-- Cardiology: a labelled view of the circulation that Z-City simulates, and the few couplings
-- between it and the brain.
--
-- Z-City owns the heart: its organism keeps a heart rate (heartbeat), a blood pressure (pulse, 70
-- at rest), the blood volume, the oxygen store, a shock value, damage to the heart muscle and the
-- flag that says the heart has stopped; it stops the heart for blood loss, lack of oxygen, brain
-- failure, cold, heat and a runaway rate, and restarts it through its own CPR and adrenaline. A
-- second heart model beside that one would have to fight it. This file therefore:
--
--   reads     those fields and gives them names and states (Cardio.GetState, GetHeartState)
--   couples   the brain to the heart through Z-City's own inputs: a convulsion drives the
--             sympathetic system (adrenaline input), rising pressure in the skull slows the heart
--             (a ceiling on the rate: the Cushing response [S: S7]); brainstem failure stopping
--             the heart was already there (sv_brain.lua)
--   records   why an arrest happened, whether compressions are being given, the return of
--             circulation and the time after it. An arrest is not a seizure: it has its own
--             plan (sv_cardioresp.lua) and its own states here.
--   offers    the calls other code may want: stress, shock, an arrest, an attempt to restart.
--             The last two write Z-City's flag; nothing else in the module does.
--
-- States are descriptions for the panel and the API, derived from the numbers; they change nothing.
-- What kind of rhythm an arrest has cannot be known: Z-City models no rhythm. The label names the
-- cause as Z-City's rules give it: a runaway rate is its "fibrillation"; everything else is a heart
-- that still could beat but has nothing to pump or no drive, which medicine files under pulseless
-- electrical activity and asystole, the arrests that do not answer to a shock [S: K7 K8].

local NT = NeuroTrauma
Cardio = Cardio or {}
NT.Cardio = Cardio
local C, Z, E = NT.Config, NT.ZC, NT.E
local CC = C.Cardio
local Clamp, min, max = math.Clamp, math.min, math.max

Cardio.States = { "NORMAL", "STRESSED", "TACHYCARDIA_LIKE", "BRADYCARDIA_LIKE", "UNSTABLE_RHYTHM", "HYPOPERFUSION", "SHOCK", "CRITICAL", "CARDIAC_ARREST", "ROSC", "POST_ARREST" }

local function Org(who)
	if istable(who) and not isentity(who) then return who end
	return IsValid(who) and Z.Org(who) or nil
end

-- The numbers, as Z-City keeps them, with plain names. All shares are of normal.
function Cardio.Read(who)
	local org = Org(who)
	if not org then return nil end
	local o2 = istable(org.o2) and org.o2 or nil
	local t = {
		heartRate = tonumber(org.heartbeat) or 0,
		pressure = tonumber(org.pulse) or 0,                                  -- Z-City: 70 at rest
		bloodPressure = Clamp((tonumber(org.pulse) or 0) / 70, 0, 1.5),
		circulatingVolume = Clamp((tonumber(org.blood) or 5000) / 5000, 0, 1.2),
		oxygenSaturation = o2 and Clamp((tonumber(o2[1]) or 0) / (tonumber(o2.range) or 30), 0, 1) or 1,
		shock = tonumber(org.shock) or 0,
		myocardium = 1 - Clamp(tonumber(org.heart) or 0, 0, 1),
		adrenaline = tonumber(org.adrenaline) or 0,
		temperature = tonumber(org.temperature) or 36.7,
		cardiacArrest = org.heartstop == true,
		breathing = org.lungsfunction ~= false,
	}
	-- what reaches the tissues: pressure with the plateau the vessels keep [P: K12]
	t.perfusion = t.cardiacArrest and min(t.pressure / C.Vascular.plateau, 0.3) or Clamp(t.pressure / C.Vascular.plateau, 0, 1)
	t.cardiacOutput = t.cardiacArrest and 0 or Clamp(t.bloodPressure * t.myocardium, 0, 1)
	t.myocardialStress = Clamp(max((t.heartRate - 110) / 150, 0) + (1 - t.oxygenSaturation) * 0.6 + (1 - t.myocardium) * 0.5, 0, 1)
	-- Z-City stops the heart when its rate passes 300
	t.arrhythmiaRisk = Clamp((t.heartRate - 170) / 130, 0, 1)
	t.respiratoryCompromise = Clamp((1 - t.oxygenSaturation) * 1.2 + (t.breathing and 0 or 0.4), 0, 1)
	local st = NT.Get(org)
	t.rosc = st and st.rosc and (CurTime() - st.rosc.t) or nil
	t.downTime = st and st.arrestSince and (CurTime() - st.arrestSince) or nil
	t.cpr = st and st.cpr and (CurTime() - st.cpr.last < CC.cprGap) or false
	t.arrestCause = st and st.arrestCause or nil
	return t
end

-- One label for the whole. Blood loss does not announce itself by a fast pulse and a low pressure
-- in step, as the classic table has it [S: K4]; the label looks at pressure, volume and oxygen
-- together and names the worst.
function Cardio.Classify(t)
	if not t then return "NORMAL" end
	if t.cardiacArrest then return "CARDIAC_ARREST" end
	if t.rosc then
		if t.rosc < CC.roscTime then return "ROSC" end
		if t.rosc < CC.postArrest then return "POST_ARREST" end
	end
	if t.perfusion < 0.45 or t.oxygenSaturation < 0.3 then return "CRITICAL" end
	if t.circulatingVolume < 0.6 or t.bloodPressure < 0.6 then return "SHOCK" end
	if t.perfusion < 0.9 or t.oxygenSaturation < 0.6 then return "HYPOPERFUSION" end
	if t.arrhythmiaRisk > 0.4 then return "UNSTABLE_RHYTHM" end
	if t.heartRate > 130 then return "TACHYCARDIA_LIKE" end
	if t.heartRate < 50 then return "BRADYCARDIA_LIKE" end
	if t.heartRate > 100 or t.adrenaline > 0.5 or t.shock > 15 then return "STRESSED" end
	return "NORMAL"
end

-- Cardio.GetState(ply) -> label, numbers
function Cardio.GetState(who)
	local t = Cardio.Read(who)
	return Cardio.Classify(t), t
end

-- Cardio.GetHeartState(ply) -> a description of the heart's own action
function Cardio.GetHeartState(who)
	local t = Cardio.Read(who)
	if not t then return "unknown" end
	if t.cardiacArrest then
		local cause = t.arrestCause or "unknown cause"
		if cause == "runaway rate" then return "no output: fibrillation-like (" .. cause .. ")" end
		return "no output: pulseless or asystole-like (" .. cause .. ")"
	end
	if t.arrhythmiaRisk > 0.4 then return string.format("unstable, %d per minute", t.heartRate) end
	if t.heartRate > 130 then return string.format("fast, %d per minute", t.heartRate) end
	if t.heartRate < 50 then return string.format("slow, %d per minute", t.heartRate) end
	return string.format("regular, %d per minute", t.heartRate)
end

-- Why Z-City stopped this heart, read from its own rules at the moment it did.
function Cardio.Cause(org, st)
	local brain = tonumber(org.brain) or 0
	local temp = tonumber(org.temperature) or 36.7
	if (tonumber(org.heartbeat) or 0) > 300 or (st and st.lastRate or 0) > 290 then return "runaway rate" end
	if brain >= 0.6 then return "brain failure" end
	if temp < 28 then return "cold" end
	if temp > 42 then return "heat" end
	if (tonumber(org.heart) or 0) >= 0.9 then return "wound of the heart" end
	if (tonumber(org.blood) or 5000) < 2600 then return "blood loss" end
	local o2 = istable(org.o2) and tonumber(org.o2[1]) or 30
	if o2 < 8 then return "lack of oxygen" end
	-- (Z-City's pressure falls with its brain damage and the heart stops when the pressure is gone,
	-- which can be before the brain value itself reaches Z-City's own limit)
	if brain >= 0.45 or (st and (st.stemStress or 0) >= 0.8) then return "brain failure" end
	return "unknown cause"
end

------------------------------------------------------------------------------------------
-- Calls for other code
------------------------------------------------------------------------------------------
-- A push on the sympathetic system (fear, pain, exertion, a convulsion): Z-City's adrenaline input.
function Cardio.ApplyStress(who, amount)
	local org = Org(who)
	if not org or not isnumber(org.adrenalineAdd) then return false end
	org.adrenalineAdd = Clamp(org.adrenalineAdd + (amount or 0.3), -4, 4)
	return true
end

-- Circulatory shock from outside the model: Z-City's shock value.
function Cardio.ApplyShock(who, amount)
	local org = Org(who)
	if not org or not isnumber(org.shock) then return false end
	org.shock = Clamp(org.shock + (amount or 10), 0, 70)
	return true
end

-- Stop the heart (administrators, tests, other addons). The neurological model itself never calls this.
function Cardio.TriggerArrest(who, cause)
	local org = Org(who)
	if not org or org.alive == false then return false end
	org.heartstop = true
	local st = NT.Brain.Ensure(org)
	st.arrestCause = cause or "triggered"
	st.quiet = false
	return true
end

-- Try to bring the circulation back (a treatment, a test). It succeeds only if the heart has
-- something to work with: blood, oxygen, a brain that still drives it, a muscle that is whole.
-- strength 0..1 scales the chance. Returns success and the chance that was drawn against.
function Cardio.AttemptROSC(who, strength)
	local org = Org(who)
	if not org or org.alive == false or org.heartstop ~= true then return false, 0 end
	local t = Cardio.Read(org)
	local p = (strength or 1) * t.circulatingVolume ^ 2 * (0.3 + 0.7 * t.oxygenSaturation) * t.myocardium
	if (tonumber(org.brain) or 0) >= 0.6 then p = 0 end
	local temp = t.temperature
	if temp < 28 or temp > 42 then p = 0 end
	p = Clamp(p, 0, 0.95)
	if math.random() >= p then return false, p end
	org.heartstop = false
	org.pulse = max(tonumber(org.pulse) or 0, 20)
	return true, p
end

------------------------------------------------------------------------------------------
-- Couplings, once per step of a record (sv_cardioresp.lua calls this)
------------------------------------------------------------------------------------------
function Cardio.Couple(ply, org, st, now, dt)
	if org.heartstop ~= true then st.lastRate = tonumber(org.heartbeat) or 0 end
	-- a convulsion: the sympathetic system fires [P]
	local sz = st.sz
	-- (Z-City's adrenaline climbs for as long as its input is above zero: the input is held up
	-- only while the adrenaline is below what a convulsion is given, so the heart runs fast and not
	-- away)
	-- (not while the heart is stopped: Z-City restarts a stopped heart by chance whenever its
	-- adrenaline is above zero, its rule for an injection, and a convulsion does not restart a heart)
	if sz and (sz.phase == "tonic" or sz.phase == "clonic") and org.heartstop ~= true and isnumber(org.adrenalineAdd) and (tonumber(org.adrenaline) or 0) < CC.seizureAdrenaline then
		org.adrenalineAdd = max(org.adrenalineAdd, 0.25)
	end
	-- rising pressure in the skull slows the heart [S: S7]: a ceiling on Z-City's rate, never a push
	if Z.Takeover() and st.pressure > CC.cushingFrom and org.heartstop ~= true then
		local cap = 70 - CC.cushingDrop * Clamp((st.pressure - CC.cushingFrom) / (1 - CC.cushingFrom), 0, 1)
		local hb = tonumber(org.heartbeat)
		if hb and hb > cap then org.heartbeat = cap st.cushing = true end
	elseif st.cushing then
		st.cushing = nil
	end
	-- compressions: Z-City's CPR lifts its pressure value in steps while the heart is stopped
	local pulse = tonumber(org.pulse) or 0
	if org.heartstop == true and st.lastPulse and pulse - st.lastPulse >= CC.cprStep then
		local c = st.cpr
		if not c or now - c.last > CC.cprGap then
			c = { first = now, n = 0 }
			st.cpr = c
			NT.States.Push(st, ply, "chest compressions begin")
		end
		c.last, c.n = now, c.n + 1
	elseif st.cpr and now - st.cpr.last > CC.cprGap and not st.cpr.stopped then
		st.cpr.stopped = true
		if org.heartstop == true then NT.States.Push(st, ply, string.format("chest compressions stop after %d", st.cpr.n)) end
	end
	st.lastPulse = pulse
end

-- The label, kept on the record and logged when it changes (for records only: nobody without a
-- neurological record is looked at).
function Cardio.Track(ply, org, st, now)
	if now < (st.nextCardio or 0) then return end
	st.nextCardio = now + 0.5
	local label = Cardio.GetState(org)
	-- (the arrest label follows the confirmed arrest, not a heart that flickers; any other label has
	-- to hold for a moment before it is taken: near its thresholds the reading goes back and forth)
	if st.arrestSince then label = "CARDIAC_ARREST" elseif label == "CARDIAC_ARREST" then label = st.cardio or "CRITICAL" end
	if label == st.cardio then
		st.cardioNext = nil
	elseif not st.cardio or label == "CARDIAC_ARREST" or st.cardio == "CARDIAC_ARREST" then
		if st.cardio then NT.States.Push(st, ply, string.format("circulation: %s -> %s (%s)", st.cardio, label, Cardio.GetHeartState(org))) end
		st.cardio, st.cardioNext = label, nil
	elseif st.cardioNext ~= label then
		st.cardioNext, st.cardioNextT = label, now
	elseif now - st.cardioNextT >= CC.labelHold then
		NT.States.Push(st, ply, string.format("circulation: %s -> %s (%s)", st.cardio, label, Cardio.GetHeartState(org)))
		st.cardio, st.cardioNext = label, nil
	end
end
