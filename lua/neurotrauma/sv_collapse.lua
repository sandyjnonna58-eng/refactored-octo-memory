-- Going down: how a character that stands comes to lie.
--
-- Z-City has one way: the player is replaced by a ragdoll, at once (hg.Fake), and its "stumble"
-- (hg.LightStunPlayer) is the same thing with a timer. Standing, then a ragdoll. This file puts
-- what belongs between the two, where something belongs there:
--
--   loss of control   something has happened that the body cannot hold against
--   stagger           on its feet still: the trunk goes over, the knees give, a step or two is
--                     taken that was not meant, the arms go out
--   failed balance    it either catches itself, and the stagger eases away, or it does not
--   collapse          the ragdoll is made in the very pose the stagger had reached (Z-City builds
--                     it from the server's bones, and the stagger is drawn on the server's bones
--                     too), and is given the movement the fall already had
--
-- Where nothing belongs between, nothing is put: a knockout, a convulsion of the whole body, a
-- heart that has stopped and every other critical state take the body down at once (sv_anim.lua),
-- and only the way of falling differs:
--
--   limp     as it stands (a knockout: no protective action [S: C3])
--   fold     the knees give first and the body sinks where it stood (a faint, an arrest)
--   topple   over, in the direction it was already going (a stumble, a blow that dazes)
--   leg      down over the leg that did not carry
--   rigid    stiff, like a felled tree (the tonic start of a convulsion)
--   drop     the feet go from under it and it comes down on its back (a rifle round through the
--            head, by the rule of the game: sv_trauma.lua)
--
-- That the phases exist is from the descriptions of what an observer sees [S: C3 R6]; how long
-- they last, how far the body leans and every speed are ours [G].

local NT = NeuroTrauma
NT.Collapse = NT.Collapse or {}
local K = NT.Collapse
local A, C, Z = NT.Anim, NT.Config, NT.ZC
local CK = C.Collapse
local M = A.Mode
local Clamp, max, min = math.Clamp, math.max, math.min

local active = {}        -- player -> its stagger
K.active = active
K.count = { staggers = 0, falls = 0, recoveries = 0, takedowns = 0 }

-- Z-City's numbering of a ragdoll's parts (hg.realPhysNum)
local PELVIS, CHEST, R_UPPER, L_UPPER, L_FORE, L_HAND, R_FORE, R_HAND = 0, 1, 2, 3, 4, 5, 6, 7
local R_THIGH, R_CALF, HEAD, L_THIGH, L_CALF, L_FOOT, R_FOOT = 8, 9, 10, 11, 12, 13, 14

local function Standing(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive() and not IsValid(ply.FakeRagdoll) and not ply:InVehicle()
end

local function Flat(v)
	local d = Vector(v.x, v.y, 0)
	if d:LengthSqr() < 0.0001 then return nil end
	d:Normalize()
	return d
end

-- The direction of a fall relative to the way the character faces, in eighths of a turn
-- (0 forward, 2 to its left, 4 backward, 6 to its right): what clients are told.
local function Octant(ply, dir)
	local f, r = Flat(ply:GetForward()) or Vector(1, 0, 0), ply:GetRight()
	local a = math.deg(math.atan2(-dir:Dot(r), dir:Dot(f)))
	return math.floor((a % 360) / 45 + 0.5) % 8
end

local function Give(rag, n, v)
	local idx = hg.realPhysNum(rag, n)
	local phys = idx and rag:GetPhysicsObjectNum(idx)
	if IsValid(phys) then phys:AddVelocity(v) end
end

-- The movement a fall is given at the moment the ragdoll is made, by its kind.
local function Throw(rag, kind, dir, fwd, side)
	local up = Vector(0, 0, 1)
	local s = CK.throw
	if kind == "fold" then
		-- the knees go forward, the hips down and back, the trunk sinks over them
		Give(rag, L_CALF, fwd * 70 * s) Give(rag, R_CALF, fwd * 70 * s)
		Give(rag, L_THIGH, fwd * 30 * s) Give(rag, R_THIGH, fwd * 30 * s)
		Give(rag, PELVIS, (-up * 60 - fwd * 25) * s)
		Give(rag, CHEST, (-up * 30 + dir * 35) * s)
		Give(rag, HEAD, dir * 45 * s)
	elseif kind == "topple" then
		-- over, turning about the feet: the higher a part, the faster it goes
		Give(rag, L_FOOT, dir * 15 * s) Give(rag, R_FOOT, dir * 15 * s)
		Give(rag, L_CALF, (dir * 35 + fwd * 20) * s) Give(rag, R_CALF, (dir * 35 + fwd * 20) * s)
		Give(rag, L_THIGH, dir * 55 * s) Give(rag, R_THIGH, dir * 55 * s)
		Give(rag, PELVIS, dir * 75 * s)
		Give(rag, CHEST, dir * 110 * s)
		for _, n in ipairs({ L_UPPER, R_UPPER, L_FORE, R_FORE, L_HAND, R_HAND }) do Give(rag, n, dir * 110 * s) end
		Give(rag, HEAD, dir * 130 * s)
	elseif kind == "leg" then
		-- down over the leg that did not carry (side: 1 left, -1 right)
		local left = side > 0
		Give(rag, left and L_CALF or R_CALF, fwd * 85 * s)
		Give(rag, left and L_THIGH or R_THIGH, (fwd * 40 - up * 30) * s)
		Give(rag, PELVIS, (dir * 50 - up * 45) * s)
		Give(rag, CHEST, dir * 65 * s)
		Give(rag, HEAD, dir * 80 * s)
	elseif kind == "drop" then
		-- The feet go out from under it, the hips down and back, the trunk and the head over
		-- backward: it sits down and comes to lie on its back. (With the knees pushed forward, as
		-- in a fold, a body shot from the side or from behind knelt, tipped over its knees and
		-- landed on its face: runs p24d, p24e.) What the bullet itself gave the body is mostly
		-- taken away first: a rifle round from behind throws the head forward harder than this
		-- throws it back.
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:SetVelocity(phys:GetVelocity() * 0.3)
				phys:AddAngleVelocity(phys:GetAngleVelocity() * -0.7)
			end
		end
		Give(rag, L_FOOT, fwd * 90 * s) Give(rag, R_FOOT, fwd * 90 * s)
		Give(rag, L_CALF, fwd * 50 * s) Give(rag, R_CALF, fwd * 50 * s)
		Give(rag, PELVIS, (-up * 60 + dir * 35) * s)
		Give(rag, CHEST, (dir * 90 - up * 10) * s)
		for _, n in ipairs({ L_UPPER, R_UPPER, L_FORE, R_FORE, L_HAND, R_HAND }) do Give(rag, n, dir * 70 * s) end
		Give(rag, HEAD, dir * 115 * s)
	elseif kind == "rigid" then
		-- (the motor holds the body stiff from the first tick: it only needs to be set going)
		Give(rag, CHEST, dir * 55 * s)
		Give(rag, HEAD, dir * 70 * s)
		Give(rag, PELVIS, dir * 25 * s)
	end
end

K.Throw = Throw

-- The hinge: the character becomes a ragdoll, in the pose it has, with the movement its fall has.
-- kind: "limp", "fold", "topple", "leg", "rigid", "drop". dir: where it falls to (world; default: where it
-- is moving, else backward for a rigid fall, else forward). stun: seconds of Z-City's light stun
-- (a stumble), nil for none.
function K.TakeDown(ply, st, kind, dir, stun, side)
	if not Standing(ply) or not Z.has.fake then return false end
	local sg = active[ply]
	active[ply] = nil
	if st then st.stagger = nil end
	local fwd = Flat(ply:GetForward()) or Vector(1, 0, 0)
	dir = dir and Flat(dir) or (sg and sg.dir) or Flat(ply:GetVelocity()) or (kind == "rigid" and -fwd or fwd)
	-- (the server's bones are what Z-City builds the ragdoll from: the pose the stagger has reached
	-- is put on them in full, now)
	if sg and K.PoseServer then K.PoseServer(ply, sg, 1) end
	local vel = ply:GetVelocity()
	if stun and Z.has.stun then hg.LightStunPlayer(ply, stun) else hg.Fake(ply) end
	local rag = ply.FakeRagdoll
	if not IsValid(rag) then return false end
	K.count.takedowns = K.count.takedowns + 1
	-- (Z-City puts the pelvis of a new ragdoll at standing height whatever the bones say: a body
	-- whose knees had given came out with its feet in the air, run p23a. It is set down by as much
	-- as the hips had sunk.)
	if sg then
		local drop = C.Pose.staggerDrop * sg.peak * sg.peak
		local down = Vector(0, 0, -drop)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then phys:SetPos(phys:GetPos() + down) end
		end
	end
	Throw(rag, kind or "limp", dir, fwd, side or 1)
	if K.ClearServer then K.ClearServer(ply) end
	if st then
		st.collapseUntil = CurTime() + C.Anim.collapseTime
		st.collapseKind = kind
		NT.States.Push(st, ply, string.format("goes down: %s%s (moving at %.0f)", kind or "limp", sg and string.format(", out of a stagger of %.1f s", CurTime() - sg.t0) or "", vel:Length2D()))
	end
	hook.Run("NT_Collapse", ply, rag, kind, dir)
	return true
end

-- A stagger begins. opts: dir (world), dur (s), peak (0..1: how far the body goes over), fall
-- (true: it ends on the ground; false: it is caught; nil: decided at its end by fallP), fallP,
-- kind (the way of falling if it falls), side, stun, why.
function K.Stagger(ply, st, opts)
	if not Standing(ply) or active[ply] then return false end
	local now = CurTime()
	if now < (ply.NT_staggerNext or 0) then return false end
	opts = opts or {}
	local fwd = Flat(ply:GetForward()) or Vector(1, 0, 0)
	local dir = opts.dir and Flat(opts.dir) or Flat(ply:GetVelocity())
	if not dir then
		-- (nothing gives a direction: somewhere to the side or backward, by chance)
		local a = math.rad(90 + math.random() * 180)
		dir = fwd * math.cos(a) + ply:GetRight() * math.sin(a)
	end
	local sg = {
		ply = ply, st = st, t0 = now, dur = opts.dur or CK.staggerTime[1] + math.random() * (CK.staggerTime[2] - CK.staggerTime[1]),
		dir = dir, oct = Octant(ply, dir), peak = Clamp(opts.peak or 0.7, 0.3, 1), fall = opts.fall, fallP = opts.fallP or 0.5,
		kind = opts.kind or "topple", side = opts.side or 1, stun = opts.stun, steps = 0, why = opts.why or "?",
	}
	active[ply] = sg
	ply.NT_staggerNext = now + sg.dur + CK.staggerGap
	K.count.staggers = K.count.staggers + 1
	if st then
		st.stagger = sg
		NT.States.Push(st, ply, string.format("loses control (%s): staggers for %.1f s, %s", sg.why, sg.dur,
			sg.fall == true and "and will go down" or (sg.fall == false and "and will catch itself" or string.format("falls with a chance of %.0f%%", sg.fallP * 100))))
		-- (the animation state and the clients, now and not at the next step of the model; a stagger
		-- that the resolver itself begins is taken up by it in the same call)
		local org = ply.organism
		if istable(org) and not opts.quiet then
			A.Resolve(ply, org, st, now)
			if NT.Net then NT.Net.Update(ply, org, st, now) end
		end
	end
	-- (the owner feels it)
	ply:ViewPunch(Angle(6 * sg.peak, 0, (sg.oct >= 1 and sg.oct <= 3) and -8 * sg.peak or 8 * sg.peak))
	return true
end

function K.Staggering(ply) return active[ply] ~= nil end

hook.Add("Think", "NT_Collapse", function()
	if next(active) == nil then return end
	local now = CurTime()
	for ply, sg in pairs(active) do
		if not Standing(ply) then
			-- (Z-City dropped it, or it died: the stagger is over; the pose is taken off the bones)
			active[ply] = nil
			if sg.st then sg.st.stagger = nil end
			if IsValid(ply) and K.ClearServer then K.ClearServer(ply) end
		else
			local f = (now - sg.t0) / sg.dur
			-- (a faint ends when wakefulness is nearly at the value at which Z-City itself drops a
			-- character, 0.4: the fall is made here, in the pose and with the movement it has)
			if sg.kind == "fold" and sg.fall and sg.st and (sg.st.effective or 1) <= 0.43 and now - sg.t0 >= 0.3 then f = 1 end
			-- the steps that were not meant: a push at the start, another on the way
			if sg.steps == 0 or (sg.steps == 1 and f >= 0.45) then
				sg.steps = sg.steps + 1
				local turn = sg.steps == 2 and (math.random() < 0.5 and 35 or -35) or 0
				local d = Vector(sg.dir)
				d:Rotate(Angle(0, turn, 0))
				ply:SetVelocity(d * CK.stepSpeed * sg.peak)
			end
			if f >= 1 then
				local fall = sg.fall
				if fall == nil then fall = math.random() < sg.fallP end
				if fall then
					K.count.falls = K.count.falls + 1
					K.TakeDown(ply, sg.st, sg.kind, sg.dir, sg.stun, sg.side)
				else
					K.count.recoveries = K.count.recoveries + 1
					active[ply] = nil
					if sg.st then
						sg.st.stagger = nil
						NT.States.Push(sg.st, ply, "catches itself")
						local org = ply.organism
						if istable(org) and NT.Get(org) == sg.st then
							A.Resolve(ply, org, sg.st, now)
							if NT.Net then NT.Net.Update(ply, org, sg.st, now) end
						end
					end
					if K.ClearServer then K.ClearServer(ply) end
				end
			end
		end
	end
end)

------------------------------------------------------------------------------------------
-- The stagger on the server's own bones. Z-City runs its bone layers on the server too, five
-- times a second (hook "Bones"), and builds a ragdoll from those bones: a character that goes
-- down out of a stagger becomes a ragdoll that leans and buckles as the stagger did, not one that
-- stands upright for a frame.
------------------------------------------------------------------------------------------
local B = "ValveBiped.Bip01_"
local zeroV, zeroA = Vector(0, 0, 0), Angle(0, 0, 0)
local BONES = { Pelvis = B .. "Pelvis", Spine = B .. "Spine", Spine1 = B .. "Spine1", LThigh = B .. "L_Thigh", RThigh = B .. "R_Thigh", LCalf = B .. "L_Calf", RCalf = B .. "R_Calf" }

function K.PoseServer(ply, sg, w)
	if not (hg.bone and hg.bone.Set) then return end
	local pose = A.StaggerPose(sg.oct, w, sg.peak, sg.side)
	for key, name in pairs(BONES) do
		local e = pose[key]
		if e then hg.bone.Set(ply, name, e.z and Vector(0, 0, e.z) or zeroV, Angle(e.p or 0, e.y or 0, e.r or 0), "nt_stagger") end
	end
	ply.NT_staggerPosed = true
end

function K.ClearServer(ply)
	if not ply.NT_staggerPosed or not (hg.bone and hg.bone.Set) then return end
	for _, name in pairs(BONES) do hg.bone.Set(ply, name, zeroV, zeroA, "nt_stagger") end
	ply.NT_staggerPosed = nil
end

hook.Add("Bones", "NT_CollapsePose", function(ply)
	local sg = active[ply]
	if not sg then
		if ply.NT_staggerPosed then K.ClearServer(ply) end
		return
	end
	K.PoseServer(ply, sg, A.StaggerEnvelope((CurTime() - sg.t0) / sg.dur, sg.fall))
end)

hook.Add("PlayerDeath", "NT_Collapse", function(ply)
	active[ply] = nil
	if K.ClearServer then K.ClearServer(ply) end
end)
hook.Add("PlayerDisconnected", "NT_Collapse", function(ply) active[ply] = nil end)
