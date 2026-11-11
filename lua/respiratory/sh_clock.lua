-- The breathing cycle as arithmetic, shared by both sides and by the offline check: the shape of
-- one breath, where a clock stands at a time, and how fast and deep a character breathes for what
-- is asked of it. Nothing here touches an entity; the server keeps the clocks (sv_clock.lua) and
-- clients run them forward (cl_net.lua).
--
-- A clock: { t, phase, rate, depth, mode, sym }
--     phase   0..1 through one breath, as it stood at the game time t
--     rate    breaths a minute; depth: 1 is a quiet breath
--     mode    BREATHING, HELD (on purpose: the lungs stay full), STOPPED (no breath: they rest)
--     sym     the breath is an even rise and fall (the brain module's breath of an unconscious
--             body, which the clock then follows) instead of in, out and a pause
--
-- Assumptions, all of them numbers in sh_config.lua (C.Breath) and none of them medicine: a breath
-- at rest is 40 % in, 44 % out and a pause; the pause is gone by 26 breaths a minute; breathing
-- out starts quickly and ends slowly; what asks for more air is exertion (read off Z-City's heart
-- rate and stamina) and a falling oxygen store; lungs that can do less are breathed with faster
-- and shallower.

local RS = HemoRespiratory
RS.Clock = RS.Clock or {}
local CK = RS.Clock
local C = RS.Config
local floor, cos, pi, min, max, exp = math.floor, math.cos, math.pi, math.min, math.max, math.exp

CK.BREATHING, CK.HELD, CK.STOPPED = 0, 1, 2
CK.ModeName = { [0] = "breathing", "held", "stopped" }

-- What a character's breathing is like, in one word (the server says which: sv_state.lua). Appended
-- to, never reordered: the number of a label is what is sent.
RS.Labels = { "NORMAL", "FAST", "SHALLOW", "IRREGULAR", "LABOURED", "OBSTRUCTED", "AGONAL", "HELD", "NOT_BREATHING" }
RS.LabelIdx = {}
for i, l in ipairs(RS.Labels) do RS.LabelIdx[l] = i end

local function Clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function Smooth(t) t = Clamp(t, 0, 1) return t * t * (3 - 2 * t) end
CK.Clamp, CK.Smooth = Clamp, Smooth

-- The parts of one breath at a rate: the share spent breathing in and the share breathing out
-- (what is left is the pause after it).
function CK.Shares(rate)
	local B = C.Breath
	local pause = B.pauseRest * Clamp((B.pauseGone - rate) / (B.pauseGone - B.pauseFrom), 0, 1)
	local inn = B.inShare * (1 - pause)
	return inn, 1 - pause - inn
end

-- How full the breath is at a phase: 0 out .. 1 in. Smooth everywhere: it leaves and reaches both
-- ends without a jerk.
function CK.Wave(phase, rate, sym)
	phase = phase - floor(phase)
	if sym then return 0.5 - 0.5 * cos(2 * pi * phase) end
	local a, b = CK.Shares(rate)
	if phase < a then return 0.5 - 0.5 * cos(pi * phase / a) end
	if phase < a + b then return 0.5 + 0.5 * cos(pi * ((phase - a) / b) ^ C.Breath.outCurve) end
	return 0
end

-- Where a clock's phase stands at a time.
function CK.PhaseAt(c, now)
	if c.mode ~= CK.BREATHING then return c.phase end
	local p = c.phase + c.rate / 60 * (now - c.t)
	return p - floor(p)
end

-- What a clock shows at a time when nothing eases it: how full, 0..1.
function CK.Fill(c, now)
	if c.mode == CK.HELD then return C.Breath.heldAt end
	if c.mode ~= CK.BREATHING then return 0 end
	return CK.Wave(CK.PhaseAt(c, now), c.rate, c.sym)
end

-- How fast and how deep, for what is asked. s: the state as sv_zcity.lua reads it (heart rate,
-- stamina, oxygen, what the lungs can do); control: what the brain still drives of it (0..1, nil: all);
-- rf, df: what others have asked of rate and depth (RS.Modify). Returns rate, depth, and how much
-- more air is wanted (0..1).
function CK.Target(s, control, rf, df)
	local B = C.Breath
	local rest, deep = C.sv.rate:GetFloat(), C.sv.depth:GetFloat()
	local work = Clamp(((s.heartRate or B.hrRest) - B.hrRest) / (B.hrFull - B.hrRest), 0, 1)
	work = max(work, B.staminaShare * (1 - Clamp(s.stamina or 1, 0, 1)))
	local air = Clamp((B.o2Ok - (s.oxygen or 1)) / (B.o2Ok - B.o2Low), 0, 1)
	local want = max(work, air)
	local rate = rest + (B.rateDemand - rest) * want ^ 0.8
	local depth = deep + (B.depthDemand - deep) * want
	-- lungs that can do less: faster and shallower
	local can = Clamp(s.capacity or 1, 0, 1)
	rate = rate * (1 + B.labouredRate * (1 - can))
	depth = depth * (1 - B.labouredDepth * (1 - can))
	-- what the brain no longer drives is breathed shallower (its pauses and stops come as stops: sv_clock.lua)
	if control then depth = depth * (0.5 + 0.5 * Clamp(control, 0, 1)) end
	rate = Clamp(rate * (rf or 1), B.rateMin, B.rateMax)
	depth = Clamp(depth * (df or 1), B.depthMin, B.depthMax)
	return rate, depth, want
end

-- A value on its way to another, the same whatever the length of the steps it is taken in.
function CK.Toward(v, target, dt, tau)
	if tau <= 0 then return target end
	return target + (v - target) * exp(-dt / tau)
end
