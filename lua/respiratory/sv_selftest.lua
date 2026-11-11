-- Test scenes of the respiratory module (developer tool). They run inside the blood module's
-- harness (lua/advancedblood/server/sv_selftest.lua), which exists only when garrysmod/data/
-- abl_selftest.txt does, and only when asked for by name. The client half is cl_selftest.lua.
--
--   resp_place      the lungs, the airways and the diaphragm in the chests of Z-City's character
--                   models, with the skeleton: from four sides, breathed out and in; left and right
--                   and the levels of things, in numbers
--   resp_breath     one character breathing: the clock on both sides, the shape of a breath read
--                   off the model's own corners at the screen's pace, Z-City's chest on the same clock
--   resp_state      the state: what Z-City keeps is read, and the breathing follows it (exertion,
--                   a held breath, a stop, a punctured lung, a shut airway, what another system asks)
--   resp_life       laid down, up again, knocked out through the brain module, dead, alive again,
--                   gone: the clock, the lungs and what is left behind through all of it
--   resp_brain      the brain module takes away control of the breathing: the state follows what that
--                   module says and writes into Z-City, and the label says so
--   resp_perf       what it costs, on the server and on the screen, with several characters

local RS = HemoRespiratory
if not (istable(ABL) and istable(ABL.SelfTest)) then return end
if RS.Quiet then return end
local S = ABL.SelfTest
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = S.Log, S.Wait, S.Client, S.NewBot, S.Place, S.View, S.Shot, S.FindSpot
local C, CK, Z, K = RS.Config, RS.Clock, RS.ZC, RS.Clocks
local SK = HemoSkeleton

RunConsoleCommand("resp_dev", "1")
RunConsoleCommand("skel_dev", "1")

local fails, checks = 0, 0
local function L(fmt, ...) Log("  resp: " .. string.format(fmt, ...)) end
local function Check(ok, fmt, ...)
	checks = checks + 1
	if not ok then fails = fails + 1 end
	Log("  resp: " .. (ok and "ok    " or "FAIL  ") .. string.format(fmt, ...))
	return ok
end
local function Done(name) L("%s: %d check(s), %d failed", name, checks, fails) checks, fails = 0, 0 end
local function Cvar(name, value) Client("cvar", { name = name, value = tostring(value) }) end
local function ViewOff()
	Cvar("resp_view", 0) Cvar("resp_view_hold", -1) Cvar("resp_view_lungs", 1) Cvar("resp_view_airways", 1) Cvar("resp_view_diaphragm", 1) Cvar("resp_view_info", 1) Cvar("resp_view_who", "aim")
	Cvar("skel_view", 0) Cvar("skel_view_labels", 1) Cvar("skel_view_who", "aim")
end

local function Model(bot, model)
	bot:SetModel(model)
	Wait(0.3)
	if bot:GetModel() ~= model then L("WARNING: %s is %s, not %s", bot:Nick(), tostring(bot:GetModel()), model) end
end

local function StateLine(who)
	local p = RS.Read(who)
	if not p then return "no state" end
	return string.format("%s (%s) %.1f/min depth %.2f -> %.1f/%.2f want %.2f | airway %.2f%s | L %.2f/%.2f/%.2f R %.2f/%.2f/%.2f cap %.2f | vent %.2f moving %.2f | o2 %.2f of %.2f | ctl %s pat %s | %s v%d",
		p.label, p.mode, p.rate, p.depth, p.target.rate, p.target.depth, p.target.want, p.airway.patency, p.airway.blocked and (" BLOCKED:" .. tostring(p.airway.why)) or "",
		p.lungs.l.damage, p.lungs.l.breach, p.lungs.l.collapse, p.lungs.r.damage, p.lungs.r.breach, p.lungs.r.collapse, p.lungs.capacity, p.ventilation, p.moving, p.oxygen.now, p.oxygen.ceiling,
		tostring(p.drive.control), tostring(p.drive.patternName), p.follows, p.ver)
end

-- the middle of a body's chest, for the camera
local function Chest(body)
	local b = body:LookupBone("ValveBiped.Bip01_Spine2")
	local m = b and body:GetBoneMatrix(b)
	return m and m:GetTranslation() or body:WorldSpaceCenter()
end

------------------------------------------------------------------------------------------
S.Add("resp_place", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	ViewOff()
	Cvar("skel_view_labels", 0)
	Cvar("skel_view_who", "all")
	Cvar("resp_view_who", "all")
	Cvar("resp_view_info", 0)
	local models = { "models/zcity/m/male_06.mdl", "models/zcity/f/female_06.mdl", "models/zcity/m/male_01.mdl", "models/zcity/f/female_01.mdl", "models/zcity/m/male_09.mdl", "models/zcity/f/female_04.mdl",
		"models/zcity/m/male_03.mdl", "models/zcity/f/female_02.mdl" }
	Client("resp", { step = "check" })
	for i, model in ipairs(models) do
		Model(bot, model)
		local name = string.match(model, "([^/]+)%.mdl$")
		Wait(0.6)
		local c = Chest(bot)
		-- breathed out, with the skeleton, from the front (the bot faces +x)
		Cvar("resp_view_hold", 0)
		Cvar("skel_view", 1)
		Cvar("resp_view", 1)
		View(c + Vector(34, 0, 2), c)
		Wait(i == 1 and 2.5 or 0.9)
		Client("resp", { step = "place", ent = bot:EntIndex(), tag = name })
		Wait(0.3)
		Shot(string.format("rpl_%d_%s_front_out", i, name))
		if i <= 4 then
			Cvar("resp_view_hold", 1)
			Wait(0.3)
			Shot(string.format("rpl_%d_%s_front_deepest", i, name))
			Cvar("resp_view_hold", 0)
			View(c + Vector(0, 34, 2), c)
			Wait(0.5)
			Shot(string.format("rpl_%d_%s_left_side", i, name))
			View(c + Vector(-34, 0, 2), c)
			Wait(0.5)
			Shot(string.format("rpl_%d_%s_back", i, name))
			View(c + Vector(22, -14, 24), c)
			Wait(0.5)
			Shot(string.format("rpl_%d_%s_from_above", i, name))
			-- the lungs alone, and as glass over the airways
			Cvar("skel_view", 0)
			View(c + Vector(30, 12, 4), c)
			Wait(0.5)
			Shot(string.format("rpl_%d_%s_alone", i, name))
			Cvar("resp_view_lungs", 0.4)
			Wait(0.3)
			Shot(string.format("rpl_%d_%s_glass", i, name))
			Cvar("resp_view_lungs", 1)
			-- as part of the world: nothing may show through the skin of a whole body
			Cvar("resp_view", 2)
			View(c + Vector(40, 10, 4), c)
			Wait(0.4)
			Shot(string.format("rpl_%d_%s_inside_the_body", i, name))
		end
	end
	ViewOff()
	Wait(0.5)
	Done("resp_place")
end)

------------------------------------------------------------------------------------------
S.Add("resp_breath", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	ViewOff()
	Wait(1.5)
	local org = bot.organism
	local r = K.Of(org)
	Check(r ~= nil, "the bot has a breathing record after its first steps: %s", StateLine(bot))
	if not r then return end
	Check(r.clock.mode == CK.BREATHING and math.abs(r.clock.rate - C.sv.rate:GetFloat()) < 3, "it breathes, near the rate at rest (%.1f a minute, depth %.2f)", r.clock.rate, r.clock.depth)
	-- the clock is stepped where Z-City steps the organism
	local s0, t0 = K.stats.steps, CurTime()
	Wait(3)
	local per = (K.stats.steps - s0) / math.max(1, #player.GetAll()) / (CurTime() - t0)
	Check(per > 6 and per < 14, "the record is stepped %.1f times a second for each character (Z-City's organism step)", per)
	local c = Chest(bot)
	Cvar("resp_view_who", "all")
	Cvar("resp_view", 1)
	View(c + Vector(46, 14, 4), c)
	Wait(2.5)
	Client("resp", { step = "clock", ent = bot:EntIndex(), phase = CK.PhaseAt(r.clock, CurTime()), rate = r.clock.rate, depth = r.clock.depth, mode = r.clock.mode, t = CurTime() })
	Wait(0.5)
	-- one breath, in pictures
	local rate = r.clock.rate
	local period = 60 / rate
	local a = CK.Shares(rate)
	-- wait for the breath out to end
	local guard = CurTime() + period * 2
	while CK.PhaseAt(r.clock, CurTime()) > 0.04 and CurTime() < guard do Wait(0.02) end
	local names = { "0_out", "1_in_half", "2_in_full", "3_out_half", "4_out_late", "5_pause" }
	local at = { 0, a * 0.5, a, a + (1 - a) * 0.3, a + (1 - a) * 0.6, 0.97 }
	local start = CurTime() - CK.PhaseAt(r.clock, CurTime()) * period
	for i, ph in ipairs(at) do
		local till = start + ph * period
		if till > CurTime() then Wait(till - CurTime()) end
		Client("shot", { name = "rbr_" .. names[i] })
		L("picture %s at phase %.2f (the clock says %.2f)", names[i], ph, CK.PhaseAt(r.clock, CurTime()))
	end
	Wait(0.6)
	-- the breath read off the screen: the client follows the lungs' lowest corners and Z-City's chest
	-- bone through three breaths, frame by frame. (The game does not let Lua change how many pictures
	-- a second it draws: for another pace the whole run is started with +fps_max, see docs/LUNGS_PHASE2.md.)
	Client("resp", { step = "trace", ent = bot:EntIndex(), secs = period * 3, tag = "three breaths at rest" })
	Wait(period * 3 + 1)
	-- with the skeleton, and walking: the lungs stay in the chest of a body that moves
	Cvar("skel_view_who", "all")
	Cvar("skel_view_labels", 0)
	Cvar("skel_view", 1)
	bot:Freeze(false)
	local dir = Vector(0, 1, 0)
	S.Drive(bot, function(b, cmd)
		cmd:SetForwardMove(b:GetWalkSpeed())
		cmd:SetViewAngles(dir:Angle())
		b:SetEyeAngles(dir:Angle())
	end)
	Client("resp", { step = "follow", ent = bot:EntIndex(), on = true })
	Wait(0.8)
	for i = 1, 3 do
		Client("resp", { step = "inside", ent = bot:EntIndex(), tag = "walking " .. i })
		Wait(0.45)
		Client("shot", { name = "rbr_walk_" .. i })
		Wait(0.45)
	end
	S.Drive(bot, nil)
	bot:Freeze(true)
	Client("resp", { step = "follow", on = false })
	Cvar("skel_view", 0)
	Wait(0.5)
	-- Z-City's chest: on the clock, and left alone when the switch is off
	c = Chest(bot)
	View(c + Vector(46, 14, 4), c)
	Client("resp", { step = "chest", ent = bot:EntIndex(), secs = 4, tag = "resp_zcity_chest 1" })
	Wait(4.6)
	RunConsoleCommand("resp_zcity_chest", "0")
	Wait(0.6)
	Client("resp", { step = "chest", ent = bot:EntIndex(), secs = 4, tag = "resp_zcity_chest 0" })
	Wait(4.6)
	RunConsoleCommand("resp_zcity_chest", "1")
	ViewOff()
	Wait(0.5)
	Done("resp_breath")
end)

------------------------------------------------------------------------------------------
-- (tests write Z-City's own fields, as Z-City's damage does; the module itself never does)
S.Add("resp_state", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	ViewOff()
	Wait(1.5)
	local org = bot.organism
	org.godmode = nil
	local c = Chest(bot)
	Cvar("resp_view_who", "all")
	Cvar("resp_view", 1)
	View(c + Vector(46, 14, 4), c)
	Wait(2)
	local r = K.Of(org)
	if not Check(r ~= nil, "a record: %s", StateLine(bot)) then return end
	local st = RS.Read(bot)
	Check(st.label == "NORMAL" and st.breathing and st.airway.patency == 1 and st.lungs.capacity == 1 and st.ventilation == 1, "a sound character at rest: NORMAL, the airway open, both lungs whole, the blood loaded fully")
	-- Z-City's own number for how the lungs load the blood is the number published
	local zc = Z.VentilationByZCity(org)
	Check(zc ~= nil and math.abs(zc - st.exchange) < 1e-6, "what the lungs could load is Z-City's own number (%s, published %.4f)", tostring(zc), st.exchange)
	local ox = RS.Oxygen(bot)
	Check(ox ~= nil and ox.via == "zcity_store" and math.abs(ox.availability - org.o2[1] / org.o2.range) < 1e-6, "the oxygen offered to a consumer is Z-City's store (%.3f), by way of %s", ox and ox.availability or -1, tostring(ox and ox.via))
	Client("resp", { step = "rec", ent = bot:EntIndex(), tag = "sound" })

	-- exertion: Z-City's heart rate
	-- (a field is held by writing it just before the module's own step reads the organism: Z-City
	-- works some of these out anew at every step of its own)
	local keep = {}
	local function Hold(field, value) keep[field] = value end
	local own = hook.GetTable()["Org Think"]["RS_Clock"]
	hook.Add("Org Think", "RS_Clock", function(owner, o, dt)
		if o == org then for f, v in pairs(keep) do o[f] = v end end
		return own(owner, o, dt)
	end)
	Hold("heartbeat", 165)
	-- (and what the screen shows while rate and depth rise, clock after clock)
	Client("resp", { step = "trace", ent = bot:EntIndex(), secs = 6.5, tag = "while rate and depth rise", loose = true })
	Wait(7)
	st = RS.Read(bot)
	Check(st.rate > 26 and st.depth > 1.7 and st.label == "FAST", "the heart at 165 for seven seconds: %s", StateLine(bot))
	Client("resp", { step = "rec", ent = bot:EntIndex(), tag = "exerted" })
	Shot("rst_1_exerted")
	keep.heartbeat = nil
	org.heartbeat = 70
	Wait(12)
	st = RS.Read(bot)
	Check(st.rate < 20 and st.label == "NORMAL", "twelve seconds after: %s", StateLine(bot))

	-- a held breath
	org.holdingbreath = true
	Hold("holdingbreath", true)
	Wait(1)
	st = RS.Read(bot)
	Check(st.mode == "held" and st.label == "HELD" and st.ventilation == 0 and st.moving == 0, "a held breath: %s", StateLine(bot))
	Client("resp", { step = "fill", ent = bot:EntIndex(), tag = "held", want = C.Breath.heldAt })
	Wait(0.8)
	Shot("rst_2_held")
	keep.holdingbreath = nil
	org.holdingbreath = false
	Wait(1)
	st = RS.Read(bot)
	Check(st.mode == "breathing", "let go: %s", StateLine(bot))

	-- no breath: the lungs do not work (what the brain module's stops and Z-City's own write)
	Hold("lungsfunction", false)
	org.lungsfunction = false
	Wait(1.2)
	st = RS.Read(bot)
	Check(st.mode == "stopped" and st.label == "NOT_BREATHING" and st.moving == 0, "the lungs do not work: %s", StateLine(bot))
	Client("resp", { step = "fill", ent = bot:EntIndex(), tag = "stopped", want = 0 })
	Wait(0.8)
	Shot("rst_3_stopped")
	keep.lungsfunction = nil
	org.lungsfunction = true
	Wait(0.5)
	st = RS.Read(bot)
	local ph = CK.PhaseAt(r.clock, CurTime())
	Check(st.mode == "breathing" and ph < 0.3, "they work again: a breath in begins (phase %.2f): %s", ph, StateLine(bot))
	Wait(2)

	-- a punctured left lung: air in the pleural space, the lung lets go of the wall
	org.lungsL[1], org.lungsL[2] = 0.6, 1
	org.pneumothorax = 0.42
	Hold("pneumothorax", 0.42)
	Wait(2.5)
	st = RS.Read(bot)
	Check(st.lungs.l.collapse > 0.8 and st.lungs.r.collapse == 0 and st.lungs.capacity < 0.75 and st.label == "LABOURED" and st.oxygen.ceiling < 0.9,
		"the left lung punctured, air in the pleural space 0.42: %s", StateLine(bot))
	-- (the oxygen store falls to what it can now hold, which asks for more air: deeper for that, and
	-- shallower for the lung that is gone; what is left is less deep than whole lungs would breathe for the same want)
	local whole = C.sv.depth:GetFloat() + (C.Breath.depthDemand - C.sv.depth:GetFloat()) * st.target.want
	Check(st.target.rate > C.sv.rate:GetFloat() + 3 and st.target.depth < whole - 0.1, "breathed with faster, and less deep than whole lungs would be for the same want of air (going to %.1f a minute and depth %.2f; whole lungs: depth %.2f)",
		st.target.rate, st.target.depth, whole)
	Client("resp", { step = "rec", ent = bot:EntIndex(), tag = "left lung punctured" })
	Client("resp", { step = "collapse", ent = bot:EntIndex(), tag = "left lung punctured" })
	Wait(0.6)
	View(c + Vector(40, 0, 3), c)
	Wait(0.6)
	Shot("rst_4_left_lung_let_go")
	keep.pneumothorax = nil
	org.lungsL[1], org.lungsL[2], org.pneumothorax = 0, 0, 0
	Wait(1.5)

	-- the airway shut: no air enters although the body tries (Z-City: nothing regained)
	Hold("vomitInThroat", true)
	org.vomitInThroat = true
	Wait(1.5)
	st = RS.Read(bot)
	Check(st.airway.blocked and st.airway.patency == 0 and st.label == "OBSTRUCTED" and st.ventilation == 0 and st.mode == "breathing", "the airway shut: %s", StateLine(bot))
	Client("resp", { step = "rec", ent = bot:EntIndex(), tag = "airway shut" })
	Wait(0.5)
	Shot("rst_5_airway_shut")
	keep.vomitInThroat = nil
	org.vomitInThroat = nil
	Wait(1.5)
	st = RS.Read(bot)
	Check(not st.airway.blocked and st.airway.patency == 1, "open again: %s", StateLine(bot))
	hook.Add("Org Think", "RS_Clock", own)
	org.o2[1] = org.o2.range
	Wait(6)

	-- what another system asks for (the interface for injuries to come)
	local regen0, lungR0, range0, trachea0 = org.o2.regen, org.lungsR[1], org.o2.range, org.trachea
	local ok, why = RS.Modify(bot, "test", { rate = 1.8, depth = 0.5, right = 0.3, ttl = 5 })
	Wait(4)
	st = RS.Read(bot)
	Check(ok and st.lungs.r.share < 0.35 and st.rate > C.sv.rate:GetFloat() * 1.3 and #st.mods == 1, "asked for by another system (rate x1.8, depth x0.5, the right lung at 0.3) %s: %s", tostring(why or ""), StateLine(bot))
	Check(regen0 == org.o2.regen and lungR0 == org.lungsR[1] and range0 == org.o2.range and trachea0 == org.trachea and st.exchange == 1,
		"and nothing of Z-City's was written for it (its right lung %s, its windpipe %s, its store's rate %s of %s; what the lungs load is still Z-City's %.2f)", tostring(org.lungsR[1]), tostring(org.trachea), tostring(org.o2.regen), tostring(org.o2.range), st.exchange)
	Wait(2)
	st = RS.Read(bot)
	Check(#st.mods == 0 and st.lungs.r.share == 1, "it holds for the five seconds asked and no longer: %s", StateLine(bot))
	Check(select(1, RS.Modify(bot, "", {})) == false and select(1, RS.Modify(Entity(0), "x", {})) == false, "an asking without a source, or for nobody, is refused")
	-- ways by which a quantity reaches a consumer
	local c1, w1 = RS.ClaimPath("brain", "oxygen", "respiratory_push", "test")
	Check(c1 == false, "a second way for oxygen to reach the brain is refused: %s", tostring(w1))
	local c2 = RS.ClaimPath("blood", "oxygen", "respiratory", "test")
	local c3, w3 = RS.ClaimPath("blood", "oxygen", "another", "other")
	Check(c2 == true and c3 == false and RS.ReleasePath("blood", "oxygen", "test") == true, "a way that is free is entered once, and not twice (%s)", tostring(w3))
	-- labels came as events
	ViewOff()
	Wait(0.5)
	Done("resp_state")
end)

------------------------------------------------------------------------------------------
S.Add("resp_life", function()
	local p = FindSpot({ open = 170, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	ViewOff()
	Cvar("resp_view_who", "all")
	Cvar("skel_view_who", "all")
	Cvar("skel_view_labels", 0)
	Cvar("resp_view", 1)
	local events = {}
	hook.Add("RS_StateChanged", "RS_TestLife", function(owner, label, was) if owner == bot then events[#events + 1] = tostring(was) .. ">" .. label end end)
	local c = Chest(bot)
	View(c + Vector(60, 20, 8), c)
	Wait(3)
	local org = bot.organism
	local r = K.Of(org)
	if not Check(r ~= nil, "standing: %s", StateLine(bot)) then return end
	Client("resp", { step = "life", ent = bot:EntIndex(), tag = "standing" })
	-- laid down as Z-City's ragdoll: the same organism, the same clock, another entity
	local ver = r.ver
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.8)
	local rag = ABL.DevRagdollOf(bot)
	if not Check(IsValid(rag), "laid down: the body is %s", tostring(rag)) then return end
	ABL.DevPose(rag, "back", false)
	Wait(2.2)
	Check(K.Of(org) == r and RS.Read(rag) == RS.Read(bot), "the ragdoll's state is the player's: %s", StateLine(rag))
	local rc = rag:WorldSpaceCenter()
	View(rc + Vector(30, 20, 52), rc)
	Wait(0.8)
	Client("resp", { step = "life", ent = rag:EntIndex(), tag = "lying" })
	Client("resp", { step = "inside", ent = rag:EntIndex(), tag = "lying" })
	Cvar("skel_view", 1)
	Wait(0.6)
	Shot("rlf_1_lying_with_skeleton")
	Cvar("skel_view", 0)
	Wait(0.3)
	Shot("rlf_2_lying")
	-- knocked out through the brain module: it moves the chest itself, the clock runs with it
	if istable(NeuroTrauma) and isfunction(NeuroTrauma.SetUnconscious) then
		NeuroTrauma.SetUnconscious(bot, 9)
		local seen, hz
		for _ = 1, 14 do
			Wait(0.5)
			hz = RS.Brain.RagdollBreath(bot)
			if hz and r.follows == "brain" then seen = true break end
		end
		Check(seen == true, "unconscious through the brain module: the clock runs with the breath that module gives the body (%s a second): %s", tostring(hz), StateLine(bot))
		if seen then
			local bh, bp = RS.Brain.RagdollBreath(bot)
			local mine = CK.PhaseAt(r.clock, CurTime())
			local d = math.abs((bp - mine + 0.5) % 1 - 0.5)
			Check(r.clock.sym and math.abs(r.clock.rate - bh * 60) < 0.01 and d < 0.03, "the same breath: %.2f a minute, the clock's phase %.3f against the brain module's %.3f", r.clock.rate, mine, bp)
			Wait(0.6)
			Client("resp", { step = "life", ent = rag:EntIndex(), tag = "unconscious" })
			Shot("rlf_3_unconscious")
		end
		-- comes round
		local till = CurTime() + 16
		while r.follows == "brain" and CurTime() < till do Wait(0.5) end
		Check(r.follows == "own" and not r.clock.sym, "come round: the clock is its own again: %s", StateLine(bot))
	else
		L("the brain module is not loaded: that part is left out")
	end
	-- up again
	if IsValid(bot.FakeRagdoll) then hg.FakeUp(bot, true, true) end
	Wait(2)
	c = Chest(bot)
	View(c + Vector(60, 20, 8), c)
	Wait(0.8)
	Check(K.Of(org) == r and r.clock.mode == CK.BREATHING, "up again: the same record, breathing: %s", StateLine(bot))
	Client("resp", { step = "life", ent = bot:EntIndex(), tag = "up again" })
	Shot("rlf_4_up_again")
	-- dead
	Wait(1)
	org.godmode = nil
	bot:Kill()
	local corpse
	for _ = 1, 20 do
		Wait(0.3)
		corpse = bot:GetNWEntity("RagdollDeath")
		if IsValid(corpse) then break end
		if bot:Alive() then bot:Kill() end
	end
	Wait(1.5)
	local st = RS.Read(bot)
	Check(not bot:Alive() and st ~= nil and st.mode == "stopped", "dead: the player's breathing has stopped: %s", StateLine(bot))
	Check(K.Of(org) ~= r, "the record of the life that ended is gone (Z-City emptied the organism)")
	if Check(IsValid(corpse), "the corpse is %s", tostring(corpse)) then
		local cs = RS.Read(corpse)
		Check(cs ~= nil and cs.mode == "stopped" and cs.label == "NOT_BREATHING", "the corpse has lungs and no breath: %s", StateLine(corpse))
		local cc = corpse:WorldSpaceCenter()
		View(cc + Vector(30, 20, 52), cc)
		Wait(1.2)
		Client("resp", { step = "life", ent = corpse:EntIndex(), tag = "corpse" })
		Wait(0.8)
		Shot("rlf_5_corpse")
	end
	-- alive again
	bot:Spawn()
	Wait(0.5)
	Place(bot, p + Vector(0, 70, 0), 0)
	Wait(2)
	local r2 = K.Of(bot.organism)
	Check(r2 ~= nil and r2 ~= r and r2.clock.mode == CK.BREATHING and next(r2.mods) == nil, "alive again: a new record, breathing: %s", StateLine(bot))
	c = Chest(bot)
	View(c + Vector(70, 30, 10), c)
	Wait(1)
	Client("resp", { step = "life", ent = bot:EntIndex(), tag = "alive again" })
	if IsValid(corpse) then Client("resp", { step = "life", ent = corpse:EntIndex(), tag = "the corpse beside the new life" }) end
	Wait(0.6)
	Shot("rlf_6_alive_again")
	L("labels in order: %s", table.concat(events, "  "))
	hook.Remove("RS_StateChanged", "RS_TestLife")
	-- the view switched off: nothing is kept
	ViewOff()
	Wait(1)
	Client("resp", { step = "left", tag = "view off" })
	-- gone
	local n0 = 0
	for _ in pairs(K.recs) do n0 = n0 + 1 end
	local idx = bot:EntIndex()
	bot:Kick("test")
	Wait(1.5)
	collectgarbage()
	collectgarbage()
	local n1 = 0
	for _ in pairs(K.recs) do n1 = n1 + 1 end
	Check(n1 < n0, "the character gone: %d record(s) before, %d after", n0, n1)
	Client("resp", { step = "gone", idx = idx })
	Wait(6)
	Client("resp", { step = "gone", idx = idx })
	Wait(0.5)
	Done("resp_life")
end)

------------------------------------------------------------------------------------------
-- The brain module damages the control of breathing; the respiratory state follows what that module
-- says and what it writes into Z-City (its pauses), and writes nothing into it.
S.Add("resp_brain", function()
	if not (istable(NeuroTrauma) and isfunction(NeuroTrauma.AddNeurologicalStress) and isfunction(NeuroTrauma.Reset)) then L("the brain module is not loaded: nothing to test") return end
	local p = FindSpot({ open = 170, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	Model(bot, "models/zcity/m/male_06.mdl")
	ViewOff()
	Cvar("resp_view_who", "all")
	Cvar("resp_view", 1)
	local c = Chest(bot)
	View(c + Vector(60, 20, 8), c)
	Wait(3)
	local org = bot.organism
	org.godmode = nil
	local st = RS.Read(bot)
	if not Check(st ~= nil and st.drive.brain == true and st.drive.control == nil and st.label == "NORMAL", "a sound character: the brain module is asked and has no record of it (all control): %s", StateLine(bot)) then return end
	local labels = {}
	hook.Add("RS_StateChanged", "RS_TestBrain", function(owner, label, was) if owner == bot then labels[#labels + 1] = string.format("%.1f %s", CurTime(), label) end end)
	local ok = NeuroTrauma.AddNeurologicalStress(bot, 0.7, "stem")
	L("the brainstem stressed by 0.7 through the brain module's own call: %s", tostring(ok))
	local seen, stops, n, apart, lowest, kinds, followed = {}, 0, 0, 0, 1, {}, 0
	local shot = false
	for i = 1, 56 do
		Wait(0.5)
		st = RS.Read(bot)
		if st then
			n = n + 1
			seen[st.label] = (seen[st.label] or 0) + 1
			kinds[st.drive.kind or "?"] = true
			if st.mode == "stopped" then stops = stops + 1 end
			if st.follows == "brain" then followed = followed + 1 end
			if st.drive.control and st.drive.control < lowest then lowest = st.drive.control end
			-- no breath exactly while Z-City's lungs do not work (where the brain module writes its pauses) or the heart stands
			if (st.mode == "stopped") ~= (org.lungsfunction == false or org.heartstop == true or not bot:Alive()) then apart = apart + 1 end
		end
		if i == 6 then
			local body = Z.Body(bot)
			local bc = body:WorldSpaceCenter()
			View(bc + Vector(34, 22, 50), bc)
		end
		if not shot and i > 8 and st and st.mode == "breathing" and st.label ~= "NORMAL" then
			shot = true
			L("pictured: %s", StateLine(bot))
			Client("resp", { step = "life", ent = Z.Body(bot):EntIndex(), tag = "breathing no longer regular" })
			Shot("rbn_1_irregular")
		end
	end
	local ls = {}
	for l, k in pairs(seen) do ls[#ls + 1] = l .. " " .. k end
	table.sort(ls)
	L("in %d looks over 28 s: %s; no breath in %d of them; the clock ran with the brain module's own movement of the chest in %d; alive %s", n, table.concat(ls, ", "), stops, followed, tostring(bot:Alive()))
	L("labels as they came: %s", table.concat(labels, "  "))
	Check(lowest < 0.8, "the brain module's respiratory control was read: down to %.2f", lowest)
	Check((seen.IRREGULAR or 0) + (seen.AGONAL or 0) > 0 and (kinds.irregular or kinds.gasping) == true, "the breathing was called what that module says of its pattern (IRREGULAR in %d looks, AGONAL in %d)", seen.IRREGULAR or 0, seen.AGONAL or 0)
	Check(stops > 0, "its pauses came as stops (%d looks without a breath)", stops)
	Check(apart <= 5, "no breath while Z-City's lungs do not work or its heart stands, and a breath while they do (%d of %d looks apart: a breath begins a step after the lungs work again)", apart, n)
	-- (labels that came and went within a step or two: there should be none)
	local quick = 0
	for i = 2, #labels do
		local a, b = tonumber(string.match(labels[i - 1], "^[%d.]+")), tonumber(string.match(labels[i], "^[%d.]+"))
		if a and b and b - a < 0.25 then quick = quick + 1 end
	end
	Check(quick == 0, "no label lasted less than a quarter of a second (%d did, of %d changes)", quick, #labels)
	hook.Remove("RS_StateChanged", "RS_TestBrain")
	-- taken back
	if bot:Alive() then
		NeuroTrauma.Reset(bot)
		org.lungsfunction = true
		org.heartstop = false
		Wait(4)
		st = RS.Read(bot)
		Check(st ~= nil and st.mode == "breathing" and st.drive.kind == "normal" and st.label ~= "IRREGULAR" and st.label ~= "AGONAL", "the brain module's record reset: %s", StateLine(bot))
	else
		L("the character died of it before the reset (Z-City's own course)")
	end
	ViewOff()
	Wait(0.5)
	Done("resp_brain")
end)

------------------------------------------------------------------------------------------
S.Add("resp_perf", function()
	local p = FindSpot({ open = 220, outdoor = true })
	ViewOff()
	local bots = {}
	for i = 1, 6 do
		local b = NewBot()
		if IsValid(b) then
			bots[#bots + 1] = b
			Place(b, p + Vector(((i - 1) % 3 - 1) * 46, (math.floor((i - 1) / 3) - 0.5) * 60, 0), 0)
			Model(b, i % 2 == 0 and "models/zcity/f/female_01.mdl" or "models/zcity/m/male_06.mdl")
		end
	end
	Wait(2)
	local mid = p + Vector(0, 0, 46)
	View(mid + Vector(150, 40, 30), mid)
	Wait(2)
	-- the server: what a step costs
	local org = bots[1].organism
	local t0 = SysTime()
	local n = 2000
	for _ = 1, n do K.Step(bots[1], org, CurTime()) end
	local per = (SysTime() - t0) / n * 1e6
	Check(per < 60, "one step of one character's breathing costs %.1f microseconds (at ten a second and %d characters: %.3f ms a second)", per, #player.GetAll(), per * 10 * #player.GetAll() / 1000)
	t0 = SysTime()
	for _ = 1, n do RS.Read(bots[1]) end
	L("reading a state costs %.1f microseconds", (SysTime() - t0) / n * 1e6)
	-- the wire
	local ns = RS.Net.stats
	local c0, b0, tA = ns.clocks, ns.clockBytes, CurTime()
	Wait(10)
	local secs = CurTime() - tA
	Check((ns.clockBytes - b0) / secs < 200, "%d characters at rest for %.0f s: %d clock message(s), %.1f bytes a second in all (%.1f a character)", #player.GetAll(), secs, ns.clocks - c0, (ns.clockBytes - b0) / secs,
		(ns.clockBytes - b0) / secs / #player.GetAll())
	-- the screen: off, the chest alone, the view on all of them, with the skeleton
	Client("resp", { step = "perf", tag = "view off (Z-City's chest on the clock)", secs = 4 })
	Wait(4.6)
	RunConsoleCommand("resp_zcity_chest", "0")
	Wait(0.5)
	Client("resp", { step = "perf", tag = "view off, resp_zcity_chest 0", secs = 4 })
	Wait(4.6)
	RunConsoleCommand("resp_zcity_chest", "1")
	Cvar("resp_view_who", "all")
	Cvar("resp_view_info", 0)
	Cvar("resp_view", 1)
	Wait(2)
	Client("resp", { step = "perf", tag = "lung view on " .. #bots .. " bodies", secs = 5 })
	Wait(5.6)
	Shot("rpf_1_six_bodies")
	-- (the harness hides the game's own writing on the screen: shown for one picture of the view's words)
	Cvar("resp_view_info", 1)
	Cvar("cl_drawhud", 1)
	Wait(0.6)
	Shot("rpf_2_six_bodies_with_words")
	Cvar("cl_drawhud", 0)
	Cvar("resp_view_info", 0)
	Client("resp", { step = "chestcost", ent = bots[1]:EntIndex() })
	Cvar("skel_view_who", "all")
	Cvar("skel_view_labels", 0)
	Cvar("skel_view", 1)
	Wait(2)
	Client("resp", { step = "perf", tag = "lung view and skeleton view on " .. #bots .. " bodies", secs = 5 })
	Wait(5.6)
	Shot("rpf_3_six_bodies_with_skeletons")
	ViewOff()
	Wait(1)
	Client("resp", { step = "left", tag = "after the perf scene" })
	local rs = RS.Net.stats
	L("the wire in all: %d clock message(s), %d bytes; records asked for %d time(s), refused %d, sent %d, %d bytes", rs.clocks, rs.clockBytes, rs.asked, rs.refused, rs.recs, rs.recBytes)
	L("the clocks: %d step(s), %d time(s) a clock did not simply run on, %d record(s) made, %d cleared", K.stats.steps, K.stats.jumps, K.stats.made, K.stats.cleared)
	Wait(0.5)
	Done("resp_perf")
end)
