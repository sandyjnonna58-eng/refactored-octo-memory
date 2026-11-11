-- Breathing and cardiac arrest.
--
-- Z-City owns the heart and the lungs (org.heartstop, org.pulse, org.lungsfunction, org.o2) and
-- its CPR acts on them; this file works through those fields and never beside them.
--
--   breathing   stops for seconds after a heavy impact [R: R1 R2]; becomes irregular, then
--               periodic with growing pauses, then stops, as the brainstem loses control
--               [S: S7 R7 R8]. Written as "no breath now" into org.lungsfunction, every tick
--               while it holds (Z-City itself switches breathing back on at random).
--   heart       is never stopped here. Brainstem failure raises Z-City's brain damage to the
--               value at which Z-City stops it (sv_brain.lua); a slowing pulse before that is
--               Z-City's own response to brain damage.
--   an arrest   from whatever cause is given its look: consciousness goes within seconds (Z-City
--               alone would leave a character awake until the oxygen runs out), a few jerks in
--               some, then stillness, with agonal gasps in a minority that space out and stop.
--               No clutching, no struggle. When CPR or adrenaline brings the heart back in
--               Z-City, the character comes round confused.

local NT = NeuroTrauma
NT.CardioResp = NT.CardioResp or {}
local CR = NT.CardioResp
local C, Z, E = NT.Config, NT.ZC, NT.E
local CA = C.Arrest

CR.Pattern = { NORMAL = 0, APNOEA = 1, IRREGULAR = 2, PERIODIC = 3, GASPING = 4, NONE = 5, ICTAL = 6 }
CR.PatternNames = { [0] = "normal", "apnoea after impact", "irregular", "periodic with pauses", "agonal gasps", "none", "held and broken up by the convulsion" }
local PT = CR.Pattern

local gaspSound = nil
local function GaspSound()
	if gaspSound == nil then
		gaspSound = file.Exists("sound/breathing/agonalbreathing_1.wav", "GAME")
	end
	return gaspSound
end

local function Gasp(ply, st, now)
	local body = Z.Body(ply)
	if not IsValid(body) then return end
	st.gasps = (st.gasps or 0) + 1
	if GaspSound() then body:EmitSound("breathing/agonalbreathing_" .. math.random(13) .. ".wav", 60) end
	-- the chest is heaved up and sinks back, the head goes back (sv_motor.lua: a pull inside the
	-- body, so a gasp cannot lift it)
	if body:IsRagdoll() and NT.Motor and NT.Motor.Gasp then NT.Motor.Gasp(ply) end
end

-- Called with every step of an injured brain, before its function is worked out.
function CR.Update(ply, org, st, now, dt)
	-- Z-City's heart can flicker. From a brain damage of 0.5 it is stopped by a throw of dice at
	-- every tick, and whenever adrenaline is above zero another throw restarts it: seen in the logs
	-- as an arrest that began and ended three times a second. An arrest is taken to have begun when
	-- the heart has been still for a moment, and to be over when it has beaten for longer.
	-- the course of a rifle round through the head (sv_trauma.lua): the heart is stopped when the
	-- body has fallen, and the death is asked of Z-City when the arrest has lasted its seconds
	local tc = st.terminal
	if tc then
		if not tc.arrested and now >= tc.arrestAt then
			tc.arrested = true
			org.heartstop = true
			st.arrestCause = tc.cause
			st.heartStill = now - CA.confirm - 0.01
		end
		if tc.arrested then org.adrenaline_try = now + 2 end
		if not tc.done and now >= tc.dieAt then
			tc.done = true
			NT.States.Push(st, ply, string.format("rule: %.1f s in cardiac arrest: death (Z-City's brain value is raised past its own threshold)", now - tc.arrestAt))
			org.brain = 1
		end
	end
	local raw = Z.HeartStopped(org)
	if raw then
		st.heartStill, st.heartBeats = st.heartStill or now, nil
	else
		st.heartBeats, st.heartStill = st.heartBeats or now, nil
	end
	local stopped = st.arrestSince ~= nil
	if not stopped then
		stopped = raw and now - st.heartStill >= CA.confirm
	elseif not raw and now - st.heartBeats >= CA.confirmBack then
		stopped = false
	end
	-- A heart that has stopped because the brainstem has failed does not start again by itself:
	-- Z-City's restart by adrenaline is kept waiting through its own timer for it.
	if raw and Z.Takeover() and (st.stemLasting or 0) >= C.Brain.stemFailure then org.adrenaline_try = now + 2 end
	if NT.Cardio then NT.Cardio.Couple(ply, org, st, now, dt or 0.1) end

	-- an arrest begins: plan what it will look like, from its own seed
	if stopped and not st.arrestSince then
		st.arrestSince = tc and now or st.heartStill or now
		st.rosc = nil
		st.arrestCause = st.arrestCause or (NT.Cardio and NT.Cardio.Cause(org, st)) or "unknown cause"
		local rng = NT.RNG(math.random(1, 2147483646))
		local parts = {}
		if tc then
			-- (four seconds: no jerks, which belong to a convulsion in the eyes of anyone watching;
			-- one gasp, which belongs to nothing else)
			local at = now + C.Headshot.gaspAt
			st.gasp = { next = at, every = 99, stop = at + 0.2 }
			parts[#parts + 1] = string.format("one gasp at %.1f s", C.Headshot.gaspAt)
		elseif rng:Next() < CA.jerksP then
			st.jerksFrom, st.jerksDur = now + rng:Range(CA.jerksAfter[1], CA.jerksAfter[2]), rng:Range(CA.jerksTime[1], CA.jerksTime[2])
			parts[#parts + 1] = "a few jerks as consciousness goes"
		end
		if tc then
			-- (planned above)
		elseif rng:Next() < CA.gaspP then
			st.gasp = { next = now + rng:Range(CA.gaspFirst[1], CA.gaspFirst[2]), every = rng:Range(CA.gaspEvery[1], CA.gaspEvery[2]), stop = now + rng:Range(CA.gaspFor[1], CA.gaspFor[2]) }
			parts[#parts + 1] = string.format("agonal gasps for %.0f s", st.gasp.stop - now)
		else
			parts[#parts + 1] = "no breathing at all"
		end
		NT.States.Push(st, ply, string.format("circulation has stopped (%s): %s", st.arrestCause, table.concat(parts, ", ")))
	elseif not stopped and st.arrestSince then
		local down = now - st.arrestSince
		st.arrestSince, st.gasp, st.jerksFrom = nil, nil, nil
		st.confusedUntil = math.max(st.confusedUntil, now + CA.wakeConfused[1] + (CA.wakeConfused[2] - CA.wakeConfused[1]) * math.min(down / 120, 1))
		st.locUntil = math.max(st.locUntil, now + math.min(down * 0.5, 20))
		-- The return of circulation is not a reset. What the brain lost while it had no blood
		-- stays lost, and part of the injury only follows afterwards (reperfusion, swelling: the
		-- second hit [S: K1 K2]): a share of the damage done is added again over the time after.
		local cpr = st.cpr
		st.rosc = { t = now, down = down, compressions = cpr and cpr.n or 0 }
		st.arrestCause, st.cpr = nil, nil
		local an = st.an
		local later, sum = {}, 0
		for id, v in pairs(an.isch) do
			if v > 0.02 then later[id] = v * C.Cardio.secondHit sum = sum + later[id] end
		end
		if sum > 0 then
			an.secondHit = { map = later, left = C.Cardio.secondHitMinutes * 60 }
			an.vascActive = true
		end
		NT.States.Push(st, ply, string.format("circulation is back after %.0f s%s%s", down,
			cpr and string.format(" and %d chest compressions", cpr.n) or "",
			sum > 0 and string.format("; the brain was injured while it had no blood, and more will follow (%d regions)", table.Count(later)) or ""))
		hook.Run("NT_ROSC", ply, org, st, down)
	end

	-- breathing
	local pattern, hold = PT.NORMAL, false
	if stopped then
		local g = st.gasp
		if g and now < g.stop then
			pattern = PT.GASPING
			if now >= g.next then
				Gasp(ply, st, now)
				g.every = g.every * CA.gaspStretch
				g.next = now + g.every
			end
		else
			pattern = PT.NONE
		end
		-- (the model's gasps are the arrest's breathing sounds: Z-City's own timer is kept waiting)
		if Z.Takeover() then org.lastsoundtime = now + 5 end
	elseif now < st.apnoeaUntil then
		pattern, hold = PT.APNOEA, true
	elseif st.sz and (st.sz.phase == "tonic" or st.sz.phase == "clonic" or st.sz.phase == "subtle") and st.sz.kind ~= "jerks" then
		-- A convulsion: the chest is held in the tonic phase and breathing is broken up in the
		-- clonic one. This is why a seizure that does not stop endangers breathing more than the
		-- drug that stops it [S: Z10 Z11].
		pattern = PT.ICTAL
		if st.sz.phase == "tonic" then hold = true
		else hold = (now % 5) / 5 < C.Seizure.breathHold * (st.sz.phase == "subtle" and 0.6 or 1) end
		-- Z-City's oxygen store refills within a breath or two, so broken-up breathing alone would
		-- cost nothing however long it lasts. A convulsion that goes on puts a ceiling on the
		-- store that sinks with its length [P]; it lifts when the convulsion ends.
		local CS = C.Seizure
		local ran = now - (st.sz.convSince or now)
		if ran > CS.hypoxiaAfter and istable(org.o2) and tonumber(org.o2[1]) then
			local cap = math.max((tonumber(org.o2.range) or 30) - (ran - CS.hypoxiaAfter) / CS.hypoxiaPer, CS.hypoxiaFloor)
			if org.o2[1] > cap then org.o2[1] = cap end
		end
	elseif st.resp < 0.05 then
		pattern, hold = PT.NONE, true
	elseif st.resp < 0.8 then
		-- pauses in a slow cycle, longer the less control is left
		local cyc = (now / CA.breathCycle + (st.netSeed or 0) / 32) % 1
		if cyc < (1 - st.resp) * CA.pauseShare then hold = true end
		pattern = st.resp < 0.45 and PT.PERIODIC or PT.IRREGULAR
	end
	if hold then
		org.lungsfunction = false
		st.ownLungs = true
	elseif st.ownLungs then
		st.ownLungs = nil
		if not stopped then org.lungsfunction = true end
	end
	if pattern ~= st.respPattern then
		if st.respPattern ~= nil or pattern ~= PT.NORMAL then
			NT.States.Push(st, ply, string.format("breathing: %s", CR.PatternNames[pattern]))
		end
		st.respPattern = pattern
	end
end

-- A heart that Z-City has stopped for a reason of its own (blood loss, a wound of the heart, cold),
-- or brain damage it has booked without an impact this module saw (lack of oxygen),
-- belongs to a character that may have no neurological record yet: it gets one, so that the arrest
-- looks like an arrest. Twice a second over the players, one field each.
timer.Create("NT_ArrestWatch", 0.5, 0, function()
	if not NT.Enabled() then return end
	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		if istable(org) and (org.heartstop == true or (tonumber(org.brain) or 0) >= 0.15) and ply:Alive() and org.alive ~= false and not NT.Get(org) then
			NT.Brain.Ensure(org)
		end
	end
end)
