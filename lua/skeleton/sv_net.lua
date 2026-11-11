-- Server: telling clients what is wrong with a character's bones.
--
-- The skeleton is not seen in ordinary play, so in ordinary play nobody is told anything: a record
-- goes only to a client that has asked for that body (the inspection view does, cl_view.lua), and
-- only to one that may use the developer view. It is sent whole when asked for and again whenever
-- it changes; a few dozen bytes. No transform of any bone is ever sent: each side works those out
-- from the entity it has (sh_pose.lua).
--
--   skel_sub   client -> server: a body's entity index, and whether to watch it or let it go
--   skel_rec   server -> client: the body, the record's version, its bones, joints and regions

local SK = HemoSkeleton
local C, RC = SK.Config, SK.Records
util.AddNetworkString("skel_sub")
util.AddNetworkString("skel_rec")

SK.Net = SK.Net or {}
local N = SK.Net
-- player -> { tokens, t, chars = { [character] = the version sent last } }
local subs = setmetatable({}, { __mode = "k" })
N.subs = subs
N.stats = { asked = 0, refused = 0, sent = 0, bytes = 0 }

local JOINT_IDX, FIELD_IDX = {}, {}
for i, j in ipairs(SK.JointList) do JOINT_IDX[j.id] = i end
for i, f in ipairs(SK.ZC.FIELDS) do FIELD_IDX[f] = i end
local SRC = { manual = 0, zcity = 1, brain = 2 }

local function Send(ply, char, rec)
	-- (a player who has died has no body of their own any more: what was theirs is the corpse's now, and
	-- the client is told that the player's own is empty, or it would go on showing what it last heard)
	local body = RC.BodyOf(char) or char
	if not IsValid(body) then return end
	net.Start("skel_rec")
	net.WriteUInt(body:EntIndex(), 13)
	net.WriteUInt((rec and rec.ver or 0) % 65536, 16)
	local list = {}
	if rec then for idx, e in pairs(rec.bones) do list[#list + 1] = idx end end
	table.sort(list)
	net.WriteUInt(#list, 8)
	for _, idx in ipairs(list) do
		local e = rec.bones[idx]
		net.WriteUInt(idx, 8)
		net.WriteUInt(e.state, 3)
		net.WriteUInt(e.integrity, 8)
		net.WriteUInt(e.flags or 0, 4)
		net.WriteUInt(SRC[e.src] or 0, 2)
		net.WriteBool(e.site ~= nil)
		if e.site then net.WriteUInt(math.floor(e.site * 255 + 0.5), 8) end
		net.WriteBool(e.at ~= nil)
		if e.at then
			for k = 1, 3 do net.WriteInt(math.Clamp(math.floor(e.at[k] * 16 + 0.5), -127, 127), 8) end
		end
	end
	local joints = {}
	if rec then for jid in pairs(rec.joints) do if JOINT_IDX[jid] then joints[#joints + 1] = jid end end end
	table.sort(joints)
	net.WriteUInt(#joints, 6)
	for _, jid in ipairs(joints) do
		net.WriteUInt(JOINT_IDX[jid], 9)
		net.WriteUInt(rec.joints[jid].state, 2)
	end
	local regions = {}
	if rec then for key in pairs(rec.regions) do if FIELD_IDX[key] then regions[#regions + 1] = key end end end
	table.sort(regions)
	net.WriteUInt(#regions, 4)
	for _, key in ipairs(regions) do
		net.WriteUInt(FIELD_IDX[key], 4)
		net.WriteUInt(math.Clamp(math.floor(rec.regions[key].value * 255 + 0.5), 0, 255), 8)
	end
	N.stats.bytes = N.stats.bytes + net.BytesWritten()
	net.Send(ply)
	N.stats.sent = N.stats.sent + 1
end

net.Receive("skel_sub", function(len, ply)
	if not IsValid(ply) then return end
	local ent = Entity(net.ReadUInt(13))
	local on = net.ReadBool()
	N.stats.asked = N.stats.asked + 1
	if not SK.Enabled() or not SK.DevAllowed(ply) then N.stats.refused = N.stats.refused + 1 return end
	local s = subs[ply]
	local now = CurTime()
	if not s then s = { tokens = C.Net.burst, t = now, chars = {} } subs[ply] = s end
	s.tokens = math.min(C.Net.burst, s.tokens + (now - s.t) * C.Net.rate)
	s.t = now
	local char = RC.CharOf(ent)
	if not char then return end
	if not on then s.chars[char] = nil return end
	if s.tokens < 1 then N.stats.refused = N.stats.refused + 1 return end
	s.tokens = s.tokens - 1
	local rec = RC.byChar[char]
	s.chars[char] = rec and rec.ver or 0
	Send(ply, char, rec)
end)

-- A record has changed: who watches that character is told, at the next look.
local dirty = {}
RC.OnChange = function(char) dirty[char] = true end
RC.OnDrop = function(char) dirty[char] = true end

timer.Create("SK_NetFlush", 0.1, 0, function()
	if next(dirty) == nil then return end
	for ply, s in pairs(subs) do
		if not IsValid(ply) or not SK.DevAllowed(ply) then
			subs[ply] = nil
		else
			for char, sent in pairs(s.chars) do
				if not IsValid(char) then
					s.chars[char] = nil
				elseif dirty[char] then
					local rec = RC.byChar[char]
					local ver = rec and rec.ver or 0
					if ver ~= sent or not rec then
						s.chars[char] = ver
						Send(ply, char, rec)
					end
				end
			end
		end
	end
	for k in pairs(dirty) do dirty[k] = nil end
end)

-- A character has become another entity (laid down as a ragdoll, got up again, died): a record
-- that is watched goes out again under the body's new number, so that a view stays with it.
local function Moved(ply)
	timer.Simple(0.2, function()
		if not IsValid(ply) then return end
		local char = RC.CharOf(SK.BodyOf(ply)) or ply
		if RC.byChar[char] then dirty[char] = true for _, s in pairs(subs) do if s.chars[char] then s.chars[char] = -1 end end end
	end)
end
hook.Add("Fake", "SK_Net", function(ply) Moved(ply) end)
hook.Add("Fake Up", "SK_Net", function(ply) Moved(ply) end)

hook.Add("PlayerSpawn", "SK_Net", function(ply)
	for _, s in pairs(subs) do if s.chars[ply] then s.chars[ply] = -1 dirty[ply] = true end end
end)
hook.Add("PlayerDisconnected", "SK_Net", function(ply) subs[ply] = nil end)
