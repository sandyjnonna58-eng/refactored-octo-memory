-- Client: what the server says about injured characters (sv_net.lua). One small record per
-- character, refreshed at least once a second while it exists; a record that is not refreshed for
-- four seconds is forgotten (the character left the area, or recovered and the last message was
-- lost). Messages are unreliable and can arrive out of order: each carries a version, and one that
-- is not newer than the last taken is dropped. What the values drive is eased by the pose controller
-- (cl_pose.lua), so a lost message shows as a slower change and nothing else.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
NT.CL = NT.CL or {}
local CL = NT.CL
local C = NT.Config

CL.records = CL.records or {}     -- player -> record
local records = CL.records
local EXPIRE = 4
CL.stale, CL.taken = 0, 0
CL.self = CL.self or nil          -- the local player's own losses (nt_self)

local function Newer(v, last)
	if last == nil then return true end
	local d = (v - last) % 256
	return d ~= 0 and d < 128
end
CL.Newer = Newer

-- Reads one nt_state message from the current net buffer (also used by the tests, which feed it
-- messages out of order).
function CL.Take(idx, version, present, read)
	local ply = Entity(idx)
	if not IsValid(ply) then return false end
	local r = records[ply]
	if r and not Newer(version, r.version) then
		CL.stale = CL.stale + 1
		return false
	end
	if not present then
		records[ply] = nil
		CL.gone = CL.gone or {}
		CL.gone[ply] = version
		return true
	end
	-- (a message older than the one that closed the record must not bring it back)
	if not r and CL.gone and CL.gone[ply] and not Newer(version, CL.gone[ply]) then
		CL.stale = CL.stale + 1
		return false
	end
	if not r then
		r = { born = CurTime(), cur = {} }
		records[ply] = r
		if CL.gone then CL.gone[ply] = nil end
	end
	-- (when the animation mode changed, by this client's own clock: a stagger is drawn from then)
	if read.anim ~= r.anim then r.animT0 = CurTime() end
	for k, v in pairs(read) do r[k] = v end
	r.version = version
	r.t = CurTime()
	CL.taken = CL.taken + 1
	return true
end

net.Receive("nt_state", function()
	local idx = net.ReadUInt(8)
	local version = net.ReadUInt(8)
	local present = net.ReadBool()
	local read = {}
	if present then
		read.state = net.ReadUInt(3)
		read.overlays = net.ReadUInt(7)
		read.motorL, read.motorR = net.ReadUInt(4) / 15, net.ReadUInt(4) / 15
		read.balance, read.consciousness = net.ReadUInt(4) / 15, net.ReadUInt(4) / 15
		read.moveQ = net.ReadUInt(4)
		read.posture = net.ReadUInt(2)
		read.seizurePhase, read.seizureSide = net.ReadUInt(3), net.ReadUInt(2)
		read.pupilL, read.pupilR = net.ReadUInt(3) / 7, net.ReadUInt(3) / 7
		read.seed = net.ReadUInt(5)
		read.anim, read.animI = net.ReadUInt(4), net.ReadUInt(4) / 15
		read.staggerOct = net.ReadUInt(3)
		if net.ReadBool() then
			read.armL, read.armR = net.ReadUInt(3) / 7, net.ReadUInt(3) / 7
			read.handL, read.handR = net.ReadUInt(3) / 7, net.ReadUInt(3) / 7
			read.legL, read.legR = net.ReadUInt(3) / 7, net.ReadUInt(3) / 7
			read.faceL, read.faceR = net.ReadUInt(2) / 3, net.ReadUInt(2) / 3
			read.coordL, read.coordR = net.ReadUInt(3) / 7, net.ReadUInt(3) / 7
			read.handStateL, read.handStateR = net.ReadUInt(3), net.ReadUInt(3)
			read.gaze = net.ReadUInt(2)
			read.veerQ = net.ReadUInt(3) - 3
			read.cardio = net.ReadUInt(4)
			read.category = net.ReadUInt(4)
			read.detail = true
		else
			read.armL, read.armR, read.handL, read.handR, read.legL, read.legR = 1, 1, 1, 1, 1, 1
			read.faceL, read.faceR, read.coordL, read.coordR = 1, 1, 1, 1
			read.handStateL, read.handStateR, read.gaze, read.veerQ, read.cardio, read.category = 0, 0, 0, 0, 0, 0
			read.detail = false
		end
	end
	CL.Take(idx, version, present, read)
end)

net.Receive("nt_self", function()
	if not net.ReadBool() then CL.self = nil return end
	local s = CL.self or {}
	s.visUL, s.visLL, s.visUR, s.visLR = net.ReadUInt(2) / 3, net.ReadUInt(2) / 3, net.ReadUInt(2) / 3, net.ReadUInt(2) / 3
	s.neglectL, s.neglectR = net.ReadUInt(2) / 3, net.ReadUInt(2) / 3
	s.hearing = net.ReadUInt(3) / 7
	s.comprehension = net.ReadUInt(3) / 7
	s.reading = net.ReadUInt(3) / 7
	s.memory = net.ReadUInt(2) / 3
	s.attention = net.ReadUInt(2) / 3
	s.sedation = net.ReadUInt(3) / 7
	s.t = CurTime()
	CL.self = s
end)

function CL.Get(ply)
	local r = records[ply]
	if r and CurTime() - r.t > EXPIRE then
		records[ply] = nil
		return nil
	end
	return r
end

timer.Create("NT_ClientExpire", 2, 0, function()
	local now = CurTime()
	for ply, r in pairs(records) do
		if not IsValid(ply) or now - r.t > EXPIRE then records[ply] = nil end
	end
	if CL.self and now - CL.self.t > 6 then CL.self = nil end
	if CL.gone then
		for ply in pairs(CL.gone) do if not IsValid(ply) then CL.gone[ply] = nil end end
	end
end)

-- Walking speed of the local player, the same factor the server applies (sh_move.lua)
function CL.MoveFactor(ply)
	local r = CL.Get(ply)
	if not r or not r.moveQ then return 1 end
	return C.Motor.moveFloor + (1 - C.Motor.moveFloor) * r.moveQ / 15
end
