-- Treatment that acts on the neurological model. One drug so far: midazolam, the rescue
-- medication for a seizure that does not stop.
--
-- What the literature says and what is made of it here:
--   * A benzodiazepine given early stops most prolonged convulsive seizures. Intramuscular
--     midazolam by paramedics: 73 % without seizures on arrival, convulsions ending a median of
--     3.3 minutes after the injection [S: Z9]. Here: the dose acts after a delay (shorter than in
--     life, so that it fits a round [G]) and then stops a running seizure with that chance.
--   * A second treatment works less well than the first, a third much less [S: Z11]. Here: the
--     chance falls with every dose given during the same seizure (numbers G).
--   * Breathing: patients in status treated with a benzodiazepine had FEWER respiratory and
--     circulatory complications than those given placebo (10.6 % and 10.3 % against 22.5 %
--     [S: Z10]; guideline, level A [S: Z11]): the seizure is the greater danger to breathing.
--     Here: a convulsion holds the breath (sv_cardioresp.lua), so stopping it helps; the drug's own
--     depression of breathing is small for one dose and grows with repeated doses and with a
--     brainstem that is already failing [P].
--   * It sedates [S: Z14]: one dose leaves an uninjured adult drowsy, several put him out [G].
--   * It does not treat the injury: no injury variable is touched, and a seizure can come back
--     once the drug has worn off (11 % recurred before arrival in [S: Z9]).
-- No dose calculation: one item is one dose.
--
-- Every administration is validated on the server: who gives it must be alive, awake, within reach
-- and have a hand that works; calls are rate-limited per giver.

local NT = NeuroTrauma
NT.Treatment = NT.Treatment or {}
local T = NT.Treatment
local C, Z, E = NT.Config, NT.ZC, NT.E
local CM = C.Med
local Clamp, min, max = math.Clamp, math.min, math.max

MedicalTreatment = MedicalTreatment or {}

T.count = T.count or 0
local lastGive = setmetatable({}, { __mode = "k" })

local function Level(m, now)
	local lvl = 0
	for _, d in ipairs(m.doses) do
		if now >= d.onsetAt then
			local rise = min((now - d.onsetAt) / CM.midazolam.rise, 1)
			lvl = lvl + rise * 0.5 ^ ((now - d.onsetAt) / CM.midazolam.halfLife)
		end
	end
	return lvl
end

-- Called with every step of a record that has a drug on board.
function T.Update(ply, org, st, now, dt)
	local med = st.med
	if not med then return end
	local m = med.midazolam
	if m then
		local K = CM.midazolam
		for _, d in ipairs(m.doses) do
			if not d.acted and now >= d.onsetAt then
				d.acted = true
				local sz = st.sz
				local running = sz and sz.phase ~= "postictal" and sz.kind ~= "jerks"
				if running then
					sz.dosesActed = (sz.dosesActed or 0) + 1
					local p = K.stopP[min(sz.dosesActed, #K.stopP)]
					if math.random() < p then
						NT.Seizure.Terminate(ply, st, now, string.format("midazolam, dose %d of this seizure", sz.dosesActed))
					else
						NT.States.Push(st, ply, string.format("midazolam is acting; the seizure goes on (dose %d of this seizure, chance was %.0f%%)", sz.dosesActed, p * 100))
					end
				else
					NT.States.Push(st, ply, "midazolam is acting")
				end
			end
		end
		local lvl = Level(m, now)
		m.level = lvl
		st.sedation = Clamp(K.sedation * lvl, 0, 0.97)
		st.respDrug = Clamp(K.resp * lvl * lvl, 0, 0.95)
		st.seizureGuard = Clamp(K.guard * lvl, 0, 0.9)
		-- worn off
		local last = m.doses[#m.doses]
		if lvl < 0.03 and last.acted and now - last.onsetAt > K.halfLife then
			med.midazolam = nil
			st.sedation, st.respDrug, st.seizureGuard = nil, nil, nil
			NT.States.Push(st, ply, "midazolam has worn off")
		end
	end
	if next(med) == nil then st.med = nil end
end

local DRUGS = { midazolam = true }

-- Give a drug to a patient. giver may be nil (console, map logic, another addon). Returns
-- true, or false and the reason.
function T.Administer(patient, drug, giver, opts)
	if not NT.Enabled() then return false, "module off" end
	if not DRUGS[drug] then return false, "unknown drug" end
	if not IsValid(patient) then return false, "no patient" end
	local owner = patient:IsPlayer() and patient or Z.Owner(patient)
	local org = Z.Org(patient)
	if not IsValid(owner) or not org or not owner:Alive() or org.alive == false then return false, "no living patient" end
	local now = CurTime()
	if IsValid(giver) and giver:IsPlayer() and not (opts and opts.trusted) then
		if not giver:Alive() then return false, "giver is dead" end
		if (lastGive[giver] or 0) > now then return false, "too soon" end
		lastGive[giver] = now + CM.cooldown
		local gorg = giver.organism
		if istable(gorg) and (gorg.otrub or Z.Consciousness(gorg) < 0.3) then return false, "giver is not conscious" end
		local gst = istable(gorg) and NT.Get(gorg)
		if gst and max(gst.handL, gst.handR) < CM.giverHand then return false, "giver's hands do not work" end
		if giver ~= owner then
			local a, b = Z.Body(giver), Z.Body(owner)
			if not IsValid(a) or not IsValid(b) or a:GetPos():DistToSqr(b:GetPos()) > CM.reach * CM.reach then return false, "out of reach" end
		end
	end
	local st = NT.Brain.Ensure(org)
	st.med = st.med or {}
	local K = CM[drug]
	local m = st.med[drug]
	if not m then m = { doses = {}, level = 0 } st.med[drug] = m end
	if #m.doses >= K.maxDoses then return false, "no more can be given" end
	local onset = K.onset[1] + math.random() * (K.onset[2] - K.onset[1])
	m.doses[#m.doses + 1] = { t = now, onsetAt = now + onset, acted = false, by = IsValid(giver) and giver or nil }
	st.quiet = false
	T.count = T.count + 1
	NT.States.Push(st, owner, string.format("%s given%s (dose %d on board); it will act in about %.0f s", drug,
		IsValid(giver) and giver ~= owner and (" by " .. giver:Nick()) or "", #m.doses, onset))
	hook.Run("NT_Treated", owner, org, st, drug, giver)
	return true
end

-- The public form asked for: MedicalTreatment.Administer(patient, "midazolam" [, giver])
function MedicalTreatment.Administer(patient, drug, giver)
	return T.Administer(patient, drug, giver)
end
