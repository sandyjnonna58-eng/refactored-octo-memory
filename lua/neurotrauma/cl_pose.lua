-- Client: how an injured body carries itself. One controller for the whole skeleton.
--
-- The server sends what the nervous system can still do (cl_state.lua); this file turns it into
-- bone angles. Every source of movement is a layer; layers are added up per bone and written
-- once, so two of them never fight over a bone:
--
--   priority (a higher one replaces the lower ones on the bones it claims, by its weight)
--     4  a seizure on the feet (one arm in a beat and the head turned, a hand that fumbles)
--     3  weakness of a limb (a hanging arm, a hand that does not close, a leg that gives)
--     2  balance (sway, lean, a broad stance, a head that hangs)
--     1  tremor
--
--   The order of work is the order of what is seen: the silhouette (trunk, head, whole limbs) at
--   every distance, the fingers and the tremor only near. How strongly a layer shows follows the
--   animation state the server sends (sh_anim.lua): its mode and its intensity, 0 to 1, where
--   0.5 is meant to be plainly abnormal from across a street. A critical mode is never drawn on a
--   standing body (the server takes the character down).
--
--   standing    additive layers on Z-City's own layer system inside its "Bones" hook (one layer
--               name, "nt", per bone), so they blend with its animation and with a weapon in the
--               hands, and fade by themselves when no longer set
--   ragdolled   limbs are server physics (sv_motor.lua); fingers and toes have no physics and are
--               posed here on the ragdoll itself
--
-- Which way each joint turns was measured on Z-City's skeleton (docs/NEUROTRAUMA_ANIMATION_MAP.md):
-- the numbers below are in the bone's own angles (pitch, yaw, roll).
-- A model is asked once which of the bones it has (its capability profile); a model without them
-- gets what it can show, a model without the skeleton nothing.
-- Detail falls with distance (level 0 to 4); nothing is posed for a character that is not drawn.
-- That the signs exist is from the literature; every angle is ours [G].

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
NT.Pose = NT.Pose or {}
local P = NT.Pose
local CL = NT.CL
local C = NT.Config
local CM, CP = C.Motor, C.Pose
local AN = NT.Anim
local AM = AN.Mode
local sin, min, max, abs, Clamp = math.sin, math.min, math.max, math.abs, math.Clamp
local zero = Vector(0, 0, 0)

------------------------------------------------------------------------------------------
-- Capability profiles
------------------------------------------------------------------------------------------
local B = "ValveBiped.Bip01_"
local CORE = { "Pelvis", "Spine", "Spine1", "Spine2", "Spine4", "Neck1", "Head1" }
local SIDE = { "Clavicle", "UpperArm", "Forearm", "Hand", "Thigh", "Calf", "Foot", "Toe0" }
local FINGERS = { "Finger0", "Finger01", "Finger02", "Finger1", "Finger11", "Finger12", "Finger2", "Finger21", "Finger22",
	"Finger3", "Finger31", "Finger32", "Finger4", "Finger41", "Finger42" }

local profiles = {}
P.profiles = profiles

function P.Profile(ent)
	local mdl = ent:GetModel()
	if not mdl then return nil end
	local pr = profiles[mdl]
	if pr ~= nil then return pr or nil end
	local ids = {}
	local n = 0
	for _, name in ipairs(CORE) do
		local id = ent:LookupBone(B .. name)
		if id then ids[name] = id n = n + 1 end
	end
	if not ids.Spine1 or not ids.Head1 then
		profiles[mdl] = false
		return nil
	end
	pr = { ids = ids, fingers = { L = true, R = true }, toes = { L = false, R = false }, model = mdl }
	for _, s in ipairs({ "L", "R" }) do
		for _, name in ipairs(SIDE) do
			local id = ent:LookupBone(B .. s .. "_" .. name)
			if id then ids[s .. name] = id n = n + 1 end
		end
		for _, name in ipairs(FINGERS) do
			local id = ent:LookupBone(B .. s .. "_" .. name)
			if id then ids[s .. name] = id n = n + 1 else pr.fingers[s] = false end
		end
		pr.toes[s] = ids[s .. "Toe0"] ~= nil
	end
	pr.count = n
	pr.flexes = ent:GetFlexNum() or 0
	profiles[mdl] = pr
	return pr
end

------------------------------------------------------------------------------------------
-- Hands: finger poses. Flexion is negative yaw on every joint of the four fingers of both hands
-- (measured). The thumb folds across the fist with pitch and positive yaw at its base; the sign
-- of its pitch mirrors between the hands.
------------------------------------------------------------------------------------------
P.Hand = { NORMAL = 0, LIMP = 1, FIST = 2, TREMOR = 3, FUMBLE = 4, SPLAY = 5 }
local HAND = P.Hand

-- base knuckle, middle joint, end joint of a finger; thumb base (pitch, yaw), thumb joints
local HANDPOSE = {
	[HAND.LIMP] = { -22, -30, -18, 6, 12, -14 },
	[HAND.FIST] = { -75, -85, -60, 25, 30, -34 },
	[HAND.SPLAY] = { 14, 6, 4, 0, -28, 8 },
}
local SPREAD = { Finger1 = 14, Finger2 = 0, Finger3 = -9, Finger4 = -20 }

-- Adds the angles of a hand pose to `out` (bone name without side -> Angle), scaled by w.
local function HandPose(out, pose, w, mirror, spread)
	local hp = HANDPOSE[pose]
	if not hp or w <= 0 then return end
	for f = 1, 4 do
		local base = "Finger" .. f
		local sp = (spread and SPREAD[base] or 0) * (mirror and -1 or 1)
		out[base] = Angle(sp * w, hp[1] * w, 0)
		out[base .. "1"] = Angle(0, hp[2] * w, 0)
		out[base .. "2"] = Angle(0, hp[3] * w, 0)
	end
	out.Finger0 = Angle(hp[4] * w * (mirror and -1 or 1), hp[5] * w, 0)
	out.Finger01 = Angle(0, hp[6] * w, 0)
	out.Finger02 = Angle(0, hp[6] * 1.2 * w, 0)
end
P.HandPose = HandPose

------------------------------------------------------------------------------------------
-- Distance levels
------------------------------------------------------------------------------------------
function P.Level(ent)
	local d = EyePos():DistToSqr(ent:GetPos())
	local L = CP.lod
	if d < L[1] * L[1] then return 0 end
	if d < L[2] * L[2] then return 1 end
	if d < L[3] * L[3] then return 2 end
	if d < L[4] * L[4] then return 3 end
	return 4
end

------------------------------------------------------------------------------------------
-- The standing body
------------------------------------------------------------------------------------------
-- accumulators, reused (bone key -> pitch, yaw, roll)
local accP, accY, accR, used = {}, {}, {}, {}
local accZ = {}       -- bone key -> units along the entity's up (the pelvis, as the knees give)
local function Add(key, p, y, r)
	if not used[key] then
		used[key] = true
		accP[key], accY[key], accR[key] = p, y, r
	else
		accP[key], accY[key], accR[key] = accP[key] + p, accY[key] + y, accR[key] + r
	end
end
-- a higher layer takes a bone over by weight w
local function Over(key, p, y, r, w)
	if not used[key] then
		used[key] = true
		accP[key], accY[key], accR[key] = p * w, y * w, r * w
	else
		local k = 1 - w
		accP[key], accY[key], accR[key] = accP[key] * k + p * w, accY[key] * k + y * w, accR[key] * k + r * w
	end
end

local fingerTmp = {}

-- (harness only: single test layers, to see what each axis of a bone does)
local test
if NeuroTrauma.testRun then
	net.Receive("nt_test", function()
		local n = net.ReadUInt(4)
		if n == 0 then test = nil return end
		test = {}
		for i = 1, n do test[i] = { net.ReadString(), net.ReadAngle() } end
	end)
end

P.stats = { calls = 0, bones = 0, time = 0 }

-- The ragdoll a player lies in, as this client knows it. Z-City keeps a field for it on the
-- player; measured with twenty bots, that field was unset on the client for every one of fourteen
-- lying characters while the network variable behind it was right. Both are asked.
local function RagOf(ply)
	local rag = ply.FakeRagdoll
	if IsValid(rag) then return rag end
	rag = ply:GetNWEntity("FakeRagdoll")
	if IsValid(rag) then return rag end
	return nil
end
P.RagOf = RagOf

function P.Standing(ply, r, dt)
	local pr = P.Profile(ply)
	if not pr then return end
	local lod = P.Level(ply)
	r.lod = lod
	if lod >= 4 then return end
	-- The animation state the server sent (sh_anim.lua). A critical state is never drawn on a
	-- standing body: the server has taken the character down, and the ragdoll is a frame away.
	local mode, mi = r.anim or 0, r.animI or 0
	if AN.Critical(mode) then
		-- (counted when the body is really drawn standing: the rule, seen from this client)
		if not ply:GetNoDraw() and ply:GetRenderMode() ~= RENDERMODE_NONE then P.stats.criticalStanding = (P.stats.criticalStanding or 0) + 1 end
		return
	end
	-- (at a distance every other call is enough)
	if lod >= 2 then
		r.skip = not r.skip
		if r.skip then return end
		dt = dt * 2
	end
	local t0 = SysTime()
	local t = CurTime()
	local ph = (r.seed or 0) * 1.7
	for k in pairs(used) do used[k] = nil end
	for k in pairs(accZ) do accZ[k] = nil end
	local injured = mode == AM.INJURED and mi or 0

	-- The silhouette first: what the trunk, the head and the limbs do as a whole. These layers are
	-- drawn at every distance at which the character is posed at all.

	-- 2: balance. Two slow waves on each axis, different for every character, never a shake. The
	-- whole trunk goes, from its lowest joint; a dazed character sways too.
	local a = CM.swayAngle * max(Clamp((1 - r.balance) / CP.swayFull, 0, 1), injured * CP.dazedSway)
	local lat, fore = 0, 0
	if a > 0.2 then
		lat = (sin(t * 1.3 + ph) + 0.6 * sin(t * 2.9 + ph * 2.1)) * a * 0.6
		fore = (sin(t * 0.9 + ph * 1.3) + 0.5 * sin(t * 2.3 + ph * 0.7)) * a * 0.45
		Add("Spine", lat, fore, 0)
		Add("Spine1", lat * 0.5, fore * 0.5, 0)
	end
	-- dazed, drowsy or coming round: the head hangs, the shoulders come forward, and the head
	-- follows the sway late (yaw < 0 nods; spine yaw > 0 bends forward)
	-- (not in a seizure that only takes awareness: the person stares, upright)
	local droop = CM.headDroop * max(Clamp((0.85 - r.consciousness) / 0.45, 0, 1), injured) * (r.seizurePhase == 6 and 0.2 or 1)
	if droop > 0.3 then
		Add("Neck1", -lat * 0.2, -droop * 0.45, 0)
		Add("Head1", -lat * 0.3, -droop * 0.55, 0)
		Add("Spine2", 0, droop * 0.3, 0)
	end
	-- a weak side: the trunk leans to it (spine pitch > 0 tilts to the character's right)
	local wl, wr = 1 - min(r.armL, r.legL), 1 - min(r.armR, r.legR)
	local lean = (wr - wl) * CM.lean
	if abs(lean) > 0.3 then
		Add("Spine", lean * 0.8, 0, 0)
		Add("Spine1", lean * 0.4, 0, 0)
		Add("Head1", lean * 0.25, 0, 0)
	end
	-- poor coordination: a broad stance and a trunk that wobbles [S: N73] (thigh pitch > 0
	-- moves the right leg outward, < 0 the left)
	local atax = 1 - min(r.coordL, r.coordR, r.balance + 0.25)
	if atax > 0.2 then
		local w = Clamp((atax - 0.2) / 0.5, 0, 1)
		Add("RThigh", CP.stance * w, 0, 0) Add("LThigh", -CP.stance * w, 0, 0)
		Add("RFoot", -CP.stance * w, 0, 0) Add("LFoot", CP.stance * w, 0, 0)
		local wob = sin(t * 5.3 + ph) * CP.titubation * w
		Add("Spine2", wob * 0.6, wob, 0)
		Add("Head1", 0, -wob * 0.8, 0)
	end

	-- 3: weakness, limb by limb
	for _, s in ipairs({ "L", "R" }) do
		local arm, hand, leg = r["arm" .. s], r["hand" .. s], r["leg" .. s]
		local wa = Clamp((1 - arm - 0.15) / 0.6, 0, 1)
		if wa > 0.02 then
			-- the arm hangs turned in, the elbow hardly bent, the wrist dropped (yaw < 0 bends
			-- elbow and wrist). The shoulder sinks with the lean of the trunk above: the
			-- collar-bone of this skeleton cannot lower it (measured: 30 degrees move the elbow
			-- 8 units inward and 1.6 down, which put the arm behind the body). The lean carries
			-- the hand inward, so the upper arm is moved out a little (pitch > 0 moves the right
			-- arm outward, < 0 the left).
			Add(s .. "UpperArm", (s == "R" and 1 or -1) * CP.armOut * wa, 0, (s == "L" and 1 or -1) * CP.armTurn * wa)
			Add(s .. "Forearm", 0, -CP.elbowHang * wa, 0)
			Add(s .. "Hand", 0, -CP.wristDrop * max(wa, 1 - hand), 0)
		end
		local wg = Clamp((1 - leg - 0.15) / 0.6, 0, 1)
		if wg > 0.02 then
			-- the knee gives a little and the foot drops and turns out (calf yaw > 0 bends the
			-- knee, foot yaw > 0 points the toes down)
			Add(s .. "Thigh", 0, -CP.kneeGive * 0.5 * wg, 0)
			Add(s .. "Calf", 0, CP.kneeGive * wg, 0)
			Add(s .. "Foot", (s == "R" and 1 or -1) * CP.footTurn * wg, CP.footDrop * wg, 0)
			-- walking: the body dips over the weak leg at every step [G]
			local speed = ply:GetVelocity():Length2D()
			if speed > 25 then
				local step = sin(t * (3 + speed / 60) + ph)
				Add("Spine", (s == "R" and 1 or -1) * CP.limp * wg * max(step, 0), CP.limp * 0.4 * wg * max(step, 0), 0)
				-- and the leg is not swung through: it trails, the knee stiff, the toes down
				-- (thigh yaw > 0 takes the knee back)
				Add(s .. "Thigh", 0, CP.legDrag * wg, 0)
				Add(s .. "Calf", 0, -CP.legDrag * 0.4 * wg, 0)
			end
		end
	end

	-- 4: a seizure on the feet
	local phase = r.seizurePhase
	local sideL = r.seizureSide == 1
	local s = sideL and "L" or "R"
	local beatPulse = 0
	local strength = mode == AM.FOCAL_SEIZURE and max(mi, 0.75) or 1
	if phase == 1 then
		-- one arm jerks in a steady beat: a quick contraction and a slower release; the head and
		-- the eyes are drawn round to that side and held there [P] (head roll turns it)
		local beat = (t * C.Seizure.focalHz + ph) % 1
		local share = C.Seizure.beatShare
		beatPulse = beat < share and sin(beat / share * math.pi * 0.5) or max(1 - (beat - share) / 0.45, 0)
		Over(s .. "Clavicle", 0, 26 * beatPulse * strength, 0, 1)
		Over(s .. "UpperArm", 0, (-14 - 30 * beatPulse) * strength, 0, 1)
		Over(s .. "Forearm", 0, (-30 - 65 * beatPulse) * strength, 0, 1)
		local turn = (sideL and 1 or -1) * CP.headTurn * strength * CP.turnSign
		Add("Neck1", 0, 0, turn * 0.4)
		Add("Head1", (sideL and 6 or -6), 2 * beatPulse, turn * (0.6 + 0.08 * beatPulse))
	elseif phase == 6 then
		-- awareness lost: the gaze fixed, the head turned a little and held, one hand drawn up to
		-- the chest and fumbling at the clothes
		local f = sin(t * 2.1 + ph)
		local g = sin(t * 3.3 + ph * 0.7)
		Over(s .. "UpperArm", 0, -22, (sideL and 1 or -1) * CP.fumbleTurn, 0.9)
		Over(s .. "Forearm", 0, -98 + 16 * f, (sideL and -1 or 1) * 14 * g, 0.95)
		Over(s .. "Hand", 0, -18 + 14 * g, 0, 0.9)
		local turn = (sideL and 1 or -1) * CP.headTurn * 0.75 * CP.turnSign
		Add("Neck1", 0, 0, turn * 0.4)
		Add("Head1", 0, -3, turn * 0.6)
	end

	-- 5: losing its feet (sv_collapse.lua). The pose is the one the server puts on its own bones,
	-- so that the ragdoll, if it comes to one, is made in it. It takes the trunk, the legs and
	-- the arms over from everything above.
	if mode == AM.STAGGER then
		local w = AN.StaggerEnvelope((t - (r.animT0 or t)) / CP.staggerShown)
		for key, e in pairs(AN.StaggerPose(r.staggerOct or 0, w, max(mi, 0.3), 1)) do
			Over(key, e.p or 0, e.y or 0, e.r or 0, 1)
			if e.z then accZ[key] = e.z end
		end
	end

	-- The small things last, and only near: the fingers, and the tremor of a clumsy arm.
	if lod <= 1 and pr.fingers.L and pr.fingers.R then
		for _, hs in ipairs({ "L", "R" }) do
			local state = r["handState" .. hs] or 0
			local coord = r["coord" .. hs]
			local mirror = hs == "L"
			for k in pairs(fingerTmp) do fingerTmp[k] = nil end
			if phase == 1 and hs == s then
				HandPose(fingerTmp, HAND.FIST, 0.35 + 0.65 * beatPulse, mirror)
			elseif phase == 6 and hs == s then
				HandPose(fingerTmp, HAND.FIST, 0.45 + 0.4 * sin(t * 4.3 + ph), mirror)
			elseif state == HAND.FIST then
				HandPose(fingerTmp, HAND.FIST, 1, mirror)
			elseif state == HAND.LIMP then
				HandPose(fingerTmp, HAND.LIMP, Clamp(1.2 - r["hand" .. hs], 0.3, 1), mirror)
			elseif state == HAND.SPLAY then
				HandPose(fingerTmp, HAND.SPLAY, 1, mirror, true)
			end
			for name, ang in pairs(fingerTmp) do Add(hs .. name, ang.p, ang.y, ang.r) end
			if coord < 0.75 and lod == 0 then
				local w = Clamp((0.75 - coord) / 0.5, 0, 1)
				local tr = sin(t * 27 + ph + (mirror and 1.3 or 0)) * CP.tremor * w
				Add(hs .. "Hand", tr, tr * 0.6, 0)
				Add(hs .. "Forearm", 0, tr * 0.4, tr)
			end
		end
	end

	-- write: one layer per bone
	local ids = pr.ids
	local n = 0
	local lerp = lod == 0 and 0.12 or 0.2
	local quick = phase == 1
	for key in pairs(used) do
		local id = ids[key]
		if id then
			-- (a beat must not be smoothed away)
			local z = accZ[key]
			local pos = z and Vector(0, 0, z) or zero
			if quick and (key == s .. "Clavicle" or key == s .. "UpperArm" or key == s .. "Forearm") then
				hg.bone.Set(ply, id, pos, Angle(accP[key], accY[key], accR[key]), "nt")
			else
				hg.bone.Set(ply, id, pos, Angle(accP[key], accY[key], accR[key]), "nt", lerp, dt)
			end
			n = n + 1
		end
	end
	local st = P.stats
	st.calls, st.bones, st.time = st.calls + 1, st.bones + n, st.time + (SysTime() - t0)
end

hook.Add("Bones", "NT_Pose", function(ply, dt)
	if test then
		for i = 1, #test do hg.bone.Set(ply, test[i][1], zero, test[i][2], "nt_test", 0.25, dt) end
	end
	local r = CL.records[ply]
	if not r then return end
	if CurTime() - r.t > 4 then return end
	if not r.balance then return end
	if RagOf(ply) then return end
	P.Standing(ply, r, dt)
end)

------------------------------------------------------------------------------------------
-- Gaze: where the eyes rest. A destroyed frontal eye field lets them drift to its own side; in a
-- seizure they are drawn to the convulsing side or roll up [P]. Near characters only.
------------------------------------------------------------------------------------------
local function Gaze(ent, r)
	local dir, up = 0, 0
	local phase = r.seizurePhase
	if phase == 1 or phase == 6 then dir = r.seizureSide == 1 and 1 or -1
	elseif phase == 2 or phase == 3 or phase == 7 then up = 1 dir = r.seizureSide == 1 and 0.5 or -0.5
	elseif r.gaze == 1 then dir = 1
	elseif r.gaze == 2 then dir = -1 end
	if dir == 0 and up == 0 then
		if r.gazeSet then r.gazeSet = nil end
		return
	end
	local id = ent:LookupAttachment("eyes")
	local att = id and id > 0 and ent:GetAttachment(id)
	if not att then return end
	-- (the attachment's right is the character's right: left is negative)
	ent:SetEyeTarget(att.Pos + att.Ang:Forward() * 40 - att.Ang:Right() * 60 * dir + att.Ang:Up() * 45 * up)
	r.gazeSet = true
end

------------------------------------------------------------------------------------------
-- Ragdolls: fingers and toes (no physics of their own), and the gaze
------------------------------------------------------------------------------------------
local ragPose = setmetatable({}, { __mode = "k" })   -- ragdoll -> key of what is set on it

local function RagHands(rag, r, lod)
	local pr = P.Profile(rag)
	if not pr then return end
	local t = CurTime()
	local phase = r.seizurePhase
	-- what the hands and feet do: a posture or a tonic phase clenches the fists and points the
	-- toes [S: S8 Z6]; a clonic beat clenches in the beat; else the state the server names
	local fist, toes = 0, 0
	if phase == 2 then fist, toes = 1, 1
	elseif phase == 3 or phase == 5 or phase == 7 then
		local hz = phase == 3 and 3 or 1.2
		fist = 0.35 + 0.65 * max(sin(t * hz * math.pi * 2 + (r.seed or 0)), 0)
		toes = 0.5
	elseif r.posture == 1 or r.posture == 2 then fist, toes = 1, 1
	elseif r.posture == 3 then fist = 0.6 end
	-- (a heart that has stopped: the hands lie half open, the fingers a little curled, as hands do
	-- that nothing holds; the feet drop)
	local limp = r.anim == AM.CARDIAC_ARREST or r.anim == AM.TERMINAL_COLLAPSE
	if limp and fist <= 0 then toes = 0.4 end
	for _, s in ipairs({ "L", "R" }) do
		local mirror = s == "L"
		local state = r["handState" .. s] or 0
		local w, pose = fist, HAND.FIST
		if w <= 0 then
			if state == HAND.FIST then w, pose = 1, HAND.FIST
			elseif state == HAND.SPLAY then w, pose = 1, HAND.SPLAY
			elseif limp then w, pose = 1, HAND.LIMP end
		end
		-- (written only when it has changed by a step: bone writes are not free)
		local key = pose * 100 + math.floor(w * 12 + 0.5)
		local slot = ragPose[rag]
		if not slot then slot = {} ragPose[rag] = slot end
		if slot[s] ~= key and pr.fingers[s] then
			slot[s] = key
			for k in pairs(fingerTmp) do fingerTmp[k] = nil end
			if w > 0.02 then HandPose(fingerTmp, pose, w, mirror, pose == HAND.SPLAY) end
			for _, name in ipairs(FINGERS) do
				local id = pr.ids[s .. name]
				if id then rag:ManipulateBoneAngles(id, fingerTmp[name] or angle_zero, false) end
			end
		end
		local tk = math.floor(toes * 8 + 0.5)
		if slot["t" .. s] ~= tk and pr.toes[s] then
			slot["t" .. s] = tk
			rag:ManipulateBoneAngles(pr.ids[s .. "Toe0"], Angle(0, CP.toePoint * toes, 0), false)
		end
		-- (the hands of a body that lay in an arrest stay as they are when it has died)
		slot.keep = limp or nil
	end
end

local function RagClear(rag)
	local slot = ragPose[rag]
	if not slot or not IsValid(rag) then return end
	local pr = P.Profile(rag)
	if pr then
		for _, s in ipairs({ "L", "R" }) do
			for _, name in ipairs(FINGERS) do
				local id = pr.ids[s .. name]
				if id then rag:ManipulateBoneAngles(id, angle_zero, false) end
			end
			if pr.toes[s] then rag:ManipulateBoneAngles(pr.ids[s .. "Toe0"], angle_zero, false) end
		end
	end
	ragPose[rag] = nil
end

local nextRag = 0
hook.Add("Think", "NT_PoseRagdolls", function()
	if next(CL.records) == nil then return end
	local now = CurTime()
	local due = now >= nextRag
	if due then nextRag = now + 0.05 end
	for ply, r in pairs(CL.records) do
		if IsValid(ply) and now - r.t <= 4 then
			local rag = RagOf(ply)
			local body = rag or ply
			if not body:IsDormant() then
				local lod = P.Level(body)
				if lod <= 1 then
					Gaze(body, r)
					if due and rag then RagHands(rag, r, lod) end
				end
			end
		end
	end
end)

-- a ragdoll that is no longer an injured character's: put its hands back
timer.Create("NT_PoseSweep", 1, 0, function()
	for rag in pairs(ragPose) do
		local keep = false
		if IsValid(rag) then
			for ply, r in pairs(CL.records) do
				if IsValid(ply) and RagOf(ply) == rag and CurTime() - r.t <= 4 then keep = true break end
			end
		end
		if not keep and not (IsValid(rag) and ragPose[rag].keep) then RagClear(rag) end
	end
end)
