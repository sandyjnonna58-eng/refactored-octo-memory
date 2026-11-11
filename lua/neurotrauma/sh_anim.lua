-- The animation state of a character: one value that says what its body is doing. It is decided
-- on the server from the neurological and the circulatory state (sv_anim.lua), sent to every
-- client that sees the character (sv_net.lua), and read by everything that moves the body: the
-- ragdoll motor (sv_motor.lua), the pose layers a client draws (cl_pose.lua), Z-City's questions
-- whether a character may get up or steer its ragdoll.
--
-- Exactly one mode at a time. Every mode has a priority; of the modes that apply, the one with
-- the highest priority is the state, and nothing of a lower priority, ordinary movement included,
-- is drawn over it. From CRITICAL upward the state is a trauma critical response: the body is
-- down, it does not get up and it cannot be steered until the state has gone.
--
--   priority  mode                  what a bystander sees
--      0      NORMAL                nothing
--     10      INJURED               on its feet: the head hangs, the trunk sways
--     20      MOTOR_IMPAIRED        on its feet: a side that hangs, a broad unsteady stance
--     30      FOCAL_SEIZURE         on its feet: one arm in a beat and the head turned to it, or a
--                                   fixed stare and a hand that fumbles
--     40      CRITICAL_UNCONSCIOUS  down and limp
--     50      POSTICTAL             down and limp after a convulsion, coming round
--     60      ABNORMAL_POSTURING    down: flexor, extensor, or the posture of a knockout
--     70      SEIZURE               down: stiff and arched, then beating
--     80      CRITICAL_COLLAPSE     going down: the moment a critical state takes a standing character
--     90      CARDIAC_ARREST        down, fallen open and still; in some a few jerks, gasps that space out
--     95      TERMINAL_COLLAPSE     down, all tone gone: circulation stopped and no brainstem left
--                                   to come back, or a wound that left no moment to live through
--    100      (FULL_RAGDOLL)        a dead body. Nothing of this module moves it.
--
-- The intensity of a mode runs from 0 to 1: 0.25 can be noticed, 0.5 is clearly abnormal, 0.75 is
-- severe, 1 is all the posture there is. A mode is not entered below the intensity at which it can
-- be seen (C.Anim.floor): a state that is announced is a state that shows.

local NT = NeuroTrauma
NT.Anim = NT.Anim or {}
local A = NT.Anim

A.Mode = {
	NORMAL = 0, INJURED = 1, MOTOR_IMPAIRED = 2, FOCAL_SEIZURE = 3, CRITICAL_UNCONSCIOUS = 4, POSTICTAL = 5,
	ABNORMAL_POSTURING = 6, SEIZURE = 7, CRITICAL_COLLAPSE = 8, CARDIAC_ARREST = 9, TERMINAL_COLLAPSE = 10,
}
A.names = {
	[0] = "NORMAL", "INJURED", "MOTOR_IMPAIRED", "FOCAL_SEIZURE", "CRITICAL_UNCONSCIOUS", "POSTICTAL",
	"ABNORMAL_POSTURING", "SEIZURE", "CRITICAL_COLLAPSE", "CARDIAC_ARREST", "TERMINAL_COLLAPSE",
}
A.priority = { [0] = 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95 }
A.FULL_RAGDOLL = 100
A.CRITICAL = 40

function A.Priority(mode) return A.priority[mode or 0] or 0 end
function A.Critical(mode) return (A.priority[mode or 0] or 0) >= A.CRITICAL end

------------------------------------------------------------------------------------------
-- Two modes of phase 23, between the standing ones and the critical ones:
--
--     35      STAGGER               on its feet and losing it: the trunk goes over, the knees
--                                   give, steps are taken that were not meant, the arms go out.
--                                   It ends caught, or on the ground (sv_collapse.lua)
--     38      RECOVERING            down and coming round: the head lifts, an arm pushes, a knee
--                                   is drawn up, and falls back (sv_motor.lua)
------------------------------------------------------------------------------------------
A.Mode.STAGGER, A.Mode.RECOVERING = 11, 12
A.names[11], A.names[12] = "STAGGER", "RECOVERING"
A.priority[11], A.priority[12] = 35, 38

-- How far a stagger has gone, 0..1, by the share of its time that has passed. It goes over
-- quickly and stays over: whether it is caught or ends on the ground is decided at its end.
function A.StaggerEnvelope(f)
	if f <= 0 then return 0 end
	if f >= 0.6 then return 1 end
	return (f / 0.6) ^ 0.8
end

-- The pose of a stagger, for both sides of the network (a client draws it; the server puts it on
-- its own bones so that the ragdoll is made in it). oct: where the body is going, in eighths of a
-- turn from the way it faces (0 forward, 2 left, 4 backward, 6 right). w: the envelope. peak: how
-- far this stagger goes. Returns bone key -> { p, y, r, z } (angles in the bone's own pitch, yaw,
-- roll, as measured: docs/NEUROTRAUMA_ANIMATION_MAP.md; z: units the pelvis is lowered).
local pose = {}
local function E(key, p, y, r, z)
	local e = pose[key]
	if not e then e = {} pose[key] = e end
	e.p, e.y, e.r, e.z = p, y, r, z
end
function A.StaggerPose(oct, w, peak, side)
	local CP = NeuroTrauma.Config.Pose
	local a = math.rad((oct or 0) * 45)
	local fore, left = math.cos(a), math.sin(a)
	local k = w * peak
	-- the trunk goes over (spine yaw > 0 bends forward, pitch > 0 tilts to the right)
	local lean = CP.staggerLean * k
	E("Spine", -lean * left * 0.7, lean * fore * 0.7, 0)
	E("Spine1", -lean * left * 0.5, lean * fore * 0.5, 0)
	-- the knees give: the hips sink and both knees bend by what that takes (thigh yaw < 0 lifts
	-- the knee forward, calf yaw > 0 bends it); the leg on the side of the fall gives more
	local drop = CP.staggerDrop * k * k
	local bend = math.deg(math.acos(math.Clamp(1 - drop / 35, 0.2, 1)))
	local moreL, moreR = 1 + 0.35 * math.max(left, 0), 1 + 0.35 * math.max(-left, 0)
	E("Pelvis", 0, 0, 0, -drop)
	E("LThigh", 0, -bend * moreL, 0) E("LCalf", 0, bend * 1.9 * moreL, 0)
	E("RThigh", 0, -bend * moreR, 0) E("RCalf", 0, bend * 1.9 * moreR, 0)
	-- the arms go out (upper arm pitch > 0 moves the right arm out, < 0 the left)
	local arms = CP.staggerArms * k
	E("LUpperArm", -arms, 0, 0) E("RUpperArm", arms, 0, 0)
	E("LForearm", 0, -arms * 0.5, 0) E("RForearm", 0, -arms * 0.5, 0)
	-- the head is left behind
	E("Head1", -lean * left * 0.3, lean * fore * 0.25, 0)
	return pose
end

-- The critical states by family, in the words of the request that made them rules: a critical
-- response to a head injury, a cardiac arrest, a terminal state. Every critical mode belongs to
-- one; nothing below priority 40 does.
function A.Family(mode)
	local p = A.priority[mode or 0] or 0
	if p >= 95 then return "TERMINAL_DEATH" end
	if p >= 90 then return "CARDIAC_ARREST" end
	if p >= A.CRITICAL then return "HEAD_TRAUMA_CRITICAL" end
	return nil
end
