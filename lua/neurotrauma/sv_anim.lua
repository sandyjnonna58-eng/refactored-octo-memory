-- The animation state, on the server: which mode a character is in (sh_anim.lua), how strongly,
-- since when and for how long. It is worked out from the state of the model with every step of an
-- injured brain and at once when an injury event has been applied (not a step later), and it is
-- the one thing the movers of the body read.
--
--   st.anim = { mode, priority, blend, startTime, duration, why, into }
--     blend      the intensity of the mode, 0..1
--     duration   seconds the mode is expected to last from startTime, 0 when it has no set end
--     into       for CRITICAL_COLLAPSE: the mode the body is collapsing into
--
-- Nothing here invents a state: every mode is a reading of variables the model already has. What
-- this file adds is the order between them, the floor below which a state is not claimed, and the
-- guarantee that a critical state is seen: a character in one is taken down if it still stands,
-- cannot get up and cannot steer its ragdoll, whatever Z-City's own consciousness value says.

local NT = NeuroTrauma
local A = NT.Anim
local C, Z, E = NT.Config, NT.ZC, NT.E
local CA = C.Anim
local M = A.Mode
local Clamp, max, min = math.Clamp, math.max, math.min

-- Which mode applies now, of the highest priority: mode, intensity, seconds it will last (0: open),
-- and a word for why. (This runs ten times a second for every injured character: the full reason
-- is put into words only when the mode changes, by Why below.)
local function Pick(st, now, down)
	local sz = st.sz
	local eff = st.effective or st.consciousness or 1
	-- circulation has stopped
	local tc = st.terminal
	if st.arrestSince then
		-- (the arrest of a rifle round through the head is shown as an arrest for the seconds the
		-- rule gives it, whatever is left of the brainstem)
		if tc and not tc.done then return M.CARDIAC_ARREST, 1, max(tc.dieAt - now, 0), "arrest" end
		if (st.stemLasting or 0) >= C.Brain.stemFailure then return M.TERMINAL_COLLAPSE, 1, 0, "terminal" end
		return M.CARDIAC_ARREST, 1, 0, "arrest"
	end
	-- (and the fall before it is a fall: nothing else is shown in that second)
	if tc and not tc.arrested then return M.CRITICAL_UNCONSCIOUS, 1, max(tc.arrestAt - now, 0), "a rifle round through the head: the fall" end
	-- a convulsion of the whole body
	if sz and sz.kind ~= "jerks" then
		local ph = sz.phase
		local left = max(sz.tEnd - now, 0)
		if ph == "tonic" then
			return M.SEIZURE, 1, left, "tonic phase"
		elseif ph == "clonic" then
			local f = Clamp((now - sz.t0) / max(sz.tEnd - sz.t0, 0.1), 0, 1)
			return M.SEIZURE, max((1 - 0.35 * f) * (1 - 0.6 * (sz.weak or 0)), CA.floor), left, "clonic phase"
		elseif ph == "jerks" then
			return M.SEIZURE, 0.6, left, "jerks after an impact"
		elseif ph == "subtle" then
			return M.SEIZURE, CA.floor, left, "a convulsion that has gone on for minutes: little left to see"
		end
	end
	-- an abnormal posture (a body that lies and does not answer)
	if now < st.fencingUntil and Z.Takeover() then
		return M.ABNORMAL_POSTURING, 1, st.fencingUntil - now, "the posture of a knockout"
	end
	if st.posture >= CA.postureFloor then return M.ABNORMAL_POSTURING, max(st.posture, 0.5), 0, "posture" end
	-- after a convulsion
	if ((sz and sz.phase == "postictal") or st.postictalUntil) and eff < 0.4 then
		return M.POSTICTAL, 1, sz and max(sz.tEnd - now, 0) or 0, "postictal"
	end
	-- not conscious
	if eff < 0.1 then return M.CRITICAL_UNCONSCIOUS, 1, 0, "unconscious" end
	-- down and coming round
	-- (not while wakefulness is still falling: a body on its way under does not stir)
	if down and eff < 0.4 and (st.effTrend or 0) >= -0.002 then return M.RECOVERING, Clamp((0.4 - eff) / 0.3, CA.floor, 1), 0, "recovering" end
	-- on its feet and losing it (sv_collapse.lua)
	local sg = st.stagger
	if sg and not down then return M.STAGGER, sg.peak, max(sg.t0 + sg.dur - now, 0), "stagger" end
	-- a seizure on the feet
	if sz and (sz.phase == "focal" or sz.phase == "impaired") then
		return M.FOCAL_SEIZURE, max(sz.strength or 1, 0.5), max(sz.tEnd - now, 0), sz.phase == "focal" and "one side in a beat" or "awareness lost"
	end
	-- a body that does not do what it should
	local weak = 1 - min(st.armL, st.armR, st.legL, st.legR)
	local clumsy = 1 - min(st.coordL, st.coordR, st.balance)
	local motor = max(weak, clumsy)
	if motor >= CA.floor then
		return M.MOTOR_IMPAIRED, motor, 0, weak >= clumsy and "a weak limb" or "balance and coordination"
	end
	-- dazed, drowsy, confused
	local dull = Clamp((CA.dullFrom - eff) / CA.dullSpan, 0, 1)
	if now < st.stunUntil then dull = max(dull, CA.dazed) end
	if now < st.confusedUntil then dull = max(dull, CA.confused) end
	if dull >= CA.floor then return M.INJURED, dull, 0, "unconscious" end
	return M.NORMAL, 0, 0, "nothing to show"
end

-- The reason in full, for the log.
local function Why(st, word)
	if word == "terminal" then return "circulation stopped and the brainstem has failed" end
	if word == "arrest" then return string.format("no circulation (%s)", tostring(st.arrestCause or "?")) end
	if word == "posture" then return string.format("%s posturing %.2f", E.Posture.names[st.postureKind] or "?", st.posture) end
	if word == "unconscious" then return string.format("consciousness %.2f (%s)", st.effective or st.consciousness or 1, tostring(st.lossWhy or "?")) end
	if word == "recovering" then return string.format("coming round, consciousness %.2f", st.effective or st.consciousness or 1) end
	if word == "stagger" then return "losing its feet: " .. tostring(st.stagger and st.stagger.why or "?") end
	return word
end

function A.Describe(st)
	local a = st and st.anim
	if not a then return "-" end
	return string.format("%s (priority %d, intensity %.2f%s, for %.1f s%s)", A.names[a.mode], a.priority, a.blend,
		a.into and (", into " .. A.names[a.into]) or "", CurTime() - a.startTime, a.duration > 0 and string.format(" of %.0f", a.duration) or "")
end

-- How a character that a critical state finds on its feet goes down (sv_collapse.lua).
local function FallKind(st, mode, now)
	local sz = st.sz
	if mode == M.SEIZURE then return (sz and sz.phase == "tonic") and "rigid" or "limp" end
	if st.stagger then return st.stagger.kind end
	if mode == M.CARDIAC_ARREST or mode == M.TERMINAL_COLLAPSE then return "fold" end
	if st.lossWhy == "knockout" or now < st.fencingUntil then return "limp" end
	return "fold"
end
A.FallKind = FallKind

A.violations = A.violations or 0     -- steps in which a critical state was found on a body that was not down

-- Works out the animation state of a character and takes it down if a critical state finds it on
-- its feet. Called with every step of an injured brain and from the injury pipeline.
function A.Resolve(ply, org, st, now)
	local isPlayer = IsValid(ply) and ply:IsPlayer() and ply:Alive()
	local standing = isPlayer and not IsValid(ply.FakeRagdoll)
	local K = NT.Collapse
	-- Wakefulness that is falling takes the feet before it takes the rest: a character whose
	-- consciousness is on its way down through the band above Z-City's own drop (0.4) loses
	-- control of its body first, and folds [G].
	local eff = st.effective or st.consciousness or 1
	local was = st.effWas or eff
	st.effWas, st.effTrend = eff, eff - was
	if standing and K and not st.stagger and eff < C.Collapse.faintFrom and eff >= 0.4 and was - eff > 0.004 and now >= (st.faintNext or 0) then
		st.faintNext = now + C.Collapse.faintGap
		local rate = (was - eff) * 10
		K.Stagger(ply, st, { kind = "fold", fall = true, dur = Clamp((eff - 0.41) / max(rate, 0.05), 0.45, 1.3), peak = 0.9,
			why = string.format("consciousness is going (%.2f)", eff), quiet = true })
	end
	local mode, blend, dur, why = Pick(st, now, isPlayer and not standing)
	local a = st.anim
	if not a then
		a = { mode = M.NORMAL, priority = 0, blend = 0, startTime = now, duration = 0 }
		st.anim = a
	end
	-- A critical state on a character that stands: it goes down now, and for a moment the state is
	-- the collapse itself, whatever it is collapsing into (unless that outranks the collapse).
	if A.Critical(mode) then
		if standing and Z.has.fake and now >= (st.animFakeNext or 0) then
			st.animFakeNext = now + 1
			st.collapseUntil = now + CA.collapseTime
			NT.States.Push(st, ply, string.format("animation: %s finds the character on its feet: taken down", A.names[mode]))
			if not (K and K.TakeDown(ply, st, FallKind(st, mode, now))) then hg.Fake(ply) end
			standing = not IsValid(ply.FakeRagdoll)
		elseif not a.wasCritical then
			-- (Z-City or the seizure code dropped it in this same moment: the ragdoll is new)
			local rag = IsValid(ply) and ply.FakeRagdoll
			if IsValid(rag) and now - rag:GetCreationTime() < CA.collapseTime then
				st.collapseUntil = max(st.collapseUntil or 0, rag:GetCreationTime() + CA.collapseTime)
			end
		end
		if now < (st.collapseUntil or 0) and A.Priority(mode) < A.Priority(M.CRITICAL_COLLAPSE) then
			a.into = mode
			mode, dur = M.CRITICAL_COLLAPSE, st.collapseUntil - now
		end
		-- The rule this file exists for, counted: a critical state on a body that is not down.
		-- (A character in a vehicle cannot be dropped by Z-City and is the one known exception.)
		if standing and isPlayer and now >= (st.animFakeNext or 0) - 0.5 then
			A.violations = A.violations + 1
			if now >= (A.violationLog or 0) then
				A.violationLog = now + 2
				NT.Print("%.1f %s is in %s and is not down (%d such steps so far)", now, ply:Nick(), A.names[mode], A.violations)
				if NT.TestLog then NT.TestLog("  ANIMATION RULE BROKEN: %s is in %s and is not down", ply:Nick(), A.names[mode]) end
			end
		end
	end
	if mode ~= M.CRITICAL_COLLAPSE then a.into = nil end
	a.wasCritical = A.Critical(mode)
	-- (for Z-City's response to a death, sv_zcity.lua: this body lies limp without circulation)
	if (mode == M.CARDIAC_ARREST or mode == M.TERMINAL_COLLAPSE) and IsValid(ply) then ply.NT_arrestSeen = now end
	a.blend = blend
	a.why = why
	if mode ~= a.mode then
		local from = a.mode
		a.mode, a.priority, a.startTime, a.duration = mode, A.Priority(mode), now, dur or 0
		NT.States.Push(st, ply, string.format("animation: %s -> %s (priority %d, intensity %.2f): %s%s", A.names[from], A.names[mode], a.priority, blend,
			a.into and ("going down into " .. A.names[a.into] .. ": ") or "", Why(st, why)))
		hook.Run("NT_AnimState", ply, org, st, mode, from)
	else
		a.duration = (dur and dur > 0) and (now - a.startTime + dur) or 0
	end
	return a
end

-- Is this character in a trauma critical response?
function A.IsCritical(ply)
	local org = IsValid(ply) and ply.organism
	local st = istable(org) and NT.Get(org)
	return st ~= nil and st.anim ~= nil and A.Critical(st.anim.mode)
end

-- Z-City asks before it lets a ragdolled player steer the ragdoll, and before it lets one get up.
-- In a critical state the answer is no: ordinary movement does not replace it.
hook.Add("CanControlFake", "NT_Anim", function(ply)
	if NT.Enabled() and A.IsCritical(ply) then return false end
end)
hook.Add("Should Fake Up", "NT_Anim", function(ply)
	if NT.Enabled() and A.IsCritical(ply) then return false end
end)
