-- The neurological state of a character: a label derived from the variables of the model
-- (sv_brain.lua), with a little hysteresis, and a log in which every change names its reason.
-- The label follows what Z-City actually does with the character: it is taken from the lower of
-- the model's consciousness and Z-City's own, so it can never say "standing" for someone Z-City
-- has knocked out for a reason of its own (pain, shock, blood loss).

local NT = NeuroTrauma
NT.States = NT.States or {}
local S = NT.States
local C, Z, E = NT.Config, NT.ZC, NT.E
local CB = C.Brain
local St, Ov = E.State, E.Overlay
local band, bor = bit.band, bit.bor

local HOLD = 0.3     -- s a milder state must last before the label follows (a worse one is immediate)
local KEPT = 10      -- transitions remembered per character

local function Push(st, ply, text)
	local log = st.log
	log[#log + 1] = { t = CurTime(), text = text }
	if #log > KEPT then table.remove(log, 1) end
	local line = string.format("%s %s", IsValid(ply) and ply:Nick() or "?", text)
	if C.sv.log:GetBool() then NT.Print("%.1f %s", CurTime(), line) end
	if NT.TestLog then NT.TestLog("  state %s", line) end
end
S.Push = Push

-- Why consciousness is what it is: the largest of the things that take from it.
local function Reason(st, zc)
	local why = st.lossWhy or "?"
	local s = string.format("consciousness %.2f", st.effective or 1)
	if zc and zc < st.consciousness - 0.02 then
		return s .. string.format(" (Z-City holds it at %.2f: pain, shock or blood loss; the model alone gives %.2f)", zc, st.consciousness)
	end
	if why == "stem" then
		s = s .. string.format(" (brainstem stress %.2f: primary %.2f, tegmentum of midbrain and pons out of work %.2f, pressure %.2f from lesion %.2f%s%s and swelling %.2f)",
			st.stemStress, st.stem, st.an.stemArousal or 0, st.pressure, st.mass, st.mass > 0 and (st.massSide > 0 and " left" or " right") or "",
			(st.massRate > 0 and st.mass < st.massFinal) and string.format(" growing %.4f/s", st.massRate * C.sv.timescale:GetFloat()) or "", st.swell)
	elseif why == "diffuse" then
		s = s .. string.format(" (diffuse injury %.2f)", st.diffuse)
	elseif why == "knockout" then
		s = s .. string.format(" (knocked out, %.0f s left)", math.max(st.locUntil - CurTime(), 0))
	elseif why == "confusion" then
		s = s .. string.format(" (coming round, %.0f s left)", math.max(st.confusedUntil - CurTime(), 0))
	elseif why == "daze" then
		s = s .. string.format(" (dazed, %.0f s left)", math.max(st.stunUntil - CurTime(), 0))
	elseif why == "seizure" then
		s = s .. " (seizure)"
	elseif why == "thalamus" then
		s = s .. string.format(" (the paramedian thalamus of both sides, or the fibres that rise to it, are not working: %s)", tostring(st.an.why.arousal_thalamus))
	elseif why == "cortex" then
		s = s .. string.format(" (the cortex of both hemispheres: left %.2f, right %.2f working)", st.an.ch.cortexL or 1, st.an.ch.cortexR or 1)
	elseif why == "sedation" then
		s = s .. string.format(" (sedated %.2f)", st.sedation or 0)
	elseif why == "arrest" then
		s = s .. string.format(" (no circulation for %.0f s)", CurTime() - (st.arrestSince or CurTime()))
	elseif st.injury > 0.1 then
		s = s .. string.format(" (awake, but injured: bruising left %.2f right %.2f, fracture %.2f, pressure %.2f)", st.focalL, st.focalR, st.fracture, st.pressure)
	end
	return s
end


-- The finer label: what a bystander would call the state, one name, the worst that applies. It is
-- a description for the panel, the log and other code; what the game does follows the base state
-- and the overlays above.
local function Label(st, org, eff, now)
	if st.arrestSince then return "CARDIAC_ARREST" end
	if st.seizing then return "SEIZURE" end
	if st.posture >= C.Anim.postureFloor or now < st.fencingUntil then return "ABNORMAL_POSTURING" end
	if st.pressure >= CB.herniation or st.stemStress >= 0.8 or st.resp < 0.3 then return "CRITICAL_NEUROLOGICAL_STATE" end
	if st.state == St.COMATOSE then return "COMA_LIKE" end
	if (st.sz and st.sz.phase == "postictal") or st.postictalUntil then return "POSTICTAL" end
	if eff < 0.1 then return (st.lossWhy == "knockout" or st.lossWhy == "sedation") and "UNCONSCIOUS" or "DEEP_UNCONSCIOUS" end
	if eff < 0.4 then return "PARTIALLY_RESPONSIVE" end
	if st.state == St.CONFUSED then return "CONFUSED" end
	if st.state == St.STUNNED then return eff < 0.8 and "DAZED" or "STUNNED" end
	if st.balance < 0.5 then return "UNSTABLE" end
	if math.min(st.motorL, st.motorR) < 0.8 then return "MOTOR_IMPAIRED" end
	if st.coordination < 0.75 then return "COORDINATION_IMPAIRED" end
	if st.cognitive < 0.75 then return "DISORIENTED" end
	if st.state == St.IMPAIRED then return "IMPAIRED" end
	return "NORMAL"
end

-- How the character answers to the world, in three parts as an examiner would look at them: the
-- eyes, the voice, movement [S: S16 S18 for the three parts]. These are levels, not a score, and
-- they are not added up.
--   eyes    3 open, 2 open when spoken to, 1 open to pain, 0 closed
--   verbal  4 talks sense, 3 confused, 2 words, 1 sounds, 0 nothing
--   motor   5 does what is asked, 4 moves toward what hurts, 3 pulls away, 2 flexor posture,
--           1 extensor posture, 0 nothing
local function Responsiveness(st, eff)
	local an = st.an
	local ch = an and an.ch or {}
	st.respEyes = eff >= 0.6 and 3 or (eff >= 0.4 and 2 or (eff >= 0.1 and 1 or 0))
	local speech = math.min(ch.language_production or 1, ch.articulation or 1)
	if eff < 0.1 then st.respVerbal = 0
	elseif eff < 0.4 or speech < 0.2 then st.respVerbal = 1
	elseif speech < 0.5 then st.respVerbal = 2
	elseif st.cognitive < 0.75 or (ch.language_comprehension or 1) < 0.6 then st.respVerbal = 3
	else st.respVerbal = 4 end
	if eff >= 0.4 then st.respMotor = math.max(st.motorL, st.motorR) > 0.2 and 5 or 3
	elseif eff >= 0.1 then st.respMotor = 4
	elseif st.postureKind == E.Posture.FLEXOR then st.respMotor = 2
	elseif st.postureKind == E.Posture.EXTENSOR then st.respMotor = 1
	else st.respMotor = st.stemStress < CB.postureFrom and (st.lossWhy == "arrest" and 0 or 3) or 0 end
end

function S.Classify(ply, org, st, now)
	local zc = Z.Consciousness(org)
	local eff = math.min(st.consciousness, zc)
	st.effective = eff

	local base
	if eff < 0.1 then
		-- no way back in sight: structural (diffuse injury, brainstem) rather than a knockout
		base = (st.structural >= 0.9) and St.COMATOSE or St.UNCONSCIOUS
	elseif now < st.confusedUntil then
		base = St.CONFUSED
	elseif now < st.stunUntil and st.injury < 0.15 then
		base = St.STUNNED
	elseif eff < 0.85 or st.injury > 0.1 then
		base = St.IMPAIRED
	else
		base = St.NORMAL
	end

	local ov = 0
	if st.seizing then ov = bor(ov, Ov.SEIZURE) end
	if math.min(st.motorL, st.motorR) < 0.8 then ov = bor(ov, Ov.MOTOR_DEFICIT) end
	if st.posture >= C.Anim.postureFloor or now < st.fencingUntil then ov = bor(ov, Ov.ABNORMAL_POSTURING) end
	if now < st.apnoeaUntil or st.resp < 0.8 then ov = bor(ov, Ov.RESPIRATORY_ABNORMALITY) end
	if st.autonomic > 0.3 then ov = bor(ov, Ov.AUTONOMIC_INSTABILITY) end
	if st.pressure >= CB.herniation then ov = bor(ov, Ov.HERNIATION_LIKE_STATE) end
	if st.arrestSince then ov = bor(ov, Ov.CARDIAC_ARREST) end

	Responsiveness(st, eff)
	-- which way it is going: the change of the overall severity, per second, looked at every two
	if now >= (st.trendNext or 0) then
		local sev = math.max(1 - eff, math.min(st.stemStress, 1), math.min(st.pressure, 1))
		if st.trendSev then st.trend = (st.trendSev - sev) / math.max(now - st.trendT, 0.1) end
		st.trendSev, st.trendT, st.trendNext = sev, now, now + 2
	end

	-- a worse state is taken at once, a milder one after it has held for a moment
	if base ~= st.state then
		if base > st.state then
			st.pending = nil
		elseif st.pending ~= base then
			st.pending, st.pendingSince = base, now
			base = st.state
		elseif now - st.pendingSince < HOLD then
			base = st.state
		else
			st.pending = nil
		end
	else
		st.pending = nil
	end

	if base ~= st.state then
		Push(st, ply, string.format("%s -> %s: %s", string.upper(St.names[st.state]), string.upper(St.names[base]), Reason(st, zc)))
		st.state = base
		st.stateSince = now
	end
	if ov ~= st.overlays then
		local gained, lost = band(ov, bit.bnot(st.overlays)), band(st.overlays, bit.bnot(ov))
		local parts = {}
		if gained ~= 0 then parts[#parts + 1] = "+" .. E.OverlayText(gained) end
		if lost ~= 0 then parts[#parts + 1] = "-" .. E.OverlayText(lost) end
		local why = {}
		if band(gained, Ov.HERNIATION_LIKE_STATE) ~= 0 then why[#why + 1] = string.format("pressure %.2f", st.pressure) end
		if band(gained, Ov.ABNORMAL_POSTURING) ~= 0 then
			why[#why + 1] = now < st.fencingUntil and "impact posturing at the knockout" or string.format("%s posturing %.2f at brainstem stress %.2f", E.Posture.names[st.postureKind], st.posture, st.stemStress)
		end
		if band(gained, Ov.MOTOR_DEFICIT) ~= 0 then
			why[#why + 1] = string.format("left arm %.2f hand %.2f leg %.2f face %.2f, right arm %.2f hand %.2f leg %.2f face %.2f",
				st.armL, st.handL, st.legL, st.faceL, st.armR, st.handR, st.legR, st.faceR)
		end
		if band(gained, Ov.RESPIRATORY_ABNORMALITY) ~= 0 then
			why[#why + 1] = now < st.apnoeaUntil and string.format("no breathing for %.0f s after the impact", st.apnoeaUntil - now) or string.format("respiratory control %.2f", st.resp)
		end
		if band(gained, Ov.AUTONOMIC_INSTABILITY) ~= 0 then why[#why + 1] = string.format("autonomic instability %.2f", st.autonomic) end
		if band(gained, Ov.CARDIAC_ARREST) ~= 0 then why[#why + 1] = string.format("Z-City: heart stopped (brain damage %.2f)", Z.Brain(org)) end
		Push(st, ply, string.format("%s%s", table.concat(parts, " "), #why > 0 and (": " .. table.concat(why, "; ")) or ""))
		st.overlays = ov
	end
	local label = Label(st, org, eff, now)
	if label ~= st.label then
		if st.label and C.sv.log:GetBool() then NT.Print("%.1f %s is now %s", now, IsValid(ply) and ply:Nick() or "?", label) end
		st.label = label
	end
end
