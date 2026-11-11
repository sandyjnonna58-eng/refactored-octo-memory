-- The calls other code may use (server). Everything goes through the same paths as the game's own
-- injuries: an impact becomes an injury event, a seizure is planned like any other, a drug is
-- validated like one given by a player. Nothing here reaches around the model.
--
--   NeuroTrauma.ApplyImpact(ply, info)             a head impact that the engine did not produce
--   NeuroTrauma.AddNeurologicalStress(ply, n, kind) add to one injury variable
--   NeuroTrauma.TriggerSeizure(ply, opts)           start a seizure
--   NeuroTrauma.SetUnconscious(ply, seconds)        a knockout of that length
--   NeuroTrauma.SetPosturing(ply, kind, severity, seconds)
--   NeuroTrauma.AttemptRecovery(ply, amount)        let the recoverable part of the injury recover
--   NeuroTrauma.AdministerMedication(ply, drug, giver)
--   NeuroTrauma.GetState(ply)                       label, snapshot
--   NeuroTrauma.GetSeverity(ply)                    0..1, parts
--   NeuroTrauma.DamageRegion / DamageVessel / Reset the anatomical layer directly
-- Cardio.* is in sv_cardio.lua, MedicalTreatment.Administer in sv_treatment.lua.
-- `ply` may be a player or the ragdoll of a living player.

local NT = NeuroTrauma
local C, Z, E, A = NT.Config, NT.ZC, NT.E, NT.Atlas
local BR, AN, VA = NT.Brain, NT.Anatomy, NT.Vascular
local Clamp, max, min = math.Clamp, math.max, math.min

local function Target(who)
	if not NT.Enabled() or not IsValid(who) then return nil end
	local owner = who:IsPlayer() and who or Z.Owner(who)
	local org = Z.Org(who)
	if not IsValid(owner) or not org or not owner:Alive() then return nil end
	return owner, org
end

-- info: rotation (rad/s on the game's scale: a limp collapse onto concrete is 4..12), contact
-- (m/s), dir (unit vector from the centre of the head to the point of impact, in the head's frame:
-- left, front, up) or region ("front", "back", "left", "right", "top", "base", "face") and side
-- (-1 right .. 1 left), mechanism (name of E.Mech, default blunt), seed, attacker.
function NT.ApplyImpact(who, info)
	local owner, org = Target(who)
	if not owner or not istable(info) then return false end
	local mech = E.Mech[string.upper(tostring(info.mechanism or "BLUNT"))] or E.Mech.BLUNT
	local region = E.Region[string.upper(tostring(info.region or "NONE"))] or E.Region.NONE
	local rot, contact = tonumber(info.rotation) or 0, tonumber(info.contact) or 0
	local ev = {
		id = 0, t = CurTime(), seed = info.seed or math.random(1, 2147483646), ply = owner, org = org, body = Z.Body(owner),
		mech = mech, measured = false, region = region, lat = tonumber(info.side) or 0,
		rot = rot, contact = contact, rotEff = rot, contactEff = contact, landing = tonumber(info.landing) or 0,
		awake = 1, shield = 0, attacker = info.attacker,
	}
	if istable(info.dir) then
		ev.hit = { info.dir[1], info.dir[2], info.dir[3] }
		ev.lat = info.dir[1]
	end
	ev.synthetic = true
	NT.ProcessTraumaEvent(owner, ev)
	return true
end

-- kind: "diffuse" (default), "stem", "hypoxic", "swelling", "left", "right" (bruising of that half)
function NT.AddNeurologicalStress(who, amount, kind)
	local owner, org = Target(who)
	if not owner then return false end
	local st = BR.Ensure(org)
	amount = tonumber(amount) or 0
	kind = kind or "diffuse"
	if kind == "diffuse" then
		st.diffuse = Clamp(st.diffuse + amount, 0, 1.5)
		st.diffuseFloor = max(st.diffuseFloor, st.diffuse * C.Brain.diffuseKeep)
	elseif kind == "stem" then st.stem = Clamp(st.stem + amount, 0, 1.5)
	elseif kind == "hypoxic" then st.hypoxic = Clamp(st.hypoxic + amount, 0, 1)
	elseif kind == "swelling" then st.swell = Clamp(st.swell + amount, 0, 1.2)
	elseif kind == "left" or kind == "right" then
		local key = kind == "left" and "focalL" or "focalR"
		st[key] = Clamp(st[key] + amount, 0, 1.5)
		AN.Convexity(st, kind == "left" and "L" or "R", amount)
	else return false end
	st.quiet = false
	NT.States.Push(st, owner, string.format("stress added from outside: %s +%.2f", kind, amount))
	return true
end

-- opts: kind ("early", "convulsion"), focal, aware, spread, tonic, clonic, status, todd (booleans:
-- nil leaves it to chance), side (1 left, -1 right), seed, duration
function NT.TriggerSeizure(who, opts)
	local owner, org = Target(who)
	if not owner then return false end
	opts = opts or {}
	local st = BR.Ensure(org)
	st.quiet = false
	return NT.Seizure.Start(owner, st, CurTime(), opts.kind or "early", opts.seed, opts.duration, opts)
end

function NT.SetUnconscious(who, seconds)
	local owner, org = Target(who)
	if not owner then return false end
	return NT.Debug.Set(owner, "knockout", tonumber(seconds) or 10)
end

-- kind: "flexor", "extensor", "none". Shows on a character that is unresponsive (a posture needs
-- a body that lies); severity 0..1; seconds: how long it is held against what the model would do.
function NT.SetPosturing(who, kind, severity, seconds)
	local owner, org = Target(who)
	if not owner then return false end
	local st = BR.Ensure(org)
	local k = E.Posture[string.upper(tostring(kind or "NONE"))]
	if not k then return false end
	st.postureForce = k ~= E.Posture.NONE and { kind = k, level = Clamp(tonumber(severity) or 1, 0, 1), untilT = CurTime() + (tonumber(seconds) or 30) } or nil
	st.quiet = false
	return true
end

-- Lets what can recover do so at once: amount 0..1 of the recoverable part of the diffuse injury,
-- of the swelling, of the running knockout / daze / confusion. What is destroyed stays destroyed.
-- Returns what is left as severity.
function NT.AttemptRecovery(who, amount)
	local owner, org = Target(who)
	if not owner then return false end
	local st = NT.Get(org)
	if not st then return 0 end
	amount = Clamp(tonumber(amount) or 1, 0, 1)
	local now = CurTime()
	st.diffuse = st.diffuseFloor + (st.diffuse - st.diffuseFloor) * (1 - amount)
	st.swell = st.swell * (1 - amount)
	st.vulnExtra = st.vulnExtra * (1 - amount)
	for _, key in ipairs({ "locUntil", "confusedUntil", "stunUntil", "apnoeaUntil" }) do
		if st[key] > now then st[key] = now + (st[key] - now) * (1 - amount) end
	end
	st.quiet = false
	NT.States.Push(st, owner, string.format("recovery from outside: %.0f%% of what can recover", amount * 100))
	return NT.GetSeverity(owner)
end

function NT.AdministerMedication(who, drug, giver)
	return NT.Treatment.Administer(who, drug, giver)
end

-- The finer label (sv_states.lua) and a snapshot of the numbers. nil for a character with no record.
function NT.GetState(who)
	local owner, org = Target(who)
	if not owner then return nil end
	local st = NT.Get(org)
	if not st then return "NORMAL", nil end
	local ch = AN.Channels(st)
	local snap = {
		state = E.State.names[st.state], label = st.label, overlays = st.overlays,
		consciousness = st.effective, responsiveness = { eyes = st.respEyes, verbal = st.respVerbal, motor = st.respMotor },
		cognition = st.cognitive, voluntaryMotorControl = min(st.motorL, st.motorR), leftMotorControl = st.motorL, rightMotorControl = st.motorR,
		limbs = { leftArm = st.armL, rightArm = st.armR, leftHand = st.handL, rightHand = st.handR, leftLeg = st.legL, rightLeg = st.legR,
			headNeck = min(st.faceL, st.faceR), trunk = st.trunk },
		coordination = st.coordination, balance = st.balance, muscleTone = st.tone, rigidity = st.posture,
		seizureRisk = st.seizureRisk, seizureActivity = st.seizing and 1 or 0, seizureCategory = st.category,
		posturingSeverity = st.posture, posturingKind = E.Posture.names[st.postureKind],
		brainstemStress = st.stemStress, autonomicInstability = st.autonomic, respiratoryControl = st.resp,
		neurologicalFatigue = st.fatigue or 0, deteriorationRate = st.trend and -min(st.trend, 0) or 0, recoveryRate = st.trend and max(st.trend, 0) or 0,
		language = { production = ch.language_production, comprehension = ch.language_comprehension, repetition = ch.language_repetition,
			reading = ch.reading, writing = ch.writing, articulation = ch.articulation },
		senses = { visionLeftUpper = ch.vision_upperL, visionLeftLower = ch.vision_lowerL, visionRightUpper = ch.vision_upperR, visionRightLower = ch.vision_lowerR,
			hearing = ch.hearing, sensationLeft = ch.sensationL, sensationRight = ch.sensationR, neglectLeft = ch.neglectL, neglectRight = ch.neglectR },
		memory = ch.memory, attention = ch.attention, executive = ch.executive,
		pressure = st.pressure, dominantHemisphere = st.an.dom,
	}
	return st.label or string.upper(E.State.names[st.state]), snap
end

-- One number for how badly off the character is neurologically, and what it is made of.
function NT.GetSeverity(who)
	local owner, org = Target(who)
	if not owner then return nil end
	local st = NT.Get(org)
	if not st then return 0, {} end
	local parts = {
		consciousness = 1 - (st.effective or st.consciousness),
		injury = min(st.injury, 1),
		motor = 1 - min(st.motorL, st.motorR),
		brainstem = min(st.stemStress, 1),
		breathing = 1 - st.resp,
		seizure = st.seizing and 0.8 or 0,
	}
	local sev = 0
	for _, v in pairs(parts) do if v > sev then sev = v end end
	return sev, parts
end

-- The anatomical layer, directly. key: a region or tract key of the atlas ("L_precentral_hand",
-- "R_ic_post"); amount 0..1 is added. Vessel: patency 0 (shut) .. 1 (open).
function NT.DamageRegion(who, key, amount)
	local owner, org = Target(who)
	if not owner then return false end
	local st = BR.Ensure(org)
	local id = A.regionOf[key]
	if id then AN.DamageRegion(st, id, amount or 1)
	else
		id = A.tractOf[key]
		if not id then return false end
		AN.DamageTract(st, id, amount or 1)
	end
	st.quiet = false
	NT.States.Push(st, owner, string.format("damage from outside: %s +%.2f", key, amount or 1))
	return true
end

function NT.DamageVessel(who, key, patency)
	local owner, org = Target(who)
	if not owner then return false end
	local st = BR.Ensure(org)
	if not VA.SetPatency(st, key, patency or 0) then return false end
	st.quiet = false
	NT.States.Push(st, owner, string.format("vessel set from outside: %s open %.0f%%", A.Vessel(key).name, (patency or 0) * 100))
	return true
end

function NT.Reset(who)
	local owner, org = Target(who)
	if not owner then return false end
	local st = NT.Get(org)
	if st then BR.Drop(org, owner, st, "reset") end
	return true
end
