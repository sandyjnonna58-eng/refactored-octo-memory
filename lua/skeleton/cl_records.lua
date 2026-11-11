-- Client: what the server has told of the bones of the bodies this client watches (sv_net.lua).
-- A copy for showing; nothing here decides anything.

local SK = HemoSkeleton
SK.CL = SK.CL or {}
local CL = SK.CL
CL.records = CL.records or {}        -- [entity index] = { ver, bones = { [idx] = entry }, joints, regions, t }
CL.watched = CL.watched or {}        -- [entity index] = true
CL.taken = CL.taken or 0

local SRC = { [0] = "manual", "zcity", "brain" }

net.Receive("skel_rec", function()
	local ei = net.ReadUInt(13)
	local rec = { ver = net.ReadUInt(16), bones = {}, joints = {}, regions = {}, t = RealTime(), n = 0 }
	for _ = 1, net.ReadUInt(8) do
		local idx = net.ReadUInt(8)
		local e = { state = net.ReadUInt(3), integrity = net.ReadUInt(8), flags = net.ReadUInt(4), src = SRC[net.ReadUInt(2)] }
		if net.ReadBool() then e.site = net.ReadUInt(8) / 255 end
		if net.ReadBool() then e.at = { net.ReadInt(8) / 16, net.ReadInt(8) / 16, net.ReadInt(8) / 16 } end
		rec.bones[idx] = e
		rec.n = rec.n + 1
	end
	for _ = 1, net.ReadUInt(6) do
		local j = SK.JointList[net.ReadUInt(9)]
		local state = net.ReadUInt(2)
		if j then rec.joints[j.id] = { state = state } end
	end
	for _ = 1, net.ReadUInt(4) do
		local f = net.ReadUInt(4)
		local v = net.ReadUInt(8) / 255
		rec.regions[f] = v
	end
	CL.records[ei] = rec
	CL.taken = CL.taken + 1
end)

-- Asks the server for a body's record, and for word of its changes; or lets it go.
function CL.Watch(ent, on)
	if not IsValid(ent) then return end
	local ei = ent:EntIndex()
	if (CL.watched[ei] or false) == (on and true or false) then return end
	CL.watched[ei] = on and true or nil
	if not on then CL.records[ei] = nil end
	net.Start("skel_sub")
	net.WriteUInt(ei, 13)
	net.WriteBool(on and true or false)
	net.SendToServer()
end

function CL.Record(ent)
	return IsValid(ent) and CL.records[ent:EntIndex()] or nil
end

function CL.Forget()
	for ei in pairs(CL.watched) do
		local e = Entity(ei)
		if IsValid(e) then CL.Watch(e, false) end
	end
	CL.watched, CL.records = {}, {}
end

-- (a number can be given to another entity once its owner is gone)
hook.Add("EntityRemoved", "SK_ClRecords", function(ent)
	local ei = ent:EntIndex()
	if ei and ei > 0 then CL.watched[ei], CL.records[ei] = nil, nil end
end)
