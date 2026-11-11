-- The brain of an injured character: what was done to it (injury variables), what it can still do
-- (function variables), and how both change with time.
--
-- A record exists only for a character that has been injured; it is created by the first injury
-- event that does anything and dropped when everything is back at baseline (or the organism is
-- cleared). Uninjured characters cost one table lookup per organism tick.
--
-- Records are kept beside Z-City's organism table, keyed by it, not inside it: nothing of Z-City
-- that walks, copies or sends an organism ever meets them.
--
-- Fast processes run in real time (knockout, daze, apnoea). Slow ones (a lesion that grows, swelling,
-- recovery of a mild diffuse injury, an infarct that matures) take minutes to hours in life and run
-- on a compressed clock, neuro_timescale [G].
--
-- Two layers describe the injury. The mechanical one keeps a few numbers for the whole brain
-- (diffuse injury, bruising of each half, the brainstem, a lesion that takes up room, swelling)
-- and decides what kills. The anatomical one (sv_anatomy.lua, sv_vascular.lua) says where the
-- damage sits and what blood reaches it, and from that what the brain can still do, function by
-- function and limb by limb. Function is always read from the anatomy; the lasting injury that is
-- written to Z-City is read from damage only, never from what is merely switched off.

local NT = NeuroTrauma
NT.Brain = NT.Brain or {}
local BR = NT.Brain
local C, Z, B, E, S = NT.Config, NT.ZC, NT.Biomech, NT.E, NT.States
local AN, VA, A = NT.Anatomy, NT.Vascular, NT.Atlas
local CB, CO, CL, CA, CV = C.Brain, C.Out, C.Load, C.Anatomy, C.Vascular
local max, min, exp, Clamp = math.max, math.min, math.exp, math.Clamp

local records = setmetatable({}, { __mode = "k" })    -- organism -> record
local tolerance = setmetatable({}, { __mode = "k" })  -- organism -> individual tolerance (one life)
local person = setmetatable({}, { __mode = "k" })     -- organism -> seed of what differs between people
BR.count = 0

function NT.Get(org) return records[org] end

local function Ramp(x, from, span)
	if x <= from then return 0 end
	return min((x - from) / span, 1)
end

-- Identical impacts injure people differently [S: B13 B14]: one draw per life.
local function Tolerance(org)
	local tol = tolerance[org]
	if not tol then
		tol = Clamp(1 + (math.random() + math.random() + math.random() - 1.5) * C.Biomech.tolSpread * 1.6, 0.6, 1.5)
		tolerance[org] = tol
	end
	return tol
end

local function NewRecord(org, now)
	local tol = Tolerance(org)
	local st = {
		born = now, lastT = now, tol = tol,
		-- what happened
		diffuse = 0, diffuseFloor = 0, focalL = 0, focalR = 0, stem = 0, fracture = 0,
		mass = 0, massRate = 0, massFinal = 0, massSide = 0, pupilSide = 0, weakSide = 0,
		swell = 0, hypoxic = 0, vulnExtra = 0,
		-- transient processes (times)
		locUntil = 0, confusedUntil = 0, stunUntil = 0, stunDur = 1, apnoeaUntil = 0,
		fencingUntil = 0, convulsionUntil = 0,
		-- what the brain can still do
		pressure = 0, stemStress = 0, structural = 0, injury = 0, globalInjury = 0, consciousness = 1, effective = 1, cognitive = 1,
		motorL = 1, motorR = 1, coordination = 1, balance = 1, seizureRisk = 0, autonomic = 0,
		armL = 1, armR = 1, handL = 1, handR = 1, legL = 1, legR = 1, faceL = 1, faceR = 1, trunk = 1,
		coordL = 1, coordR = 1, gaze = 0,
		reflexAbn = 0, pupilL = 0.5, pupilR = 0.5, resp = 1, posture = 0, postureKind = E.Posture.NONE,
		seizing = false, ictal = 0,
		state = E.State.NORMAL, stateSince = now, overlays = 0, log = {}, events = 0,
	}
	local seed = person[org]
	if not seed then
		seed = math.random(1, 2147483646)
		person[org] = seed
	end
	AN.New(st, seed)
	records[org] = st
	BR.count = BR.count + 1
	return st
end

local function Drop(org, ply, st, why)
	if records[org] then
		records[org] = nil
		BR.count = math.max(BR.count - 1, 0)
		if st then S.Push(st, ply, "record closed: " .. why) end
		hook.Run("NT_Closed", ply, org)
	end
end
BR.Drop = Drop

hook.Add("Org Clear", "NT_Brain", function(org)
	if not istable(org) then return end
	tolerance[org] = nil
	person[org] = nil
	local st = records[org]
	if st then Drop(org, org.owner, st, "organism cleared") end
end)

------------------------------------------------------------------------------------------
-- One step of the model
------------------------------------------------------------------------------------------
local function Derive(st, now)
	local an = st.an
	-- pressure inside the skull: the reserve takes up added volume, then pressure climbs steeply [S: S5]
	local vol = st.mass + st.swell + an.sah * CV.sahVolume + an.ivh * CV.ivhVolume
	local p = 0
	if vol > CB.reserve then p = ((vol - CB.reserve) / (1 - CB.reserve)) ^ CB.pressurePow end
	st.pressure = p
	local ch = AN.Channels(st)

	-- The brainstem's hold on arousal is loosened by a primary injury, by pressure from above, or
	-- by a lesion in its tegmentum [S: N14]. The first reading is of what does not work now, the
	-- second of what is destroyed.
	st.stemStress = Clamp(max(st.stem, p, an.stemArousal), 0, 1.5)
	local stemLasting = Clamp(max(st.stem, p, an.stemArousalD), 0, 1.5)
	st.stemLasting = stemLasting

	-- consciousness: what the largest cause takes from it
	local cd = Ramp(st.diffuse, CB.cDiffuseFrom, CB.cDiffuseSpan)
	local cs = Ramp(st.stemStress, CB.cStemFrom, CB.cStemSpan)
	-- (the paramedian thalamus of both sides [S: N20 N22]; nearly all the cortex of both hemispheres [P])
	local ct = min(Ramp(1 - ch.arousal_thalamus, CB.cThalFrom, CB.cThalSpan), CB.cThalMax)
	local cc = Ramp(1 - max(ch.cortexL, ch.cortexR), CB.cCortexFrom, CB.cCortexSpan)
	-- what of this is lasting: the same causes read from damage alone
	st.structural = max(cd, Ramp(stemLasting, CB.cStemFrom, CB.cStemSpan), Ramp(an.thalD, CB.cThalFrom + 0.3, CB.cThalSpan),
		Ramp(min(an.lesionL, an.lesionR), CB.cCortexFrom, CB.cCortexSpan))
	-- how badly the brain is injured as a whole, whether or not it costs consciousness; and how
	-- badly at all, counting an injury of one place (which Z-City's single number must not carry)
	st.globalInjury = max(st.structural, min(p, 1), Ramp(st.zbrain or 0, 0.1, 0.4))
	local focal = max(st.focalL, st.focalR, an.lesionL * 3, an.lesionR * 3)
	st.injury = max(st.globalInjury, min(focal, 1.5) * 0.8, st.fracture * 0.3)
	local lost, why = 0, "none"
	if cd > lost then lost, why = cd, "diffuse" end
	if cs > lost then lost, why = cs, "stem" end
	if ct > lost then lost, why = ct, "thalamus" end
	if cc > lost then lost, why = cc, "cortex" end
	if now < st.locUntil then
		lost, why = 1, "knockout"
	elseif now < st.confusedUntil then
		-- coming round: from just able to stand back to clear
		local f = (now - st.locUntil) / max(st.confusedUntil - st.locUntil, 0.1)
		local k = (1 - f) * (1 - CO.confused[1])
		if k > lost then lost, why = k, "confusion" end
	end
	if now < st.stunUntil then
		local k = (st.stunUntil - now) / st.stunDur * (1 - CO.stunned[1])
		if k > lost then lost, why = k, "daze" end
	end
	if st.ictal > lost then lost, why = st.ictal, "seizure" end
	-- sedation by a drug (sv_treatment.lua)
	if (st.sedation or 0) > lost then lost, why = st.sedation, "sedation" end
	-- no circulation: consciousness goes within seconds [S: R5; R: R6]
	if st.arrestSince then
		local k = Ramp(now - st.arrestSince, C.Arrest.locFrom, C.Arrest.locSpan)
		if k > lost then lost, why = k, "arrest" end
	end
	st.consciousness = Clamp(1 - lost, 0, 1)
	st.lossWhy = why
	st.cognitive = Clamp(1 - max(lost, st.diffuse * 0.8), 0, 1)

	-- Strength, limb by limb: the pathway from the motor cortex of the opposite side down to the
	-- pyramid (sh_atlas.lua), times how readily a movement starts. A lesion that presses on the
	-- motor pathway weakens one whole side, usually the opposite one [S: S6]; so does the time
	-- after a seizure that began on one side [S: Z7].
	local pl, pr = 0, 0
	if st.massSide ~= 0 and p > 0.15 then
		local weak = st.weakSide          -- +1: the left side of the body is the weak one
		if weak > 0 then pl = min(p, 1) * 0.8 else pr = min(p, 1) * 0.8 end
	end
	-- (the weakness after a seizure is in the anatomy: the tired hemisphere is switched off there,
	-- sv_seizure.lua)
	local il, ir = 0.6 + 0.4 * ch.initiationL, 0.6 + 0.4 * ch.initiationR
	st.armL, st.armR = Clamp(ch.armL * il - pl, 0, 1), Clamp(ch.armR * ir - pr, 0, 1)
	st.handL, st.handR = Clamp(ch.handL * il - pl, 0, 1), Clamp(ch.handR * ir - pr, 0, 1)
	st.legL, st.legR = Clamp(ch.legL * il - pl, 0, 1), Clamp(ch.legR * ir - pr, 0, 1)
	st.faceL, st.faceR = Clamp(ch.faceL - pl * 0.7, 0, 1), Clamp(ch.faceR - pr * 0.7, 0, 1)
	st.trunk = ch.trunk
	st.motorL = min(st.armL, st.handL, st.legL)
	st.motorR = min(st.armR, st.handR, st.legR)
	-- balance: wakefulness, the diffuse injury, the brainstem, and the cerebellar midline with the
	-- vestibular nuclei and the feeling of the legs [S: N73 N41]
	local feel = 0.6 + 0.4 * min(ch.sensationL, ch.sensationR)
	st.balance = Clamp(min(1 - max(lost * 0.9, st.diffuse * 0.9, st.stem * 0.8), ch.balance * feel), 0, 1)
	-- coordination of each side: the cerebellar hemisphere of that side [S: N43 N73]
	local cg = 1 - max(lost * 0.8, st.diffuse * 0.7, st.stem)
	st.coordL, st.coordR = Clamp(min(cg, ch.coordinationL), 0, 1), Clamp(min(cg, ch.coordinationR), 0, 1)
	st.coordination = min(st.coordL, st.coordR)

	-- brainstem signs. Breathing is driven from the medulla and the pons (the channel): it fails
	-- with a lesion there, with a primary injury of the whole brainstem, or with pressure from above;
	-- a lesion confined to the midbrain costs wakefulness, not breathing [S: N67].
	-- (and the diaphragm is driven through the cervical cord: sv_spine.lua)
	st.resp = Clamp(min(1 - Ramp(max(st.stem, p), 0.5, 0.4), ch.respiration, NT.Spine and NT.Spine.Breath(st) or 1) - (st.respDrug or 0), 0, 1)
	st.autonomic = Clamp(max(Ramp(p, 0.4, 0.5), now < st.apnoeaUntil and 0.6 or 0, 1 - ch.autonomic), 0, 1)
	st.reflexAbn = Clamp(Ramp(st.stemStress, 0.3, 0.6), 0, 1)
	-- posturing belongs to deep unresponsiveness with brainstem stress; flexor first, extensor as
	-- the stress grows [S: S8 S14 S17]
	-- A posture is made by the brainstem below what has let go: it needs a medulla that works, and
	-- blood. A body without circulation is limp [P].
	local post = 0
	if st.consciousness < 0.1 and not st.arrestSince then
		post = Ramp(st.stemStress, CB.postureFrom, CB.postureSpan) * Clamp((an.medulla or 1) * 2, 0, 1)
	end
	st.posture = post
	st.postureKind = post <= 0 and E.Posture.NONE or (st.stemStress >= CB.postureExtensor and E.Posture.EXTENSOR or E.Posture.FLEXOR)
	-- (a posture asked for from outside, NeuroTrauma.SetPosturing: shown while the character is
	-- unresponsive, for as long as it was asked for)
	local force = st.postureForce
	if force then
		if now >= force.untilT then st.postureForce = nil
		elseif st.consciousness < 0.1 then st.posture, st.postureKind = force.level, force.kind end
	end
	-- muscle tone, for the readout: limp when unresponsive, raised in a posture, rigid in the tonic
	-- phase of a seizure
	local sz = st.sz
	st.tone = (sz and sz.phase == "tonic") and 2 or (st.posture > 0.05 and 1 + st.posture * 0.8 or (st.consciousness < 0.1 and 0.3 or 1))
	-- what a seizure leaves behind, as tiredness of the whole brain
	st.fatigue = Clamp(max(st.postictal or 0, (sz and sz.phase == "postictal") and st.ictal or 0), 0, 1)
	-- pupils: the one on the side drawn at the lesion's start widens with pressure; both at the end.
	-- A lesion of the midbrain on one side widens the pupil of that side [S: N55].
	local wide = Ramp(p, CB.pupilFrom, CB.pupilSpan) * 0.5
	local both = Ramp(st.stemStress, 0.85, 0.15) * 0.5
	local d = an.d
	local ml, mr = (d[A.regionOf.L_midbrain_teg] or 0) * 0.5, (d[A.regionOf.R_midbrain_teg] or 0) * 0.5
	st.pupilL = 0.5 + max(st.pupilSide > 0 and wide or 0, both, ml)
	st.pupilR = 0.5 + max(st.pupilSide < 0 and wide or 0, both, mr)
	-- the eyes rest toward the side of a destroyed frontal eye field [P]; a seizure sets its own
	local fl, fr = d[A.regionOf.L_caudalmiddlefrontal] or 0, d[A.regionOf.R_caudalmiddlefrontal] or 0
	st.gaze = (fl - fr > 0.4) and 1 or ((fr - fl > 0.4) and -1 or 0)
	-- seizures: more likely with bruising, bleeding and fracture [S: Z1 Z3]
	st.seizureRisk = Clamp(min(focal, 1.5) * 0.5 + st.mass * 0.4 + st.fracture * 0.2 + st.diffuse * 0.2 + an.sah * 0.2, 0, 1)
end
BR.Derive = Derive

local function Output(org, st)
	-- consciousness: a ceiling. Unconscious is written well under Z-City's threshold of 0.1
	local cap = st.consciousness
	if cap < 0.1 then cap = min(cap, CO.unconscious) end
	if cap < 0.999 then Z.CapConsciousness(org, cap) end
	-- brain damage: a floor that follows the lasting injury of the brain as a whole. An injury of
	-- one place does not raise it: Z-City hangs slurred chat, a muted voice, reversed walking and a
	-- blurred view on this one number, and a character with a paralysed hand has none of those.
	local floor = 0
	if st.stemLasting >= CB.stemFailure then
		floor = CO.brainFailure
	elseif st.structural >= 0.9 then
		-- (kept under 0.5 for as long as the brainstem has not failed: from 0.5 Z-City stops the
		-- heart by a throw of dice at every tick, about six seconds on average, and a comatose
		-- character that postures would be in arrest before the posture had been seen. The heart
		-- stops when the model says the brainstem has failed, not before.)
		floor = CO.brainComa[1] + (CO.brainComa[2] - CO.brainComa[1]) * Ramp(st.stemLasting, 0.3, 0.6)
	elseif st.globalInjury > 0.15 then
		floor = CO.brainImpaired[1] + (CO.brainImpaired[2] - CO.brainImpaired[1]) * Ramp(st.globalInjury, 0.15, 0.75)
	end
	-- (the course of a rifle round, sv_trauma.lua: its seconds are counted by the rule. Neither
	-- Z-City's dice for the heart, from 0.5, nor its death, at 0.7, are to come before their end.)
	local tc = st.terminal
	if tc and not tc.done then floor = min(floor, CO.brainComa[2]) end
	st.brainFloor = floor
	if floor > 0 then Z.FloorBrain(org, floor) end
end

-- A lesion that takes up room switches off what lies beside it and, past the point of herniation,
-- pinches the posterior cerebral artery of its side against the tentorium [P].
local function MassEffects(st)
	local an = st.an
	local m = st.mass
	if math.abs(m - (an.massAt or 0)) > 0.03 or (m == 0 and an.massAt and an.massAt > 0) then
		an.massAt = m
		if m > 0.05 and st.massSide ~= 0 then
			local site = st.massSite
			local sx = st.massSide > 0 and 1 or -1
			local x, y, z = 0.75 * sx, 0.0, 0.55
			if site then x, y, z = site[1], site[2], site[3] end
			local sup = {}
			local reach = CA.massReach * CA.massReach
			for id, r in ipairs(A.regions) do
				if r.kind ~= "B" and r.kind ~= "X" then
					local dx, dy, dz = r.x - x, r.y - y, r.z - z
					local s = m * CA.massSuppress * exp(-(dx * dx + dy * dy + dz * dz) / reach)
					if s > 0.05 then sup[id] = min(s, 0.95) end
				end
			end
			AN.Suppress(st, "mass", sup, nil)
		elseif an.src.mass then
			AN.Suppress(st, "mass", nil, nil)
		end
	end
	local pinch = (st.pressure >= CB.herniation and st.massSide ~= 0) and (st.massSide > 0 and "L" or "R") or nil
	if pinch ~= an.pinched and (pinch or st.pressure < CB.herniation - 0.1) then
		if an.pinched then VA.SetPatency(st, an.pinched .. "_pca_p2", 1) end
		if pinch then VA.SetPatency(st, pinch .. "_pca_p2", CV.herniationPCA) end
		an.pinched = pinch
	end
end

local function Step(ply, org, st, now)
	local dt = now - st.lastT
	if dt <= 0 then return end
	st.lastT = now
	local sdt = dt * C.sv.timescale:GetFloat()
	local an = st.an

	-- a lesion that grows until it has reached its final size
	if st.massRate > 0 and st.mass < st.massFinal then
		st.mass = min(st.mass + st.massRate * sdt, st.massFinal)
	end
	-- Low oxygen and low blood pressure make every brain injury worse [S: S10 S14]. Z-City keeps
	-- both; here they add to the swelling.
	local o2 = istable(org.o2) and tonumber(org.o2[1]) or 30
	if o2 >= CB.hypoxiaFrom and st.hypoxic > 0 and st.hypoxic < 0.15 then
		-- (a brief shortage leaves nothing behind)
		st.hypoxic = st.hypoxic * 0.5 ^ (sdt / 600)
		if st.hypoxic < 0.01 then st.hypoxic = 0 end
	elseif o2 < CB.hypoxiaFrom then
		st.hypoxic = min(st.hypoxic + (CB.hypoxiaFrom - o2) / CB.hypoxiaFrom * dt / CB.hypoxiaSeconds, 1)
	end
	local lowPressure = Clamp((CB.bloodFrom - (tonumber(org.blood) or 5000)) / CB.bloodSpan, 0, 1)
	-- what Z-City itself has booked as brain damage beyond what this model put there
	st.zbrain = max(Z.Brain(org) - (st.brainFloor or 0), 0)
	-- swelling follows the injury, slowly, and does not go down within a round, unless it is treated:
	-- Z-City's mannitol draws it down for as long as it lasts, and does nothing to a lesion that
	-- keeps growing [P]. A large infarct swells too [S: N21].
	local focal = max(st.focalL, st.focalR, an.lesionL * 3, an.lesionR * 3)
	local target = min(CB.swellDiffuse * st.diffuse + CB.swellFocal * min(focal, 1.5) + CB.swellHypoxic * st.hypoxic + CB.swellMass * st.mass
		+ CB.swellShock * lowPressure * min(st.injury, 1) + CV.swellInfarct * an.infarct, 1.2)
	st.swellTarget = target
	if (tonumber(org.mannitol) or 0) > 0 then
		st.swell = max(st.swell - CB.mannitolRate * dt, 0)
	elseif target < st.swell and st.swell < 0.1 then
		st.swell = max(st.swell - sdt / 3000, target)
	elseif target > st.swell then
		st.swell = st.swell + (target - st.swell) * (1 - exp(-sdt / (CB.swellMinutes * 60)))
	end
	-- the mild part of a diffuse injury recovers
	if st.diffuse > st.diffuseFloor then
		st.diffuse = st.diffuseFloor + (st.diffuse - st.diffuseFloor) * 0.5 ^ (sdt / (CB.diffuseMinutes * 60))
		if st.diffuse - st.diffuseFloor < 0.003 then st.diffuse = st.diffuseFloor end
	end
	if st.vulnExtra > 0 then
		st.vulnExtra = st.vulnExtra * 0.5 ^ (sdt / (CL.vulnMinutes * 60))
		if st.vulnExtra < 0.01 then st.vulnExtra = 0 end
	end

	MassEffects(st)
	-- Z-City's spine as what the cord still conducts (sv_spine.lua)
	if NT.Spine then NT.Spine.Refresh(st, org) end
	VA.Step(ply, org, st, now, dt, sdt)
	if NT.Treatment then NT.Treatment.Update(ply, org, st, now, dt) end
	if NT.CardioResp then NT.CardioResp.Update(ply, org, st, now, dt) end
	if NT.Seizure then NT.Seizure.Update(ply, org, st, now, sdt) end
	Derive(st, now)
	S.Classify(ply, org, st, now)
	Output(org, st)
	if NT.Cardio then NT.Cardio.Track(ply, org, st, now) end
	if NT.Face then NT.Face.Update(ply, org, st, now) end
	-- what the owner sees, how the body moves, what the others are told
	Z.Disorient(org, (1 - st.cognitive) * 6)
	-- the animation state, then what moves the body by it
	if NT.Anim and NT.Anim.Resolve then NT.Anim.Resolve(ply, org, st, now) end
	if NT.Motor then NT.Motor.Update(ply, org, st, now) end
	if NT.Net then NT.Net.Update(ply, org, st, now) end

	-- back at baseline: nothing structural, nothing running
	if st.state == E.State.NORMAL and st.overlays == 0 and st.consciousness > 0.99 and st.diffuse < 0.02 and st.diffuseFloor < 0.02
		and max(st.focalL, st.focalR) < 0.02 and st.stem < 0.02 and st.fracture <= 0 and st.massRate <= 0 and st.swell < 0.02
		and st.vulnExtra <= 0 and st.hypoxic < 0.02 and (st.zbrain or 0) < 0.1 and not st.sz and not st.postictalUntil and not st.arrestSince and not st.heartStill and not st.stagger and not st.cordHurt
		and next(an.d) == nil and next(an.td) == nil and not an.vascActive and not st.med
		and now > max(st.locUntil, st.confusedUntil, st.stunUntil, st.apnoeaUntil, st.fencingUntil, st.convulsionUntil) then
		Drop(org, ply, st, "back at baseline")
	end
end
BR.Step = Step

hook.Add("Org Think", "NT_Brain", function(owner, org)
	local st = records[org]
	if not st then return end
	if not NT.Enabled() then return end
	if org.alive == false or (IsValid(owner) and owner:IsPlayer() and not owner:Alive()) then
		Drop(org, owner, st, "dead")
		return
	end
	local now = CurTime()
	-- (a record in which nothing is running, kept only for what the injury left behind, is looked
	-- at once a second; an injury event steps it at once)
	if st.quiet and now - st.lastT < 1 then return end
	Step(owner, org, st, now)
	-- (overlays that only describe what an old injury left behind do not keep a record awake)
	local still = bit.band(st.overlays, bit.bnot(E.Overlay.MOTOR_DEFICIT)) == 0
	st.quiet = (st.state == E.State.NORMAL or st.state == E.State.IMPAIRED) and still and st.consciousness > 0.99 and (st.massRate <= 0 or st.mass >= st.massFinal)
		and st.balance >= C.Motor.stumbleFrom and not st.an.vascActive
		and not st.sz and not st.arrestSince and not st.postictalUntil and not st.convulsionFrom and not st.jerksFrom and not st.med
		and now > max(st.locUntil, st.confusedUntil, st.stunUntil, st.apnoeaUntil, st.fencingUntil)
end)

------------------------------------------------------------------------------------------
-- An injury event arrives
------------------------------------------------------------------------------------------
-- Is this injury unsurvivable in the instant it happens? Asked inside Z-City's damage call, before
-- its organism think (sv_injury.lua): the answer decides whether Z-City's own lethal brain value
-- stands. Two cases, and no others:
--   the "explosive" kind of gunshot wound: at high energy the temporary cavity inside the closed
--   skull lacerates the whole brain [S: G5; the energy from which it is taken to happen is G]
--   the lower brainstem is destroyed: nothing is left that breathes or holds a circulation [P]
-- Everything else runs its course. It may well kill (most tracks through the middle of the brain
-- do [S: G1 G2 G3]), but not in this instant.
function BR.Triage(org, ev)
	if ev.mech ~= E.Mech.PROJECTILE then return nil end
	local sv = AN.SurveyEvent(ev)
	if not sv then return nil end
	if sv.e >= CL.shotExplosive then return string.format("the brain is destroyed (a wound of the explosive kind, %.0f J)", ev.energy or 0) end
	if sv.medulla >= CL.shotMedulla then return "the lower brainstem is destroyed" end
	return nil
end

function BR.Apply(ply, org, ev)
	local st = records[org]
	local L = B.Loads(ev, ev.tol or Tolerance(org), 1 + (st and st.vulnExtra or 0))
	-- (somebody else decides what the blow does to the player at once: sv_injury.lua, "A blow of
	-- the free-hand module")
	if ev.owned then L.loc, L.stun, L.apnoea, L.fencing, L.convulsion = nil, nil, nil, nil, nil end
	ev.loads = L
	local any = L.diffuse > 0.03 or L.focalL > 0.03 or L.focalR > 0.03 or L.stem > 0.03 or L.fracture > 0
		or L.loc or L.stun or L.apnoea or L.mass
	if not any then return end
	local now = CurTime()
	if not st then st = NewRecord(org, now) end
	st.events = st.events + 1
	-- (the chain an event belongs to: a second event soon after the first is a consequence of it,
	-- a later one a repeated injury)
	if st.lastEventT then
		local gap = now - st.lastEventT
		ev.secondary = gap < 3
		ev.repeated = not ev.secondary
		ev.chain = ev.secondary and st.lastEventId or nil
	end
	st.lastEventT, st.lastEventId = now, ev.id

	-- (a trace of injury that does nothing is not kept)
	if L.diffuse > 0.03 then st.diffuse = min(st.diffuse + L.diffuse, 1.5) end
	st.diffuseFloor = max(st.diffuseFloor, st.diffuse * CB.diffuseKeep)
	if L.focalL > 0.03 then st.focalL = min(st.focalL + L.focalL, 1.5) end
	if L.focalR > 0.03 then st.focalR = min(st.focalR + L.focalR, 1.5) end
	st.stem = min(st.stem + L.stem, 1.5)
	st.fracture = max(st.fracture, L.fracture)
	-- where it sits: the bruises under and opposite a blow, the track of a bullet, the vessels it cut
	local notes = AN.ApplyEvent(st, ev, L)
	if ev.trackA then
		local n = VA.TrackSpaces(st, ev.trackA[1], ev.trackA[2], ev.trackA[3], ev.trackB[1], ev.trackB[2], ev.trackB[3])
		if n then notes[#notes + 1] = n end
	end
	if L.loc then
		st.locUntil = max(st.locUntil, now + L.loc)
		st.confusedUntil = max(st.confusedUntil, st.locUntil + Clamp(L.loc * CB.confusionPerLoc, CB.confusionMin, CB.confusionMax))
	end
	if L.stun then
		st.stunUntil = max(st.stunUntil, now + L.stun)
		st.stunDur = max(st.stunUntil - now, 0.5)
	end
	if L.apnoea then st.apnoeaUntil = max(st.apnoeaUntil, now + L.apnoea) end
	-- (a body without circulation does not answer a blow: its head strikes the ground when it is
	-- dropped or moved, and neither a posture nor a convulsion follows)
	local still = st.arrestSince ~= nil or st.terminal ~= nil
	if L.fencing and not still then st.fencingUntil = now + 0.4 + L.fencing st.fencingSeed = ev.seed end
	if L.convulsion and not still then st.convulsionFrom, st.convulsionUntil = now + 0.8, now + 0.8 + L.convulsion end
	-- (a stem artery cut by the track bleeds for certain, and fast [P])
	if st.an.cutLarge and not L.mass and not st.an.cutBooked then
		local side = (ev.lat or 0) >= 0 and 1 or -1
		L.mass = { rate = 1 / (CL.epiMinutes[1] * 60), final = CL.massFinal[2] + CL.massFinalSevere, side = side, kind = "bleeding from a cut artery" }
		st.an.cutBooked = true
	end
	if L.mass and (st.massRate <= 0 or L.mass.rate > st.massRate) then
		local rng = NT.RNG(ev.seed + 7)
		st.massRate = L.mass.rate
		st.massFinal = max(st.massFinal, L.mass.final)
		st.massSide = L.mass.side
		st.massKind = L.mass.kind
		-- where it lies: an epidural one under the blow, low at the temple where the meningeal
		-- artery crosses the fracture [S: N85 S3]; a subdural one over the convexity [S: S4]; a
		-- bleed along a track in the middle of the track
		local sx = L.mass.side > 0 and 1 or -1
		if ev.trackA then
			st.massSite = { (ev.trackA[1] + ev.trackB[1]) * 0.5, (ev.trackA[2] + ev.trackB[2]) * 0.5, (ev.trackA[3] + ev.trackB[3]) * 0.5 }
		elseif L.mass.kind == "epidural-like" then
			local x, y, z = AN.Site(ev)
			st.massSite = { sx * max(math.abs(x or 0.9), 0.7), (y or 0.2) * 0.6, min(z or 0, 0.4) }
		else
			st.massSite = { sx * 0.75, 0.0, 0.55 }
		end
		-- which pupil widens and which side weakens are tendencies, drawn once [R: S11; S: S6]
		st.pupilSide = rng:Next() < CB.pupilSameSide and L.mass.side or -L.mass.side
		st.weakSide = rng:Next() < CB.weakOpposite and -L.mass.side or L.mass.side
	end
	if L.x > 5 or L.loc then st.vulnExtra = min(st.vulnExtra + CL.vulnAdd, 1.5) end

	if #notes > 0 then L.why = (L.why ~= "" and (L.why .. "; ") or "") .. table.concat(notes, "; ") end
	S.Push(st, ply, string.format("event #%d %s (%s%s): rotation %.1f contact %.1f tolerance %.2f -> diffuse +%.2f focal L +%.2f R +%.2f stem +%.2f%s",
		ev.id, E.Mech.names[ev.mech], ev.measured and "measured" or "estimated", ev.secondary and ", follows the last" or (ev.repeated and ", repeated" or ""),
		L.x, L.k, st.tol, L.diffuse, L.focalL, L.focalR, L.stem,
		L.why ~= "" and ("; " .. L.why) or ""))
	hook.Run("NT_Injured", ply, org, st, ev, L)
	return st, L
end

-- The record of a character, made if there is none (developer commands and tests).
function BR.Ensure(org)
	return records[org] or NewRecord(org, CurTime())
end

-- (An event reaches BR.Apply from the trauma pipeline, sv_trauma.lua, which then runs a step of
-- the model at once. BR.paused: events are recorded and nothing is applied; the calibration scene
-- of the tests.)
