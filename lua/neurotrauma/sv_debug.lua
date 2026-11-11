-- Developer commands. All need neuro_dev 1 and a superadmin (or the listen-server host / console).

local NT = NeuroTrauma
NT.Debug = NT.Debug or {}
local D = NT.Debug
local C, Z, I = NT.Config, NT.ZC, NT.Injury

function D.Allowed(ply)
	if not C.sv.dev:GetBool() then return false end
	if not IsValid(ply) then return true end
	return ply:IsSuperAdmin() or ply:IsListenServerHost() or game.SinglePlayer()
end

local function Reply(ply, fmt, ...)
	local s = string.format(fmt, ...)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else print(s) end
end
D.Reply = Reply

-- self | bot | aim | part of a name | entity index
function D.Target(caller, token)
	token = token or "aim"
	if token == "self" then return caller end
	if token == "bot" then return player.GetBots()[1] end
	if tonumber(token) then
		local e = Entity(tonumber(token))
		if IsValid(e) then return e:IsPlayer() and e or Z.Owner(e) end
		return nil
	end
	if token == "aim" and IsValid(caller) then
		local e = caller:GetEyeTrace().Entity
		if IsValid(e) then
			if e:IsPlayer() then return e end
			local owner = Z.Owner(e)
			if owner then return owner end
		end
		return caller
	end
	for _, p in ipairs(player.GetAll()) do
		if string.find(string.lower(p:Nick()), string.lower(token), 1, true) then return p end
	end
	return nil
end

-- neuro_events [target]: the injury events remembered for a character
concommand.Add("neuro_events", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	local org = IsValid(target) and Z.Org(target)
	local h = org and I.History(org)
	if not h or #h == 0 then return Reply(ply, "[NeuroTrauma] no events") end
	for _, ev in ipairs(h) do Reply(ply, "[NeuroTrauma] %6.1f s ago  %s", CurTime() - ev.t, I.Describe(ev)) end
end)

------------------------------------------------------------------------------------------
-- The neurological record
------------------------------------------------------------------------------------------
local BR, E = NT.Brain, NT.E

-- The record of a character as lines of text, in the sections of the developer panel.
function D.StatusLines(org)
	local st = NT.Get(org)
	if not st then
		-- (no record: the circulation can still be read)
		local label = NT.Cardio and NT.Cardio.GetState(org) or "-"
		return { "no neurological record (uninjured)", "CARDIOLOGY", string.format("  %s | %s", label, NT.Cardio and NT.Cardio.GetHeartState(org) or "-") }
	end
	local now = CurTime()
	local an = st.an
	local ch = NT.Anatomy.Channels(st)
	local out = {}
	local function L(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
	L("TRAUMA")
	L("  %d events | tolerance %.2f | diffuse %.2f (keeps %.2f) bruising L %.2f R %.2f brainstem %.2f fracture %.2f | lesion %.2f of %.2f (%s, %s) | swelling %.2f | vulnerability +%.2f",
		st.events, st.tol, st.diffuse, st.diffuseFloor, st.focalL, st.focalR, st.stem, st.fracture, st.mass, st.massFinal,
		st.massSide == 0 and "none" or (st.massSide > 0 and "left" or "right"), tostring(st.massKind or "-"), st.swell, st.vulnExtra)
	L("  damaged: %s", NT.Anatomy.Describe(st, 8))
	L("  %s", NT.Vascular.Describe(st))
	L("NEUROLOGY")
	L("  %s (%s) | overlays %s | consciousness %.2f (effective %.2f, lost to %s) | eyes %d voice %d movement %d | thinking %.2f | trend %+.3f /s",
		tostring(st.label), string.upper(E.State.names[st.state]), E.OverlayText(st.overlays), st.consciousness, st.effective, tostring(st.lossWhy),
		st.respEyes or -1, st.respVerbal or -1, st.respMotor or -1, st.cognitive, st.trend or 0)
	L("  limbs: arm L %.2f R %.2f | hand L %.2f R %.2f | leg L %.2f R %.2f | face L %.2f R %.2f | trunk %.2f | coordination L %.2f R %.2f | balance %.2f | tone %.1f | gaze %s",
		st.armL, st.armR, st.handL, st.handR, st.legL, st.legR, st.faceL, st.faceR, st.trunk, st.coordL, st.coordR, st.balance, st.tone or 1,
		st.gaze == 0 and "free" or (st.gaze > 0 and "held left" or "held right"))
	L("  language (dominant %s, %s-handed): speech out %.2f understanding %.2f repeating %.2f reading %.2f writing %.2f articulation %.2f | memory %.2f attention %.2f executive %.2f drive %.2f",
		an.dom == "L" and "left" or "right", an.handed == "L" and "left" or "right",
		ch.language_production, ch.language_comprehension, ch.language_repetition, ch.reading, ch.writing, ch.articulation, ch.memory, ch.attention, ch.executive, ch.drive)
	L("  senses: sight left field up %.2f down %.2f, right field up %.2f down %.2f | hearing %.2f | feeling L %.2f R %.2f | neglect of the left %.2f, of the right %.2f | cortex working L %.2f R %.2f",
		ch.vision_upperL, ch.vision_lowerL, ch.vision_upperR, ch.vision_lowerR, ch.hearing, ch.sensationL, ch.sensationR, ch.neglectL, ch.neglectR, ch.cortexL, ch.cortexR)
	L("  brainstem: pressure %.2f stress %.2f respiratory control %.2f autonomic %.2f reflexes %.2f | posturing %s %.2f | pupils L %.2f R %.2f",
		st.pressure, st.stemStress, st.resp, st.autonomic, st.reflexAbn, E.Posture.names[st.postureKind], st.posture, st.pupilL, st.pupilR)
	local sz = st.sz
	L("  seizure: risk %.2f | %s%s | fatigue %.2f | running: knockout %.0f s, coming round %.0f s, daze %.0f s, apnoea %.0f s",
		st.seizureRisk, tostring(NT.Seizure.CategoryOf(st, now) or "none"),
		sz and string.format(" (%s phase, %.0f s left%s%s)", sz.phase, math.max(sz.tEnd - now, 0), sz.convSince and string.format(", convulsing for %.0f s", now - sz.convSince) or "", sz.stops and "" or ", will not stop by itself") or "",
		st.fatigue or 0, math.max(st.locUntil - now, 0), math.max(st.confusedUntil - now, 0), math.max(st.stunUntil - now, 0), math.max(st.apnoeaUntil - now, 0))
	local med = st.med and st.med.midazolam
	if med then L("  midazolam: %d doses, level %.2f | sedation %.2f | breathing -%.2f | seizure threshold +%.0f%%", #med.doses, med.level or 0, st.sedation or 0, st.respDrug or 0, (st.seizureGuard or 0) * 100) end
	L("CARDIOLOGY")
	if NT.Cardio then
		local label, t = NT.Cardio.GetState(org)
		L("  %s | heart: %s | pressure %.0f (%.0f%%) volume %.0f%% oxygen %.0f%% shock %.0f | perfusion %.2f output %.2f | stress on the heart %.2f, risk of a runaway rate %.2f%s%s%s",
			label, NT.Cardio.GetHeartState(org), t.pressure, t.bloodPressure * 100, t.circulatingVolume * 100, t.oxygenSaturation * 100, t.shock, t.perfusion, t.cardiacOutput,
			t.myocardialStress, t.arrhythmiaRisk, t.downTime and string.format(" | no circulation for %.0f s", t.downTime) or "",
			t.cpr and string.format(" | compressions: %d", st.cpr.n) or "", t.rosc and string.format(" | circulation back for %.0f s after %.0f s without", t.rosc, st.rosc.down) or "")
	end
	L("  Z-City: consciousness %.2f brain %.3f (floor %.2f) otrub %s heart stopped %s breathing %s%s",
		tonumber(org.consciousness) or -1, tonumber(org.brain) or -1, st.brainFloor or 0, tostring(org.otrub), tostring(org.heartstop), tostring(org.lungsfunction), st.cushing and " | heart slowed by pressure in the skull" or "")
	L("ANIMATION")
	local owner = org.owner
	local rag = IsValid(owner) and owner.FakeRagdoll
	local ctl = IsValid(rag) and NT.Motor.ctlOf[rag]
	L("  body: %s | ragdoll controller: %s | walking %d/15, pulled %s | hands L %s R %s",
		IsValid(rag) and "ragdolled" or "standing",
		ctl and string.format("driving, strength %.2f%s%s", ctl.env, ctl.sz and (", seizure " .. tostring(ctl.sz.phase)) or "", ctl.fencing and ", impact posture" or "") or "none",
		st.moveQ or 15, (st.veerQ or 0) == 0 and "nowhere" or ((st.veerQ > 0 and "left " or "right ") .. math.abs(st.veerQ)),
		st.handL < 0.6 and "limp" or "normal", st.handR < 0.6 and "limp" or "normal")
	L("NETWORK")
	L("  state messages %d (%d bytes), owner messages %d (%d bytes) since the map started | records %d | this record: version %s",
		NT.Net.messages, NT.Net.bytes, NT.Net.selfMessages, NT.Net.selfBytes, NT.Brain.count, tostring(st.netVersion or "-"))
	L("PERFORMANCE")
	L("  channels worked out %d times | vessels %s | record %s", an.version, an.vascActive and "active" or "asleep", st.quiet and "quiet (looked at once a second)" or "awake")
	L("TRANSITIONS")
	for _, l in ipairs(st.log) do out[#out + 1] = string.format("  %6.1f s ago  %s", now - l.t, l.text) end
	return out
end

-- neuro_status [target]
concommand.Add("neuro_status", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	local org = IsValid(target) and Z.Org(target)
	if not org then return Reply(ply, "[NeuroTrauma] no such character") end
	for _, l in ipairs(D.StatusLines(org)) do Reply(ply, "[NeuroTrauma] %s", l) end
end)

-- A synthetic head impact: rotation (the game's rad/s), contact (m/s), side (-1 right .. 1 left).
function D.Hit(target, rot, contact, lat, seed)
	local org = Z.Org(target)
	if not org then return false end
	local ev = {
		id = 0, t = CurTime(), seed = seed or math.random(1, 2147483646), ply = target, org = org, body = Z.Body(target),
		mech = E.Mech.BLUNT, measured = false, region = E.Region.NONE, lat = lat or 0,
		rot = rot, contact = contact, rotEff = rot, contactEff = contact, landing = 0, awake = 1, shield = 0, tol = 1,
	}
	ev.synthetic = true
	NT.ProcessTraumaEvent(target, ev)
	return true
end

-- neuro_hit <target> <rotation> <contact> [side]
concommand.Add("neuro_hit", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	if not IsValid(target) then return Reply(ply, "[NeuroTrauma] no such character") end
	D.Hit(target, tonumber(args[2]) or 12, tonumber(args[3]) or 0, tonumber(args[4]) or 0)
end)

-- neuro_set <target> <variable> <value>: an injury variable set by hand (diffuse, focalL, focalR,
-- stem, fracture, mass, massRate, massFinal, massSide, swell, knockout, daze)
function D.Set(target, key, value)
	local org = Z.Org(target)
	if not org then return false end
	local st = BR.Ensure(org)
	local now = CurTime()
	if key == "knockout" then
		st.locUntil = now + value
		st.confusedUntil = st.locUntil + math.Clamp(value * C.Brain.confusionPerLoc, C.Brain.confusionMin, C.Brain.confusionMax)
	elseif key == "daze" then
		st.stunUntil, st.stunDur = now + value, math.max(value, 0.5)
	elseif st[key] ~= nil and isnumber(st[key]) then
		st[key] = value
		if key == "diffuse" then st.diffuseFloor = value * C.Brain.diffuseKeep end
		-- (a hemisphere-level number says nothing of where: it is put on the outer surface around the
		-- central sulcus; the brainstem number stands for the whole brainstem)
		if key == "focalL" or key == "focalR" then
			local side = key == "focalL" and "L" or "R"
			for id, r in ipairs(NT.Atlas.regions) do if r.side == side and (r.kind == "C") then st.an.d[id] = nil end end
			if value > 0 then NT.Anatomy.Convexity(st, side, value) end
			st.an.dirty = true
		end
		st.quiet = false
		if key == "massSide" then st.pupilSide, st.weakSide = value, -value end
	else
		return false
	end
	NT.States.Push(st, target, string.format("set by hand: %s = %s", key, tostring(value)))
	return true
end

concommand.Add("neuro_set", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	if not IsValid(target) or not args[2] then return Reply(ply, "[NeuroTrauma] neuro_set <target> <variable> <value>") end
	if not D.Set(target, args[2], tonumber(args[3]) or 0) then Reply(ply, "[NeuroTrauma] unknown variable") end
end)

-- neuro_clear [target]: forget the injury (Z-City's own values are left as they are)
concommand.Add("neuro_clear", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	local org = IsValid(target) and Z.Org(target)
	local st = org and NT.Get(org)
	if st then BR.Drop(org, target, st, "cleared by hand") end
end)

-- neuro_seizure [target] [early|convulsion|full]: start a seizure
concommand.Add("neuro_seizure", function(ply, _, args)
	if not D.Allowed(ply) then return end
	local target = D.Target(ply, args[1])
	local org = IsValid(target) and Z.Org(target)
	if not org then return Reply(ply, "[NeuroTrauma] no such character") end
	local st = BR.Ensure(org)
	local kind = args[2] or "early"
	if kind == "full" then
		NT.Seizure.Force(target, st, CurTime(), { { "focal", 8 }, { "tonic", 8 }, { "clonic", 25 }, { "postictal", 40 } }, 1, true)
	else
		NT.Seizure.Start(target, st, CurTime(), kind, nil, 12)
	end
end)

------------------------------------------------------------------------------------------
-- The developer panel (cl_debug.lua): a superadmin who switches neuro_debug on is sent, twice a
-- second, the record of the character under the crosshair (or of his own): the last injury events
-- with their kinematics, the injury and function variables, the state, the last transitions with
-- their reasons. Nobody else is sent anything.
------------------------------------------------------------------------------------------
util.AddNetworkString("nt_debug")
local watchers = {}

net.Receive("nt_debug", function(_, ply)
	local on = net.ReadBool()
	if on and D.Allowed(ply) then watchers[ply] = true else watchers[ply] = nil end
end)

timer.Create("NT_DebugStream", 0.5, 0, function()
	for ply in pairs(watchers) do
		if not IsValid(ply) or not D.Allowed(ply) then
			watchers[ply] = nil
		else
			local target = D.Target(ply, "aim")
			local org = IsValid(target) and Z.Org(target)
			local lines = {}
			if org then
				lines[1] = string.format("%s  (records in the game: %d, events so far: %d)", target:Nick(), BR.count, I.count)
				for _, l in ipairs(D.StatusLines(org)) do lines[#lines + 1] = l end
				local h = I.History(org)
				if h then
					for i = math.max(#h - 2, 1), #h do
						lines[#lines + 1] = string.format("  %5.1f s ago  %s", CurTime() - h[i].t, I.Describe(h[i]))
					end
				end
			else
				lines[1] = "no character"
			end
			net.Start("nt_debug")
			net.WriteUInt(math.min(#lines, 63), 6)
			for i = 1, math.min(#lines, 63) do net.WriteString(string.sub(lines[i], 1, 480)) end
			net.Send(ply)
		end
	end
end)
