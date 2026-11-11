-- Movement that an injured brain produces or fails to produce, on the server.
--
--   on a ragdoll   abnormal posturing (flexor, extensor), the forearm posture of a knockout and
--                  the movement of a seizure: the whole body is drawn toward the shape a state
--                  gives it, in the body's own frame. A body that only lies breathes, if it
--                  breathes (which is what tells an unconscious character from one whose heart
--                  has stopped), and stirs as it comes round. A body whose heart has just
--                  stopped is let fall open, onto the ground it lies on, and then lies by itself
--   standing       loss of balance (a short fall), slowed walking; sway, lean and a weak arm are
--                  drawn by each client (cl_pose.lua)
--
-- What is driven follows the animation state (sv_anim.lua): the mode says which shape, its
-- intensity how completely and how firmly. A shape has three layers, in this order of importance:
--   the silhouette   trunk and limbs: bent or straight, arched or flat, held or beating. This is
--                    what is seen from across a street, and it is all done here, with physics.
--   the detail       hands, feet, head: fists, pointed toes, the neck (here and in cl_pose.lua)
--   the small things fingers, the face, the eyes (cl_pose.lua, sv_face.lua), near characters only
--
-- The shapes of the postures are from the literature [S: S8], the phases of a seizure too
-- [S: Z5 Z6]; joint targets, strengths and timing are ours [G]. Posturing is a response: it comes
-- when the body is hurt, moved or treated, holds for some seconds and eases; it also comes in waves
-- of its own. Nothing here shakes at random: every movement belongs to a phase with a beginning,
-- a course and an end.
--
-- How a part is moved. A limb is drawn toward its place by shadow control of its own physics
-- object, with own parameters (Z-City's helper for this scales by the ragdoll's voluntary strength,
-- which is zero exactly when a body postures). That is a force from outside: the trunk does not
-- feel it. For a hand or a foot this is harmless. For the trunk it is not: lifting the pelvis is
-- lifting the body, and at the strength a movement needs to be seen, shadow control of the pelvis
-- stood a convulsing body on its head (run vis2). So the trunk is only ever moved by a pull
-- between parts: what is given to the pelvis and the chest is taken, reversed, from the head and
-- the feet, each by the lever it has. The body can then bow and heave, against the ground and its
-- own weight; it cannot rise. (The same pairing was tried for the limbs and given up: a ragdoll's
-- trunk is a narrow rounded thing that the honest reaction to a lifted arm rolls over, run vis3.)
-- While a body is driven here, Z-City's voluntary ragdoll control is switched off for it (hook
-- CanControlFake) and it cannot get up (hook Should Fake Up).

local NT = NeuroTrauma
NT.Motor = NT.Motor or {}
local M = NT.Motor
local C, Z, E, A = NT.Config, NT.ZC, NT.E, NT.Anim
local CM = C.Motor
local P = E.Posture
local AM = A.Mode
local Clamp, max, min = math.Clamp, math.max, math.min

local list = {}                                    -- bodies being driven
local ctlOf = setmetatable({}, { __mode = "k" })   -- ragdoll -> its controller
local slots = 0
M.ctlOf = ctlOf

-- Z-City's numbering of a ragdoll's parts (hg.realPhysNum)
local PELVIS, CHEST, R_UPPER, L_UPPER, L_FORE, L_HAND, R_FORE, R_HAND = 0, 1, 2, 3, 4, 5, 6, 7
local R_THIGH, R_CALF, HEAD, L_THIGH, L_CALF, L_FOOT, R_FOOT = 8, 9, 10, 11, 12, 13, 14

-- Where a shape puts each part: { part, anchor, toward the front, toward the body's left, toward
-- the head, weight, flat }, in units, in the body's own frame. A forearm's origin is the elbow, a
-- calf's the knee. A flat entry belongs to a leg that is to lie straight. It is placed along the
-- line from the feet to the head, not along the line of the trunk (which, arched, points into the
-- air), and is moved neither toward the front nor toward the back: the leg is drawn out and
-- together along the ground it lies on, never lifted off it and never pressed onto it. (A knee
-- that is pushed down pins its own foot and the leg stays bent, whether it is pushed to the
-- ground, run audit9, or to the middle between hip and foot, run pre22d.) A foot that still has a
-- way to go is carried a little off the ground so that it does not catch. A shape can also arch
-- the trunk (arch: units the pelvis is
-- brought in front of the line from the feet to the head) and set the neck (neck: units the head
-- is taken back).
local LEGS_STRAIGHT = {
	{ L_CALF, PELVIS, 1, 4, -18, 0.5, true }, { R_CALF, PELVIS, 1, -4, -18, 0.5, true },
	{ L_FOOT, PELVIS, 0, 4, -37, 1.6, true }, { R_FOOT, PELVIS, 0, -4, -37, 1.6, true },
}
local function With(pose, extra)
	for _, e in ipairs(extra) do pose[#pose + 1] = e end
	return pose
end
local POSES = {
	-- arms bent and drawn onto the chest, legs straight
	[P.FLEXOR] = With({
		{ L_HAND, CHEST, 7, 2, 1, 1.0 }, { R_HAND, CHEST, 7, -2, 1, 1.0 },
		{ L_FORE, CHEST, 2, 8, -6, 0.8 }, { R_FORE, CHEST, 2, -8, -6, 0.8 },
	}, LEGS_STRAIGHT),
	-- arms straight along the body and turned in, legs straight, feet pointed; at its severe end
	-- the back arched off the ground and the head back [S: G8]
	[P.EXTENSOR] = With({
		{ L_FORE, CHEST, -1, 9, -6, 0.9 }, { R_FORE, CHEST, -1, -9, -6, 0.9 },
		{ L_HAND, PELVIS, -1, 10, -6, 1.0 }, { R_HAND, PELVIS, -1, -10, -6, 1.0 },
		arch = CM.archPosture, neck = 3,
	}, LEGS_STRAIGHT),
	-- one forearm held up and out, the other bent over the chest (side from the seed)
	[P.FENCING] = {
		{ L_HAND, CHEST, 19, 11, 5, 1.0 }, { L_FORE, CHEST, 9, 10, 0, 1.0 },
		{ R_HAND, CHEST, 7, -2, 1, 0.8 }, { R_FORE, CHEST, 3, -8, -5, 0.6 },
		quick = 1.6,
	},
}
-- The tonic phase of a convulsion: for a moment the arms come up, bent and away from the body,
-- then everything is driven straight [S: Z5 Z6]. The bow of the trunk in this phase was not read
-- anywhere: it is the same bow as the severe extensor posture, given to the phase so that it
-- can be told from a body that merely lies straight [G].
local TONIC_FLEX = With({
	{ L_HAND, CHEST, 10, 13, 5, 1.0 }, { R_HAND, CHEST, 10, -13, 5, 1.0 },
	{ L_FORE, CHEST, 5, 12, -2, 0.9 }, { R_FORE, CHEST, 5, -12, -2, 0.9 },
	arch = CM.archTonic * 0.5, neck = 2, quick = 1.5,
}, LEGS_STRAIGHT)
local TONIC_EXT = With({
	{ L_FORE, CHEST, -1, 11, -6, 1.0 }, { R_FORE, CHEST, -1, -11, -6, 1.0 },
	{ L_HAND, PELVIS, -1, 13, -6, 1.0 }, { R_HAND, PELVIS, -1, -13, -6, 1.0 },
	arch = CM.archTonic, neck = 4, quick = 1.5,
}, LEGS_STRAIGHT)
-- The clonic phase is a beat between two shapes: the contraction (arms drawn up to the chest,
-- knees drawn up, the trunk thrown forward) and its release (arms down and out, legs let go).
-- (Hand and elbow are both drawn: with the hand alone a beat lost a third of its travel and the
-- knees most of theirs, run pre22d. Every part that is drawn costs a call of the engine's
-- controller, some eight microseconds; a convulsing body is the most expensive thing this module
-- does, and it is worth it.)
local CLONIC_FLEX = {
	{ L_HAND, CHEST, 10, 5, 7, 1.0 }, { R_HAND, CHEST, 10, -5, 7, 1.0 },
	{ L_FORE, CHEST, 3, 9, -5, 0.9 }, { R_FORE, CHEST, 3, -9, -5, 0.9 },
	{ L_CALF, PELVIS, 11, 5, -12, 1.3 }, { R_CALF, PELVIS, 11, -5, -12, 1.3 },
	{ L_FOOT, PELVIS, 2, 5, -27, 1.0 }, { R_FOOT, PELVIS, 2, -5, -27, 1.0 },
	heave = 1,
}
-- (the legs are let go and fall by their own weight; the arms are thrown down and out)
local CLONIC_RELAX = {
	{ L_HAND, PELVIS, -2, 16, -3, 1.0 }, { R_HAND, PELVIS, -2, -16, -3, 1.0 },
	{ L_FORE, CHEST, -1, 11, -8, 0.8 }, { R_FORE, CHEST, -1, -11, -8, 0.8 },
}
-- one side only: a focal seizure of a body that lies, the jerks after an impact or as the
-- circulation stops (left; mirrored for the right)
local FOCAL_FLEX = { { L_HAND, CHEST, 10, 5, 6, 1.0 }, { L_FORE, CHEST, 3, 9, -5, 0.8 }, { L_CALF, PELVIS, 8, 5, -14, 0.7 } }
local FOCAL_RELAX = { { L_HAND, PELVIS, -2, 15, -2, 0.9 }, { L_FORE, CHEST, -1, 11, -8, 0.7 } }
-- An agonal gasp: the chest is heaved up and the head goes back, for well under a second.
local GASP = { arch = CM.gaspLift, archChest = true, neck = 3 }
-- A heart that has stopped: a body that holds nothing. A ragdoll that has just dropped lies as it
-- happened to land, propped on a bent knee or an arm, like any other ragdoll; this shape lets the
-- body fall all the way when the arrest begins, and then nothing holds it. Flat. One arm flung
-- out from the shoulder, the other fallen beside the body, away from it. One leg out straight, the
-- other let go with its knee fallen outward and its foot drawn in. The head rolled to the side.
-- No part of it is tense, none of it beats, and the chest does not move: that is what tells it
-- from a posture, from a convulsion and from an unconscious body that breathes. (A look for the
-- game, asked for as one: not a finding [G].)
-- Every part comes to lie on the ground: nothing is lifted, nothing is laid on the body. A limb
-- that rises is a limb that is moved by someone, and this body is moved by nobody (the first
-- shape had a hand laid on the belly: it went there through the air, run p24b).
-- Where the parts come to lie, on the ground the body lies on, not in the body's own frame (which
-- points into the air for half of the ways a body can land): { part, anchor, toward the head, to
-- the body's left, weight, arm }. Left-handed here; mirrored by chance.
local ARREST = {
	{ L_FORE, CHEST, 7.5, 19.5, 0.8, true }, { L_HAND, CHEST, 13, 28, 1.0, true },
	{ R_FORE, CHEST, -4.5, -14, 0.7, true }, { R_HAND, PELVIS, -2, -17, 0.9, true },
	{ L_CALF, PELVIS, -18, 6.5, 0.6 }, { L_FOOT, PELVIS, -36.5, 10, 1.0 },
	{ R_CALF, PELVIS, -14, -15, 0.9 }, { R_FOOT, PELVIS, -30, -7, 0.9 },
}
-- (A body on its face: the same arms; both legs out, the second a little further from the first.
-- A knee cannot fall outward under a body that lies on it: the ragdoll's answer to being asked
-- was a foot held up in the air, run p24b.)
local ARREST_DOWN = {
	ARREST[1], ARREST[2], ARREST[3], ARREST[4], ARREST[5], ARREST[6],
	{ R_CALF, PELVIS, -18, -9, 0.6 }, { R_FOOT, PELVIS, -36, -13, 1.0 },
}
-- (how far the middle of a part is from the ground it lies on)
local LIES = { [L_HAND] = 1.5, [R_HAND] = 1.5, [L_FORE] = 2.5, [R_FORE] = 2.5, [L_CALF] = 3, [R_CALF] = 3, [L_FOOT] = 2, [R_FOOT] = 2 }
-- A body that is coming round stirs: one of these, for a second, then it lies again (left side;
-- mirrored by chance). The head is lifted; an arm pushes against the ground; a knee is drawn up.
local STIR = {
	{ { HEAD, CHEST, 6, 0, 11, 1.0 } },
	{ { L_HAND, CHEST, 3, 13, -3, 1.0 }, { L_FORE, CHEST, 8, 12, -4, 0.8 } },
	{ { L_CALF, PELVIS, 9, 5, -13, 1.0 } },
	{ { HEAD, CHEST, 5, 0, 11, 1.0 }, { L_HAND, CHEST, 3, 13, -3, 0.9 }, { L_FORE, CHEST, 8, 12, -4, 0.7 } },
}
local MIRROR = {
	[L_HAND] = R_HAND, [R_HAND] = L_HAND, [L_FORE] = R_FORE, [R_FORE] = L_FORE, [L_UPPER] = R_UPPER, [R_UPPER] = L_UPPER,
	[L_CALF] = R_CALF, [R_CALF] = L_CALF, [L_FOOT] = R_FOOT, [R_FOOT] = L_FOOT, [L_THIGH] = R_THIGH, [R_THIGH] = L_THIGH,
}

local function Part(ctl, n)
	local p = ctl.parts[n]
	if p == nil then
		local idx = hg.realPhysNum(ctl.rag, n)
		p = idx and ctl.rag:GetPhysicsObjectNum(idx) or false
		if p and not IsValid(p) then p = false end
		ctl.parts[n] = p
	end
	-- (a body that is being removed loses its physics objects before it stops being valid itself:
	-- seen as "Tried to use a NULL physics object" when the map was cleaned up, run all28)
	if p and not p:IsValid() then return nil end
	return p or nil
end

local function Controller(rag, ply)
	local ctl = ctlOf[rag]
	if ctl then return ctl end
	if not Z.has.physnum then return nil end
	slots = slots + 1
	ctl = { rag = rag, ply = ply, parts = {}, env = 0, level = 0, kind = P.NONE, evokedUntil = 0, nextWave = 0, side = 1, born = CurTime(), slot = slots }
	ctlOf[rag] = ctl
	list[#list + 1] = ctl
	return ctl
end

-- Something was done to the body: a posturing body answers.
function M.Stimulus(ply, strength)
	local rag = IsValid(ply) and ply.FakeRagdoll
	local ctl = IsValid(rag) and ctlOf[rag]
	if not ctl then return end
	local now = CurTime()
	if now >= ctl.evokedUntil then ctl.fastUntil = now + 1.2 end
	ctl.evokedUntil = max(ctl.evokedUntil, now + CM.evokedHold[1] + math.random() * (CM.evokedHold[2] - CM.evokedHold[1]) * (strength or 1))
end

-- A gasp of a body without circulation (sv_cardioresp.lua).
function M.Gasp(ply)
	local rag = IsValid(ply) and ply.FakeRagdoll
	if not IsValid(rag) then return false end
	local ctl = Controller(rag, ply)
	if not ctl then return false end
	ctl.seen = CurTime()
	ctl.gaspUntil = CurTime() + CM.gaspTime
	ctl.gaspRest = nil
	return true
end

-- Called with every step of an injured brain (10 Hz): does this body need driving, and how?
function M.Update(ply, org, st, now)
	local rag = IsValid(ply) and ply.FakeRagdoll or nil
	if not IsValid(rag) then
		-- standing: a leg that does not carry takes the character down, and it stays down (Should Fake Up)
		if IsValid(ply) and ply:IsPlayer() and min(st.legL, st.legR) < CM.standMotor and Z.has.fake and now >= (st.nextCollapse or 0) then
			st.nextCollapse = now + 2
			NT.States.Push(st, ply, string.format("a leg gives way (left %.2f, right %.2f)", st.legL, st.legR))
			-- (down over that leg, after the moment it takes: sv_collapse.lua)
			local K = NT.Collapse
			local side = st.legL <= st.legR and 1 or -1
			if K then
				if not K.Staggering(ply) then
					K.Stagger(ply, st, { kind = "leg", side = side, dir = ply:GetRight() * -side, dur = 0.45, peak = 1, fall = true, why = "a leg gives way" })
				end
			else
				hg.Fake(ply)
			end
			return
		end
		-- standing: balance
		if st.balance < CM.stumbleFrom and IsValid(ply) and ply:IsPlayer() and ply:OnGround() and now >= (st.nextStumbleCheck or 0) then
			st.nextStumbleCheck = now + 0.5
			local speed = ply:GetVelocity():Length2D()
			-- (turning counts as moving: a body with poor balance does not come round quickly)
			local yaw = ply:EyeAngles().y
			local turning = math.abs(math.AngleDifference(yaw, st.lastYaw or yaw)) * 2
			st.lastYaw = yaw
			local moving = max(Clamp(speed / 200, 0, 1.5), Clamp(turning / 240, 0, 1) * CM.turnShare)
			local risk = (1 - st.balance) ^ 2 * CM.stumbleRate * moving * 0.5
			if math.random() < risk then
				local long = CM.stumbleTime[1] + (CM.stumbleTime[2] - CM.stumbleTime[1]) * (1 - st.balance)
				local K = NT.Collapse
				local why = string.format("lost balance (balance %.2f, moving at %.0f, turning %.0f degrees a second)", st.balance, speed, turning)
				if K then
					-- (a stagger first; whether it is caught depends on how much balance is left)
					K.Stagger(ply, st, { kind = "topple", fallP = Clamp((1 - st.balance) * 1.4, 0.3, 0.95), stun = long, peak = Clamp(1.25 - st.balance, 0.45, 1), why = why })
				elseif Z.Stumble(ply, long) then
					NT.States.Push(st, ply, why)
				end
			end
		end
		-- a weapon hand that cannot close lets go of what it holds: Z-City's own drop, the one it
		-- runs when a character passes out
		if IsValid(ply) and ply:IsPlayer() and st.handR < C.Control.gripHand and now >= (st.nextDrop or 0) then
			st.nextDrop = now + 1
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and ishgweapon and ishgweapon(wep) and not wep.NoDrop then
				NT.States.Push(st, ply, string.format("the right hand cannot hold the weapon (hand %.2f): dropped", st.handR))
				hook.Run("PlayerDropWeapon", ply)
			end
		end
		-- a clumsy weapon arm: the aim is thrown about, more the less coordination is left. Done on
		-- the server (a view punch), so it cannot be switched off on the client [G]
		if IsValid(ply) and ply:IsPlayer() and st.coordR < 0.8 and now >= (st.nextPunch or 0) then
			st.nextPunch = now + 0.25 + math.random() * 0.35
			local wep = ply:GetActiveWeapon()
			if IsValid(wep) and ishgweapon and ishgweapon(wep) then
				local a = C.Control.ataxiaPunch * Clamp((0.8 - st.coordR) / 0.6, 0, 1)
				ply:ViewPunch(Angle((math.random() - 0.5) * 2 * a, (math.random() - 0.5) * 2 * a, 0))
			end
		end
		return
	end
	-- What the animation state asks of the body. A terminal collapse is driven by nothing; in an
	-- arrest only the jerks of the first seconds are; a posture is driven at the intensity of the mode.
	local an = st.anim
	local mode = an and an.mode or AM.NORMAL
	local sz = st.sz
	local seizing = sz and sz.phase ~= "postictal" and sz.phase ~= "impaired"
	if mode == AM.TERMINAL_COLLAPSE or (mode == AM.CARDIAC_ARREST and not (sz and sz.kind == "jerks")) then seizing = false end
	local posturing = mode == AM.ABNORMAL_POSTURING or (mode == AM.CRITICAL_COLLAPSE and an.into == AM.ABNORMAL_POSTURING)
	local fencing = posturing and now < st.fencingUntil and Z.Takeover() and not seizing
	local kind = fencing and P.FENCING or st.postureKind
	local level = posturing and (fencing and 1 or an.blend) or 0
	-- a body that only lies: it breathes if it breathes, and stirs as it comes round
	local breath = (st.effective or 1) < 0.4 and org.lungsfunction ~= false and not org.heartstop and not st.arrestSince
	local settling = st.arrestSince ~= nil and (st.settledArrest ~= st.arrestSince or (ctlOf[rag] ~= nil and now < (ctlOf[rag].settleUntil or 0)))
	-- (the second half of the time after a convulsion is a coming round too)
	local stir = (mode == AM.RECOVERING and an.blend) or (mode == AM.POSTICTAL and (st.effective or 0) >= 0.12 and 0.6) or nil
	local ctl = ctlOf[rag]
	if level <= 0 and not seizing and not ctl and not breath and not stir and not settling then return end
	ctl = ctl or Controller(rag, ply)
	if not ctl then return end
	ctl.seen = now
	ctl.breath, ctl.stir = breath or nil, stir
	-- An arrest that has just begun: the body is let fall into the shape of one that holds nothing.
	-- A body that has only just gone down falls open, quickly, with what is left of its fall. One
	-- that has lain for a while only lets go: the legs slide out, the head rolls; its arms stay
	-- where they are (an arm that sets out across the ground by itself is an arm that is moved).
	if st.arrestSince and st.settledArrest ~= st.arrestSince then
		st.settledArrest = st.arrestSince
		local fresh = now - rag:GetCreationTime() < CM.arrestFresh
		local i = fresh and 1 or 2
		ctl.settleFresh = fresh
		ctl.settleFor, ctl.settleStrength, ctl.settleQuick = CM.arrestSettle[i], CM.arrestStrength[i], fresh and CM.arrestQuick or 1
		ctl.settleFrom, ctl.settleUntil = now, now + ctl.settleFor
		ctl.settleSide = math.random() < 0.5 and 1 or -1
		-- (a body on its side is rolled for most of a second at most; all of it is over in time for
		-- the one gasp of a rifle round, sh_config.lua)
		ctl.settleRollBy, ctl.settleBy = now + 0.7, now + (fresh and 2.2 or 3.5)
		ctl.settleRolling = nil
	end
	ctl.sz = seizing and sz or nil
	ctl.hold = seizing or nil
	ctl.blend = an and an.blend or 1
	if level > 0 and kind ~= P.NONE and kind ~= ctl.kind then
		ctl.kind = kind
		ctl.fastUntil = now + 1.2
		if kind == P.FENCING then
			ctl.side = ((st.fencingSeed or 1) % 2 == 0) and 1 or -1
			ctl.evokedUntil = st.fencingUntil
		else
			-- a posture that has just appeared shows itself once
			ctl.evokedUntil = max(ctl.evokedUntil, now + CM.evokedHold[1])
			ctl.side = 1
		end
	end
	ctl.level = level
	ctl.fencing = fencing
	-- being moved is a stimulus too (dragged, carried, rolled)
	local root = Part(ctl, PELVIS)
	if root and not fencing and level > 0 and root:GetVelocity():LengthSqr() > CM.movedSpeed * CM.movedSpeed and now >= (ctl.movedNext or 0) then
		ctl.movedNext = now + 2
		M.Stimulus(ply, 0.6)
	end
	-- and it comes unprompted, in waves, the more often the worse the state is
	if not fencing and level >= CM.waveFrom and now >= ctl.nextWave then
		if ctl.nextWave > 0 then M.Stimulus(ply, 0.8) end
		local every = CM.waveEvery[1] + math.random() * (CM.waveEvery[2] - CM.waveEvery[1])
		ctl.nextWave = now + every * (1.5 - 0.7 * level)
	end
end
-- What a seizure does to the body at this instant. A tonic phase is held; the others are beats
-- between a contraction, in which the limbs are pulled hard toward one shape, and its release, in
-- which they are let go toward another.
--   focal   one arm (and a little of that leg), a steady beat
--   tonic   the arms come up for a moment, then everything is driven straight, arched, and stays
--   clonic  all limbs and the trunk together; the beats come more slowly, and larger, toward the end
--   jerks   a few irregular, weak, one-sided jerks (impact convulsion; the moment circulation stops)
-- Returns: shape, strength now, side, how abruptly (1 = as a posture comes on).
local function SeizurePose(sz, now, dt, blend)
	local CS = C.Seizure
	local f = Clamp((now - sz.t0) / max(sz.tEnd - sz.t0, 0.1), 0, 1)
	if sz.phase == "tonic" then
		-- comes on within a second, then holds
		local t = now - sz.t0
		local on = min(t / 0.6, 1)
		if t < min(CS.tonicFlex, (sz.tEnd - sz.t0) * 0.3) then return TONIC_FLEX, on, 1, TONIC_FLEX.quick end
		return TONIC_EXT, on, 1, TONIC_EXT.quick
	elseif sz.phase == "clonic" then
		local hz = CS.clonicHz[1] + (CS.clonicHz[2] - CS.clonicHz[1]) * f
		local b = (sz.beat or 0) + hz * dt
		if math.floor(b) > math.floor(sz.beat or 0) then
			sz.pullUntil = now + min(CS.beatTime, 0.45 / hz)
			sz.kick = true
			-- (no two beats alike, and one side a little ahead of the other for the whole
			-- seizure: within limits, so that it stays one movement [G])
			sz.gain = 0.86 + 0.28 * math.random()
			sz.asym = sz.asym or (math.random() - 0.5) * 0.4
		end
		sz.beat = b
		-- (a seizure that does not stop goes on weaker: sv_seizure.lua, sz.weak. The mode's intensity carries it.)
		local g = blend * (sz.gain or 1)
		if now < (sz.pullUntil or 0) then return CLONIC_FLEX, g, 1, CM.jerkQuick end
		return CLONIC_RELAX, g * CM.releaseShare, 1, CM.releaseQuick
	elseif sz.phase == "subtle" then
		-- after minutes little is left to see: a twitch of one side now and then
		if now >= (sz.nextJerk or 0) then
			sz.nextJerk = now + 0.7 + math.random() * 1.6
			sz.pullUntil = now + CS.beatTime
			sz.jerkSide = math.random() < 0.5 and 1 or -1
		end
		if now < (sz.pullUntil or 0) then return FOCAL_FLEX, 0.4, sz.jerkSide or 1, CM.jerkQuick end
		return nil, 0, 1, 1
	elseif sz.phase == "focal" then
		local b = (sz.beat or 0) + CS.focalHz * dt
		if math.floor(b) > math.floor(sz.beat or 0) then sz.pullUntil = now + CS.beatTime end
		sz.beat = b
		if now < (sz.pullUntil or 0) then return FOCAL_FLEX, sz.strength * 0.8, sz.side, CM.jerkQuick end
		return FOCAL_RELAX, sz.strength * 0.8 * CM.releaseShare, sz.side, CM.releaseQuick
	elseif sz.phase == "jerks" then
		-- irregular: the next jerk is drawn when the last one has been made
		if now >= (sz.nextJerk or 0) then
			sz.nextJerk = now + 0.3 + math.random() * 1.0
			sz.pullUntil = now + CS.beatTime
			sz.jerkSide = math.random() < 0.5 and 1 or -1
			sz.kick = true
		end
		local s = 0.7 * (1 - 0.5 * f)
		if now < (sz.pullUntil or 0) then return FOCAL_FLEX, s, sz.jerkSide or 1, CM.jerkQuick end
		return FOCAL_RELAX, s * CM.releaseShare, sz.jerkSide or 1, CM.releaseQuick
	end
	return nil, 0, 1, 1
end

local sp = { secondstoarrive = 0.3, dampfactor = 0.85, maxangular = 0, maxangulardamp = 0, teleportdistance = 0 }

-- A limb: drawn to its place.
local function Shadow(phys, pos, strength, quick, dt)
	sp.pos = pos
	sp.angle = phys:GetAngles()
	sp.deltatime = dt
	sp.secondstoarrive = CM.arrive / quick
	sp.maxspeed = CM.speed * strength * quick
	sp.maxspeeddamp = CM.damp * strength * quick
	phys:Wake()
	phys:ComputeShadowControl(sp)
end

-- The trunk: a part is given the change of speed that takes it toward its place, as fast and as
-- hard as its strength allows, for itself and the load that hangs on it. Returns the impulse given,
-- which the caller takes from the parts the trunk pushes against.
local function Pull(phys, target, strength, quick, dt)
	local want = (target - phys:GetPos()) * (quick / CM.arrive)
	local top = CM.speed * strength * quick
	local l = want:Length()
	if l > top then want:Mul(top / l) end
	local dv = want - phys:GetVelocity()
	local cap = CM.accel * strength * dt
	l = dv:Length()
	if l > cap then dv:Mul(cap / l) end
	dv:Mul(phys:GetMass() * CM.trunkLoad)
	phys:Wake()
	phys:ApplyForceCenter(dv)
	return dv
end

-- A body that only lies (no posture, no convulsion). It breathes, if it breathes: the chest rises
-- and sinks against the pelvis and the head, a little more than in life so that it can be seen
-- [G]. And it stirs as it comes round. Called on the limbs' ticks.
local function Quiet(ctl, now, dt, pelvis, chest, lu, ru)
	local pp, cp = pelvis:GetPos(), chest:GetPos()
	local up = cp - pp
	if up:LengthSqr() < 1 then return true end
	up:Normalize()
	local left = lu:GetPos() - ru:GetPos()
	left = left - up * left:Dot(up)
	if left:LengthSqr() < 0.01 then return true end
	left:Normalize()
	local front = left:Cross(up)
	up = up + front * CM.trunkTilt
	up:Normalize()
	front = left:Cross(up)
	local head = Part(ctl, HEAD)
	if ctl.breath and head then
		local s = 0.5 - 0.5 * math.cos(((now * CM.breathHz + ctl.slot * 0.37) % 1) * 2 * math.pi)
		local axis = head:GetPos() - pp
		local len2 = axis:LengthSqr()
		if len2 > 100 then
			local t = Clamp((cp - pp):Dot(axis) / len2, 0.2, 0.8)
			local off = (cp - (pp + axis * t)):Dot(front)
			-- (where the chest rests is followed while the breath is out)
			if not ctl.rest then ctl.rest = off elseif s < 0.15 then ctl.rest = ctl.rest + (off - ctl.rest) * 0.25 end
			local imp = Pull(chest, cp + front * (ctl.rest + CM.breathLift * s - off), CM.breathStrength, CM.archQuick, dt)
			head:ApplyForceCenter(imp * -t * 0.5)
			pelvis:ApplyForceCenter(imp * -(1 - t * 0.5))
		end
	end
	if ctl.stir then
		if now >= (ctl.stirNext or 0) then
			ctl.stirNext = now + CM.stirEvery[1] + math.random() * (CM.stirEvery[2] - CM.stirEvery[1])
			ctl.stirUntil = now + CM.stirTime
			ctl.stirShape = math.random(#STIR)
			ctl.stirSide = math.random() < 0.5
		end
		if now < (ctl.stirUntil or 0) then
			-- (comes and goes)
			local env = math.sin((1 - (ctl.stirUntil - now) / CM.stirTime) * math.pi) * CM.stirStrength * (0.6 + 0.4 * ctl.stir)
			local shape = STIR[ctl.stirShape]
			for i = 1, #shape do
				local e = shape[i]
				local n, ly = e[1], e[4]
				if ctl.stirSide and MIRROR[n] then n, ly = MIRROR[n], -ly end
				local phys = Part(ctl, n)
				if phys then Shadow(phys, (e[2] == CHEST and cp or pp) + front * e[3] + left * ly + up * e[5], env * e[6], 1, dt) end
			end
		end
	end
	return true
end

-- A body whose heart has just stopped is let fall into the shape of one that holds nothing (ARREST
-- above). On the ground it lies on: along the trunk, across it, and down to where the ground is
-- under each part. A body that lies on its side is first let roll onto its back or its face,
-- whichever is nearer, as a limp body on its side goes.
local settleTr = { mask = MASK_SOLID_BRUSHONLY }
local settleAt = Vector()
local function GroundZ(x, y, z)
	settleTr.start, settleTr.endpos = Vector(x, y, z + 14), Vector(x, y, z - 50)
	local tr = util.TraceLine(settleTr)
	return tr.Hit and tr.HitPos.z or (z - 5)
end
local function SettleLog(ctl, now, fmt, ...)
	if not NT.TestLog or now < (ctl.settleLog or 0) then return end
	ctl.settleLog = now + 0.2
	NT.TestLog("    settle: " .. fmt, ...)
end
local function Settle(ctl, now, dt, pelvis, chest, lu, ru, gasping)
	local pp, cp = pelvis:GetPos(), chest:GetPos()
	local along = cp - pp
	along.z = 0
	local len = along:Length()
	-- (A trunk that stands on end or is propped up, sitting, kneeling or still on its way down:
	-- pinning its limbs to the ground would hold it there. It is left to fall, and the shape waits.)
	if len < 6 or cp.z - pp.z > CM.arrestProp then
		ctl.settleFrom, ctl.settleUntil = now, min(now + ctl.settleFor, ctl.settleBy)
		SettleLog(ctl, now, "the trunk is not down yet (%.1f long on the ground, chest %.1f above the pelvis): left to fall", len, cp.z - pp.z)
		return
	end
	along:Mul(1 / len)
	local across = Vector(-along.y, along.x, 0)
	local bl = lu:GetPos() - ru:GetPos()
	bl:Normalize()
	-- the body's left shoulder is on that side of it: -1 on its back, 1 on its face, between: on its side
	local s = bl:Dot(across)
	local faceUp = s < 0
	-- (It begins to roll when it lies well on its side and goes on until it lies well on its back or
	-- its face: a body at the edge between the two was rolled and shaped by turns, run p24b. When
	-- the time for rolling is over it is shaped as it lies; it is never left with nothing done.)
	local rolling = ctl.settleRolling
	if rolling then
		if s < -0.65 or s > 0.65 or now >= ctl.settleRollBy then rolling = nil end
	elseif s > -0.35 and s < 0.35 and now < ctl.settleRollBy then
		rolling = true
	end
	ctl.settleRolling = rolling
	if rolling then
		local front = bl:Cross(along)
		local turn = (along:Cross(front).z >= 0 and 1 or -1) * (faceUp and 1 or -1)
		for i = 1, 2 do
			local phys = i == 1 and pelvis or chest
			local axis = phys:WorldToLocalVector(along)
			local have = phys:GetAngleVelocity():Dot(axis) * turn
			if have < CM.arrestRoll then phys:AddAngleVelocity(axis * (turn * min(CM.arrestRoll - have, CM.arrestRoll * 8 * dt))) end
			phys:Wake()
		end
		ctl.settleFrom, ctl.settleUntil = now, min(now + ctl.settleFor, ctl.settleBy)
		SettleLog(ctl, now, "on its side (%.2f), rolling onto its %s", s, faceUp and "back" or "face")
		return
	end
	local lat = faceUp and -across or across
	local t, left = now - ctl.settleFrom, ctl.settleUntil - now
	-- (comes on at once, lets go over the last part: then the body lies by itself)
	local env = ctl.settleStrength * min(t / 0.15, 1) * min(left / (ctl.settleFor * 0.4), 1)
	if env <= 0 then return end
	settleTr.filter = ctl.rag
	if NT.TestLog and now >= (ctl.settleLog or 0) then
		SettleLog(ctl, now, "%.2f s, %s, face %s (%.2f) | above the ground: pelvis %.1f chest %.1f | speed pelvis %.0f chest %.0f", t, ctl.settleFresh and "falling open" or "letting go",
			faceUp and "up" or "down", s, pp.z - GroundZ(pp.x, pp.y, pp.z), cp.z - GroundZ(cp.x, cp.y, cp.z), pelvis:GetVelocity():Length(), chest:GetVelocity():Length())
	end
	local mirror = ctl.settleSide < 0
	local shape = faceUp and ARREST or ARREST_DOWN
	local quick = ctl.settleQuick
	for i = 1, #shape do
		local e = shape[i]
		if ctl.settleFresh or not e[6] then
			local n, ly = e[1], e[4]
			if mirror then n, ly = MIRROR[n], -ly end
			local phys = Part(ctl, n)
			if phys then
				local a = e[2] == CHEST and cp or pp
				local x, y = a.x + along.x * e[3] + lat.x * ly, a.y + along.y * e[3] + lat.y * ly
				-- (A part that is in the air comes down; one that lies is slid along the ground and
				-- not pressed into it: pressed down, a hand or a foot is pinned where it is and
				-- nothing moves, which is what the limbs of a body on its face did, run p24c.)
				local z = GroundZ(x, y, a.z) + LIES[n]
				local cz = phys:GetPos().z
				if cz - z < 4 then z = cz end
				settleAt:SetUnpacked(x, y, z)
				Shadow(phys, settleAt, env * e[5], quick, dt)
			end
		end
	end
	-- the head: down, to the side away from the arm that is flung out, and the face turned that way
	local head = not gasping and Part(ctl, HEAD)
	if head then
		local d = (head:GetPos() - cp):Dot(along)
		local side = mirror and 7 or -7
		local x, y = cp.x + along.x * d + lat.x * side, cp.y + along.y * d + lat.y * side
		settleAt:SetUnpacked(x, y, GroundZ(x, y, cp.z) + 4.5)
		Shadow(head, settleAt, env * 0.8, quick, dt)
		-- (turning about the body's length in its own sense turns the face to its left)
		local axis = head:WorldToLocalVector(along)
		local turn = mirror and 1 or -1
		local have = head:GetAngleVelocity():Dot(axis) * turn
		if have < CM.arrestHead then head:AddAngleVelocity(axis * (turn * min(CM.arrestHead - have, CM.arrestHead * 8 * dt) * env / ctl.settleStrength)) end
	end
end

-- Called with every tick for every driven body. The limbs are drawn on some ticks only (`limbs`:
-- every `every`-th, the bodies taking turns: shadow control is as steady at half the rate and
-- costs half); what works against the weight of the whole body, the bow of the trunk, on all.
local function Drive(ctl, now, dt, limbs, every)
	local pelvis, chest = Part(ctl, PELVIS), Part(ctl, CHEST)
	local lu, ru = Part(ctl, L_UPPER), Part(ctl, R_UPPER)
	if not pelvis or not chest or not lu or not ru then return false end
	local pose, env, side
	local quick = 1
	local sz = ctl.sz
	if ctl.gaspUntil and not sz then
		if now >= ctl.gaspUntil then
			ctl.gaspUntil, ctl.gaspRest = nil, nil
			return ctl.level > 0
		end
		-- (rises quickly, sinks back)
		local f = 1 - (ctl.gaspUntil - now) / CM.gaspTime
		pose, env, side = GASP, f < 0.35 and f / 0.35 or (1 - (f - 0.35) / 0.65), 1
		-- (the limbs of a body that is still falling open go on falling through a gasp)
		if limbs and ctl.settleUntil and now < ctl.settleUntil then Settle(ctl, now, dt * every, pelvis, chest, lu, ru, true) end
	elseif sz then
		pose, env, side, quick = SeizurePose(sz, now, dt, ctl.blend or 1)
		ctl.env = max(env, 0.06)
		if not pose or env <= 0.01 then return true end
	elseif ctl.settleUntil and now < ctl.settleUntil then
		if limbs then Settle(ctl, now, dt * every, pelvis, chest, lu, ru) end
		return true
	else
		-- a posture: evoked in full, at rest a share, eased in and out
		local want = 0
		if ctl.level > 0 then
			want = (0.4 + 0.6 * ctl.level) * ((now < ctl.evokedUntil) and 1 or CM.restShare)
			if ctl.fencing then want = 1 end
		end
		local rate = want > ctl.env and CM.rise or CM.ease
		-- (by the time that has really passed: a posture at rest is not looked at with every tick)
		local passed = min(now - (ctl.envT or now - dt), 0.1)
		ctl.envT = now
		ctl.env = math.Approach(ctl.env, want, rate * passed)
		if ctl.env < 0.01 then
			if want <= 0 and (ctl.breath or ctl.stir) then
				if limbs then return Quiet(ctl, now, dt * every, pelvis, chest, lu, ru) end
				return true
			end
			return want > 0
		end
		pose, env, side = POSES[ctl.kind], ctl.env, ctl.side
		if not pose then return false end
		quick = pose.quick or 1
	end

	-- (a tick on which no limb is drawn, no bow is held up and no beat begins: nothing to do)
	if not limbs and not ctl.wasBowing and not (sz and sz.kick) then return true end

	-- the body's own frame
	local pp, cp = pelvis:GetPos(), chest:GetPos()
	local up = cp - pp
	if up:LengthSqr() < 1 then return true end
	up:Normalize()
	local left = lu:GetPos() - ru:GetPos()
	left = left - up * left:Dot(up)
	if left:LengthSqr() < 0.01 then return true end
	left:Normalize()
	local front = left:Cross(up)
	-- (the chest part sits nearer the back than the pelvis does: the line between them leans by
	-- some twelve degrees against the line of the body. Without this, "straight legs" pointed
	-- into the air over a body on its back.)
	up = up + front * CM.trunkTilt
	up:Normalize()
	front = left:Cross(up)

	-- the line the body lies along, from the feet to the head, for what must stay on the ground
	local head = Part(ctl, HEAD)
	local lf, rf = Part(ctl, L_FOOT), Part(ctl, R_FOOT)
	local lineUp, lineLeft, lineFront, lineAt
	if head and lf and rf then
		local feet = (lf:GetPos() + rf:GetPos()) * 0.5
		local axis = head:GetPos() - feet
		if axis:LengthSqr() > 400 then
			axis:Normalize()
			local l = left - axis * left:Dot(axis)
			if l:LengthSqr() > 0.01 then
				l:Normalize()
				lineUp, lineLeft, lineFront = axis, l, l:Cross(axis)
				lineAt = feet + axis * (pp - feet):Dot(axis)
			end
		end
	end

	local mirror = side < 0
	for i = 1, #pose do
		local e = pose[i]
		local n, ly = e[1], e[4]
		if mirror and MIRROR[n] then n, ly = MIRROR[n], -ly end
		local phys = limbs and Part(ctl, n)
		if phys then
			local pos
			if e[7] and lineUp then
				local at = phys:GetPos()
				pos = lineAt + lineLeft * ly + lineUp * e[5]
				local lift = (n == L_FOOT or n == R_FOOT) and Clamp((at - pos):Dot(lineUp) / 4, 0, 3) or 0
				pos = pos + lineFront * (at - pos):Dot(lineFront)
				pos.z = pos.z + lift
			else
				pos = (e[2] == CHEST and cp or pp) + front * e[3] + left * ly + up * e[5]
			end
			local w = e[6]
			if sz and sz.asym and ly ~= 0 then w = w * (1 + (ly > 0 and sz.asym or -sz.asym)) end
			Shadow(phys, pos, env * w, quick, dt * every)
		end
	end
	-- the trunk: brought forward of the line from the feet to the head, so that the body bows. The
	-- head and the feet take the push back, shared by the lever each has: on its back the body
	-- stands on them as a bridge, on its side it bends like a bow, and it never leaves the ground.
	ctl.bowing = false
	if pose.archChest and head and (limbs or ctl.wasBowing) then
		-- A gasp: the chest is heaved straight up from where it rests, whichever way the body lies,
		-- and the head and the feet are pressed down by as much. (It was a pull toward a place
		-- worked out in the body's own frame, in front of the line from the feet to the head. With
		-- the trunk twisted or the knees drawn up that place lay to the side, and the pull rolled
		-- the body out of its shape and onto its side, run p24g; on a body on its face it came
		-- out at the feet and kicked them into the air, run p24b. The push must not go to the
		-- pelvis: that pins the trunk, and the chest rose 1.4 units of the 7, run p24h.)
		ctl.gaspRest = ctl.gaspRest or cp.z
		local imp = Pull(chest, Vector(cp.x, cp.y, ctl.gaspRest + pose.arch * env), max(env, 0.4) * CM.archStrength, CM.archQuick, dt)
		imp.x, imp.y = 0, 0
		if lf and rf then
			head:ApplyForceCenter(imp * -0.7)
			imp:Mul(-0.15)
			lf:ApplyForceCenter(imp)
			rf:ApplyForceCenter(imp)
		else
			head:ApplyForceCenter(imp * -1)
		end
		ctl.bowing = true
	elseif pose.arch and head and (limbs or ctl.wasBowing) then
		if lf and rf then
			local feet = (lf:GetPos() + rf:GetPos()) * 0.5
			local axis = head:GetPos() - feet
			local len2 = axis:LengthSqr()
			if len2 > 400 then
				-- (not before the legs are out: the push that goes into the feet would pin them where
				-- they stand, knees up, and the body would never straighten)
				local reach = (pp - feet):Dot(axis) / math.sqrt(len2)
				local lift = pose.arch * env * Clamp((reach - 26) / 8, 0, 1)
				-- (a posture bows only at its severe end; a tonic phase does in full)
				if not sz then lift = lift * Clamp((ctl.level - 0.5) * 2, 0, 1) end
				-- (held up with every tick while it is being shown; a posture at rest is looked at on
				-- the limbs' ticks only, and lies nearly flat between them)
				ctl.bowing = lift > 0.3 and (sz ~= nil or ctl.fencing or now < ctl.evokedUntil)
				local hold = max(env, 0.4) * CM.archStrength
				local function Bow(part, at, amount)
					local t = Clamp((at - feet):Dot(axis) / len2, 0.1, 0.9)
					local imp = Pull(part, feet + axis * t + front * amount, hold, CM.archQuick, dt)
					head:ApplyForceCenter(imp * -t)
					imp:Mul(-(1 - t) * 0.5)
					lf:ApplyForceCenter(imp)
					rf:ApplyForceCenter(imp)
				end
				Bow(pelvis, pp, lift)
				Bow(chest, cp, lift * 0.85)
			end
		end
	end
	-- the neck: the head taken back
	if limbs and pose.neck and head then
		Shadow(head, cp + up * (head:GetPos() - cp):Dot(up) - front * pose.neck, env * 0.8, 1, dt * every)
	end
	-- the trunk in a beat: the chest and the head thrown forward with the contraction, the pelvis
	-- pressed back by as much
	if sz and sz.kick and (pose.heave or pose == FOCAL_FLEX) then
		sz.kick = nil
		local v = CM.heave * env * (pose.heave and 1 or 0.5)
		local imp = front * (v * chest:GetMass())
		chest:ApplyForceCenter(imp)
		if head then
			local hi = front * (v * 1.3 * head:GetMass())
			head:ApplyForceCenter(hi)
			imp:Add(hi)
		end
		pelvis:ApplyForceCenter(-imp)
	end
	return true
end

hook.Add("Think", "NT_Motor", function()
	local n = #list
	if n == 0 then return end
	local now, dt, tick = CurTime(), FrameTime(), engine.TickCount()
	for i = n, 1, -1 do
		local ctl = list[i]
		local keep = true
		if not IsValid(ctl.rag) then keep = false
		else
			-- (A body whose record has gone is let go. The record's own closing does this too, but a
			-- record that closes when its character respawns no longer knows the body it left
			-- behind: seen as a posture held on an abandoned ragdoll for as long as it lay there.)
			if now - (ctl.seen or ctl.born) > 1 and not ctl.gaspUntil then
				ctl.level, ctl.fencing, ctl.hold, ctl.sz, ctl.breath, ctl.stir = 0, false, nil, nil, nil, nil
			end
			-- How often the limbs are drawn. Getting into a shape takes every tick: the first second
			-- of a posture that comes out, of a tonic phase, of the posture of a knockout, and the
			-- contraction of every beat. Holding it takes every other tick, a posture at rest a
			-- quarter of them. (Drawn on alternate ticks throughout, arms did not reach the chest
			-- in time and a beat lost half its travel: runs pre22c, pre22d.)
			local sz = ctl.sz
			local every
			if sz then
				every = (now < (sz.pullUntil or 0) or (sz.phase == "tonic" and now - sz.t0 < 1.2)) and 1 or 2
			elseif ctl.gaspUntil or now < (ctl.settleUntil or 0) then
				every = (ctl.settleFresh and not ctl.gaspUntil) and 1 or 2
			elseif ctl.fencing or now < ctl.evokedUntil or ctl.env > ctl.level * CM.restShare + 0.1 then
				every = now < (ctl.fastUntil or 0) and 1 or 2
			elseif ctl.level <= 0 and (ctl.breath or ctl.stir) then
				every = 2
			else
				every = 4
			end
			local limbs = (tick + ctl.slot) % every == 0
			if limbs or ctl.wasBowing or ctl.sz or ctl.gaspUntil then
				keep = Drive(ctl, now, dt, limbs, every)
				ctl.wasBowing = ctl.bowing
			end
		end
		if not keep and not ctl.hold and not ctl.gaspUntil then
			if IsValid(ctl.rag) then
				ctlOf[ctl.rag] = nil
				-- (limbs that were held still have gone to sleep where they were: let them fall)
				for _, phys in pairs(ctl.parts) do
					if phys and IsValid(phys) then phys:Wake() end
				end
			end
			table.remove(list, i)
		end
	end
end)

-- Z-City asks before it lets a ragdolled player move the ragdoll, and before it lets one get up.
hook.Add("CanControlFake", "NT_Motor", function(ply, rag)
	local ctl = ctlOf[rag]
	if ctl and (ctl.env > 0.05 or ctl.hold) then return false end
end)

hook.Add("Should Fake Up", "NT_Motor", function(ply)
	local org = ply.organism
	local st = istable(org) and NT.Get(org)
	if not st or not NT.Enabled() then return end
	local rag = ply.FakeRagdoll
	local ctl = IsValid(rag) and ctlOf[rag]
	if ctl and (ctl.env > 0.05 or ctl.hold) then return false end
	-- legs that do not carry, or no balance at all
	if min(st.legL, st.legR) < CM.standMotor or st.balance < CM.standBalance then return false end
end)

-- What hurts a posturing body brings the posture out.
hook.Add("HomigradDamage", "NT_MotorStimulus", function(ply)
	if IsValid(ply) and ply:IsPlayer() then M.Stimulus(ply, 1) end
end)

hook.Add("NT_Closed", "NT_Motor", function(ply)
	local rag = IsValid(ply) and ply.FakeRagdoll
	local ctl = IsValid(rag) and ctlOf[rag]
	if ctl then ctl.level, ctl.fencing, ctl.hold, ctl.sz, ctl.breath, ctl.stir = 0, false, nil, nil, nil, nil end
end)

-- Z-City knocks characters out for reasons of its own (pain, shock, blood loss), and those have no
-- neurological record. They breathe too: twice a second, every character that lies unconscious
-- with working lungs and a beating heart and has no record is given the breathing of one that has.
timer.Create("NT_BreathWatch", 0.5, 0, function()
	if not NT.Enabled() or not Z.has.physnum then return end
	local now = CurTime()
	for _, ply in ipairs(player.GetAll()) do
		local rag = ply.FakeRagdoll
		local org = ply.organism
		if IsValid(rag) and istable(org) and ply:Alive() and not NT.Get(org) then
			if org.otrub and org.lungsfunction ~= false and not org.heartstop then
				local ctl = Controller(rag, ply)
				if ctl then ctl.seen, ctl.breath = now, true end
			else
				local ctl = ctlOf[rag]
				if ctl then ctl.breath = nil end
			end
		end
	end
end)
