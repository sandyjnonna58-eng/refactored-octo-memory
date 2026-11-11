-- The trauma pipeline: the one place where an injury event becomes its consequences.
--
-- Every source of an event hands it to NeuroTrauma.ProcessTraumaEvent: the measured impacts of a
-- ragdoll and the bullets, blows, blasts and landings that sv_injury.lua builds from Z-City's
-- damage hooks, and the synthetic events of the API, the developer commands and the tests. Nothing
-- else turns an injury into a state. The stages run in this order, in one call, and each leaves a
-- line in the log (neuro_log 1, and always in the test log):
--
--    1 validate        a character with an organism, the module switched on. A character that is
--                      already dead takes the fatal branch: no record, a terminal collapse.
--    2 mechanism       what kind of event (set by its source), where on the head, measured or estimated
--    3 severity        rotation and contact (sv_biomech.lua, Evaluate) and the loads they give (Loads)
--    4 anatomy         which structures are damaged (sv_anatomy.lua, ApplyEvent)
--    5 vessels         what a track cut and where it bleeds (sv_vascular.lua, TrackSpaces)
--    6 neurological    the transient effects of the event, then one step of the model: what every
--                      region and channel can still do
--    7 circulation     breathing, the heart, an arrest (sv_cardioresp.lua, sv_cardio.lua)
--    8 consciousness   the state and its overlays (sv_states.lua)
--    9 animation       the animation state, in this same call (sv_anim.lua)
--   10 delayed         what the event has set going: a lesion that grows, swelling, the risk of a
--                      seizure, an impact convulsion. These are variables the stepper advances;
--                      nothing is scheduled by timer.
--   11 clients         the state message to everybody who sees the character (sv_net.lua)
--   12 visible         the ragdoll motor and the collapse (sv_motor.lua)
--
-- Stages 4 to 6 are done by sv_brain.lua (Apply), 6 to 12 by one step of the model (Step), which
-- runs them in that order; this file calls both and reports what each stage left behind.
--
-- Before stage 1, inside Z-City's own damage call, sv_injury.lua answers one question for a
-- bullet or an explosion that met Z-City's brain box: who decides what it does (triage). That has
-- to happen there, because Z-City's organism think runs at the end of the same damage call and
-- kills at a brain value of 0.7 (docs/NEUROTRAUMA_TRAUMA_CHAIN.md). The event itself is processed
-- one tick later, when every listener of the damage call has run and Z-City has dropped the
-- character.

local NT = NeuroTrauma
NT.Trauma = NT.Trauma or {}
local T = NT.Trauma
local C, Z, E = NT.Config, NT.ZC, NT.E
local I, B, BR, A = NT.Injury, NT.Biomech, NT.Brain, NT.Anim

T.count, T.fatal = 0, 0
T.last = nil                     -- the report of the last event (tests, the debug panel)
T.outcomes = {}                  -- outcome -> how many events ended so

-- What an event has come to, in the words of the outcomes a head injury can have, and which of
-- the three cases it is:
--   A  fatal at once: there is no neurological period to show
--   B  survivable, however severe: the character lives and the state is seen
--   C  critical, on the way to an arrest: failure of the brainstem, of breathing, of the circulation
function T.Classify(st, ev, alive)
	if not alive then return "IMMEDIATE_DEATH", "A" end
	if not st then return "SURVIVES", "B" end
	local CB = C.Brain
	local eff = st.effective or st.consciousness or 1
	-- where it will end, if nothing is done: the lesion at its final size, on top of the swelling
	-- the injury is heading for (and what the rest of the lesion will add to that)
	local willPress = 0
	do
		local grows = math.max(st.massFinal - st.mass, 0)
		local vol = math.max(st.mass, st.massRate > 0 and st.massFinal or 0)
			+ math.max(st.swell, math.min((st.swellTarget or 0) + (st.massRate > 0 and CB.swellMass * grows or 0), 1.2))
		if vol > CB.reserve then willPress = ((vol - CB.reserve) / (1 - CB.reserve)) ^ CB.pressurePow end
	end
	local critical = st.arrestSince ~= nil or st.stemStress >= 0.8 or st.pressure >= CB.herniation or st.resp < 0.3
	local case = (critical or willPress >= CB.herniation or st.stemLasting >= CB.postureFrom) and "C" or "B"
	if critical then return "CRITICAL_NEUROLOGICAL_STATE", case end
	if st.sz or st.convulsionFrom then return "SEIZURE", case end
	if eff < 0.1 then return "UNCONSCIOUS", case end
	if eff < 0.6 or math.min(st.motorL, st.motorR) < 0.5 or st.balance < 0.5 or st.cognitive < 0.5 then return "SEVERELY_IMPAIRED", case end
	return "SURVIVES", case
end

local function Report(ev, lines)
	local who = IsValid(ev.ply) and ev.ply:Nick() or "?"
	T.last = { id = ev.id, who = who, lines = lines, outcome = ev.outcome, case = ev.case }
	if not lines then return end
	local loud = C.sv.log:GetBool()
	for i, l in ipairs(lines) do
		local s = string.format("trauma #%d %s %s", ev.id or 0, who, l)
		if loud then NT.Print("%s", s) end
		if NT.TestLog then NT.TestLog("  %s", s) end
	end
end

-- The fatal branch: an event on a character that is already dead (Z-City killed it inside the
-- damage call, because the triage left its value to stand or because a rule of its own applied).
local function Fatal(victim, ev, lines)
	T.fatal = T.fatal + 1
	ev.outcome, ev.case = "IMMEDIATE_DEATH", "A"
	T.outcomes[ev.outcome] = (T.outcomes[ev.outcome] or 0) + 1
	if lines then
		lines[#lines + 1] = string.format("1 validate: the character is dead%s", ev.fatal and (" (" .. ev.fatal .. ")") or " (killed by Z-City inside the damage call)")
	end
	if lines then
		lines[#lines + 1] = string.format("2 mechanism: %s", I.Describe(ev))
	end
	if lines then
		lines[#lines + 1] = "9 animation: TERMINAL_COLLAPSE (priority 95) [TERMINAL_DEATH]: no neurological period to show; the module drives nothing, Z-City's own response to a death runs"
	end
	if lines then
		lines[#lines + 1] = "outcome: IMMEDIATE_DEATH, case A"
	end
	Report(ev, lines)
	hook.Run("NT_FatalEvent", victim, ev.org, ev)
	return ev
end

-- The course of a rifle round through the head, by the rule of the game (neuro_headshot_rules):
-- the fall, then cardiac arrest for some four seconds, then death. The heart is stopped and the
-- death is asked of Z-City (by raising its brain value past its own threshold) because the rule
-- says so, not because the model would: this is the one place where the module stops a heart. The
-- steps of the course are taken in sv_cardioresp.lua. It begins before the model takes its step
-- for the event, so that the step already shows the fall and nothing else.
function T.BeginTerminal(victim, org, st, ev)
	if st.terminal then return end
	local now = CurTime()
	local H = C.Headshot
	local hold = C.sv.rifleArrest:GetFloat()
	st.terminal = { t0 = now, arrestAt = now + H.collapse, dieAt = now + H.collapse + hold, hold = hold, cause = "catastrophic head wound" }
	st.locUntil = math.max(st.locUntil, now + 600)
	st.fencingUntil = 0
	st.convulsionFrom, st.convulsionUntil = nil, nil
	NT.States.Push(st, victim, string.format("rule: a rifle round through the head: a fall, cardiac arrest from %.1f s for %.1f s, then death", H.collapse, hold))
	-- The fall: the knees give, the body sits back and goes over backward, a little the way the
	-- bullet went. (Thrown the way the bullet went and no other, a body shot from behind went over
	-- its own head and one shot from the side landed on its face, run p24c; a body whose legs go
	-- from under it comes down on its back more often than not, and on its back it is seen.)
	local K = NT.Collapse
	if K and victim:IsPlayer() then
		local fwd = victim:GetForward()
		fwd.z = 0
		fwd:Normalize()
		local d = -fwd
		if isvector(ev.dirWorld) then d = d + Vector(ev.dirWorld.x, ev.dirWorld.y, 0) * 0.4 end
		d:Normalize()
		local rag = victim.FakeRagdoll
		if not IsValid(rag) then
			K.TakeDown(victim, st, "drop", d)
		elseif now - rag:GetCreationTime() < 0.3 then
			-- (Z-City dropped it inside the damage call, a tick ago: the ragdoll is given the fall)
			K.Throw(rag, "drop", d, fwd, 1)
			st.collapseKind = "drop"
		end
	end
end

function NT.ProcessTraumaEvent(victim, ev)
	if not istable(ev) then return nil end
	-- (the report of the stages is put into words only when somebody reads it: the server's log
	-- switch, or the test log unless a scene that measures cost has asked for silence)
	local lines = (C.sv.log:GetBool() or (NT.TestLog and not T.silent)) and {} or nil
	-- 1 validate
	if not NT.Enabled() then return nil end
	if I.muted and not ev.synthetic then return nil end
	if not IsValid(victim) then return nil end
	local org = ev.org or (victim.organism)
	if not istable(org) then return nil end
	ev.ply, ev.org = victim, org
	T.count = T.count + 1
	I.Complete(ev)
	-- 3 (first half) the kinematics of the event: needed for its description
	if ev.rotEff == nil then B.Evaluate(ev) end
	if victim:IsPlayer() and not victim:Alive() then
		I.Record(ev, true)
		return Fatal(victim, ev, lines)
	end
	-- (events made by hand are not part of a character's history of real injuries)
	if not ev.synthetic then I.Record(ev, false) end
	if lines then
		lines[#lines + 1] = string.format("1 validate: alive, organism present%s", ev.restored and string.format("; Z-City's brain value %.2f for this hit was taken back (triage)", ev.zcityBrain or 0) or "")
	end
	if lines then
		lines[#lines + 1] = string.format("2 mechanism: %s", I.Describe(ev))
	end
	-- (listeners: tests, other addons. The model itself is called below, not through the hook.)
	if not ev.synthetic then hook.Run("NT_InjuryEvent", victim, org, ev) end
	if BR.paused then
		if lines then
			lines[#lines + 1] = "the model is paused: recorded, not applied"
		end
		Report(ev, lines)
		return ev
	end
	-- 3 to 6: loads, anatomy, vessels, transient effects
	local st, L = BR.Apply(victim, org, ev)
	if ev.terminal and st then T.BeginTerminal(victim, org, st, ev) end
	if not st then
		-- (below what injures a brain: this event changes nothing. A character that already carries
		-- an injury is in the state that injury gave it, and that is what is reported.)
		if lines then
			lines[#lines + 1] = string.format("3 severity: rotation %.1f, contact %.1f: below what injures a brain; nothing applied", ev.rotEff or 0, ev.contactEff or 0)
		end
		st = NT.Get(org)
		ev.noEffect = true
		if st then
			ev.outcome, ev.case = T.Classify(st, ev, true)
			if lines then
				lines[#lines + 1] = string.format("outcome: nothing from this event; the character stays %s, case %s (%s)", ev.outcome, ev.case, tostring(st.label))
			end
		else
			ev.outcome, ev.case = "SURVIVES", "B"
			T.outcomes[ev.outcome] = (T.outcomes[ev.outcome] or 0) + 1
			if lines then
				lines[#lines + 1] = "outcome: SURVIVES, case B (no injury)"
			end
		end
		Report(ev, lines)
		return ev
	end
	local an = st.an
	if lines then
		lines[#lines + 1] = string.format("3 severity: rotation %.1f, contact %.1f -> diffuse +%.2f, focal L +%.2f R +%.2f, brainstem +%.2f%s",
			L.x or 0, L.k or 0, L.diffuse, L.focalL, L.focalR, L.stem, ev.trajectory and ("; track " .. ev.trajectory) or "")
	end
	if lines then
		lines[#lines + 1] = string.format("4 anatomy: %d regions and %d tracts damaged in all; lesion left %.2f right %.2f", table.Count(an.d), table.Count(an.td), an.lesionL or 0, an.lesionR or 0)
	end
	if lines then
		lines[#lines + 1] = string.format("5 vessels: %s%s", an.cutLarge and "a large artery cut; " or "",
			st.massRate > 0 and string.format("%s, growing to %.2f", tostring(st.massKind), st.massFinal) or "no bleeding that takes up room")
	end
	-- 6 to 12: one step of the model, now
	local now = CurTime()
	BR.Step(victim, org, st, now + 0.001)
	st = NT.Get(org)
	if not st then
		-- (the step closed the record: nothing was left of the event)
		ev.outcome, ev.case = "SURVIVES", "B"
		if lines then
			lines[#lines + 1] = "6 neurological: back at baseline within the step"
		end
		if lines then
			lines[#lines + 1] = "outcome: SURVIVES, case B"
		end
		T.outcomes[ev.outcome] = (T.outcomes[ev.outcome] or 0) + 1
		Report(ev, lines)
		return ev
	end
	if lines then
		lines[#lines + 1] = string.format("6 neurological: %s; brainstem stress %.2f, pressure %.2f, strength L %.2f R %.2f, balance %.2f", tostring(st.label), st.stemStress, st.pressure, st.motorL, st.motorR, st.balance)
	end
	if lines then
		lines[#lines + 1] = string.format("7 circulation: %s; breathing %s (control %.2f)%s", tostring(st.cardio or "NORMAL"),
			NT.CardioResp.PatternNames[st.respPattern or 0] or "?", st.resp, st.arrestSince and "; the heart has stopped" or "")
	end
	if lines then
		lines[#lines + 1] = string.format("8 consciousness: %.2f (%s), state %s", st.effective or st.consciousness, tostring(st.lossWhy), string.upper(E.State.names[st.state] or "?"))
	end
	if lines then
		lines[#lines + 1] = string.format("9 animation: %s%s", A.Describe(st), A.Family(st.anim and st.anim.mode) and (" [" .. A.Family(st.anim.mode) .. "]") or "")
	end
	if lines then
		local later = {}
		if st.massRate > 0 and st.mass < st.massFinal then later[#later + 1] = string.format("a lesion growing %.4f a second to %.2f", st.massRate * C.sv.timescale:GetFloat(), st.massFinal) end
		if st.convulsionFrom then later[#later + 1] = string.format("an impact convulsion in %.1f s", st.convulsionFrom - now) end
		if now < st.locUntil then later[#later + 1] = string.format("unconscious for %.0f s more, then confused for %.0f", st.locUntil - now, math.max(st.confusedUntil - st.locUntil, 0)) end
		if now < st.apnoeaUntil then later[#later + 1] = string.format("no breath for %.0f s", st.apnoeaUntil - now) end
		if st.seizureRisk > 0.05 then later[#later + 1] = string.format("seizure risk %.2f", st.seizureRisk) end
		if an.vascActive then later[#later + 1] = "tissue without blood supply dying over the next minutes" end
		if lines then
			lines[#lines + 1] = "10 delayed: " .. (#later > 0 and table.concat(later, "; ") or "nothing set going")
		end
	end
	if lines then
		lines[#lines + 1] = string.format("11 clients: state message version %s", tostring(st.netVersion or "-"))
	end
	if lines then
		local rag = victim:IsPlayer() and victim.FakeRagdoll or nil
		local ctl = IsValid(rag) and NT.Motor and NT.Motor.ctlOf[rag]
		if lines then
			lines[#lines + 1] = string.format("12 visible: %s%s", IsValid(rag) and "down, in a ragdoll" or "on its feet",
				ctl and string.format("; the motor drives it (strength %.2f)", ctl.env or 0) or (IsValid(rag) and "; limp" or "; the pose layers of each client"))
		end
	end
	ev.outcome, ev.case = T.Classify(st, ev, true)
	st.lastOutcome, st.lastCase = ev.outcome, ev.case
	T.outcomes[ev.outcome] = (T.outcomes[ev.outcome] or 0) + 1
	if lines then
		lines[#lines + 1] = string.format("outcome: %s, case %s", ev.outcome, ev.case)
	end
	Report(ev, lines)
	-- 12, for a character the hit has left on its feet: it does not simply stand there. It loses
	-- control for a moment, away from where it was struck, and catches itself or does not.
	local K = NT.Collapse
	if K and victim:IsPlayer() and not IsValid(victim.FakeRagdoll) and not A.Critical(st.anim and st.anim.mode)
		and (L.stun or (L.x or 0) >= C.Collapse.dazeRot) then
		local dir
		if ev.hit then dir = victim:GetRight() * ev.hit[1] - victim:GetForward() * ev.hit[2]
		elseif (ev.lat or 0) ~= 0 then dir = victim:GetRight() * ev.lat end
		K.Stagger(victim, st, { dir = dir, kind = "topple", peak = math.Clamp((L.x or 0) / 16, 0.45, 1),
			fallP = math.Clamp((1 - st.balance) * 1.2 + (L.x or 0) / 60, 0.15, 0.9), stun = C.Motor.stumbleTime[1],
			why = string.format("a hit that dazed (rotation %.1f)", L.x or 0) })
	end
	hook.Run("NT_TraumaProcessed", victim, org, st, ev)
	return ev
end
