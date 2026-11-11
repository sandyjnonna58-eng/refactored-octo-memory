-- Hostile scenes (developer tool; only with the test harness, see sv_selftest.lua). They try to
-- break the blood system instead of showing it: entities that vanish under it, models that change
-- under it, convars at their limits, low frame rates and stalls, events that are wrong, doubled or
-- name the wrong entity, traces that find nothing, values that are not numbers. After every action
-- the client half (client/cl_hostile.lua) writes what is still alive against a baseline (leak),
-- scans the whole simulated state (scan) and counts the Lua errors raised. They run only when asked
-- for by name:  hostile_lifetime, hostile_model, hostile_cache, hostile_extremes, hostile_fps,
-- hostile_corpse, hostile_head, hostile_net, hostile_world, hostile_traces, hostile_bad,
-- hostile_zcity (one blood system on screen: what Z-City still shows of its own),
-- onset (the first seconds of a wound, frame by frame), onset_rates (the same wound at four
-- frame rates, across a stall, from three distances), hostile_churn (wound, bleed, close, remove,
-- a few hundred times).

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot
local N, WD, Z = ABL.Net, ABL.Wound, ABL.ZC

local function Base(name, key) Client("leakcheck", { name = name, key = key, base = true }) Wait(0.15) end
local function Check(name, key)
	Client("leakcheck", { name = name, key = key })
	Client("scan", { name = name })
	Wait(0.2)
end

-- (Z-City closes a small wound within seconds: the wound values are kept where they were set)
local function Hold(bot, seconds)
	local org = bot.organism
	if not istable(org) or not istable(org.wounds) or not org.wounds[1] then return end
	local values = {}
	for i, w in ipairs(org.wounds) do values[i] = w[1] end
	local name = "ABL_HostileHold" .. bot:EntIndex()
	local untilT = CurTime() + seconds
	timer.Create(name, 0.3, 0, function()
		if not IsValid(bot) or not istable(bot.organism) or CurTime() > untilT then timer.Remove(name) return end
		local w = bot.organism.wounds
		if not istable(w) then return end
		for i, v in ipairs(values) do
			if w[i] then w[i][1] = v end
		end
		bot.organism.owner:SetNetVar("wounds", w)
	end)
end

local function Fake(bot)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	return ABL.DevRagdollOf(bot)
end

local function Bleeder(p, yaw, model)
	local bot = NewBot()
	if not IsValid(bot) then return nil end
	Place(bot, p, yaw or 90)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	if model then bot:SetModel(model) end
	return bot
end

local function ClientCvar(name, value) Client("cvar", { name = name, value = tostring(value) }) end

-- One abl_hit as the wire has it (sv_main.lua SendHit), with whatever values are asked for.
local function SendHit(o)
	local host = ST.Host()
	net.Start(N.HIT)
	net.WriteUInt(o.index or 0, 13)
	net.WriteUInt(o.bone or 0, 8)
	N.WriteLocal(o.lpos or Vector(0, 0, 0))
	net.WriteNormal(o.dir or Vector(1, 0, 0))
	net.WriteUInt(o.class or 0, 3)
	net.WriteUInt(o.damage or 30, 10)
	net.WriteUInt(o.bleed or 240, 10)
	net.WriteUInt(o.hitgroup or 2, 4)
	WD.Write({ pen = o.pen or WD.PEN_THROUGH, energy = o.energy or 2, velocity = o.velocity or 1, diameter = o.diameter or 6, range = o.range or 0, flags = o.flags or 0, seed = o.seed or 1 })
	net.WriteBool(o.second or false)
	net.WriteBool(o.lexit ~= nil)
	if o.lexit then N.WriteLocal(o.lexit) end
	net.WriteBool(o.continued or false)
	net.WriteUInt(o.own or 0, 8)
	net.Send(host)
end

local function SendCollide(o)
	local host = ST.Host()
	net.Start(N.RCOL, true)
	net.WriteUInt(o.index or 0, 13)
	net.WriteUInt(o.bone or 0, 8)
	net.WriteVector(o.pos or Vector(0, 0, 0))
	net.WriteNormal(o.normal or Vector(0, 0, 1))
	net.WriteUInt(o.speed or 400, 12)
	net.WriteBool(true)
	net.Send(host)
end

------------------------------------------------------------------------------------------
-- Entities that vanish
------------------------------------------------------------------------------------------
ST.Add("hostile_lifetime", function()
	local host = ST.Host()
	local p = FindSpot({ open = 220, outdoor = true })
	View(p + Vector(0, -190, 95), p + Vector(0, 0, 30))
	Wait(1)
	Base("L0_empty", "life")

	-- a bleeding player is kicked
	local a = Bleeder(p + Vector(-90, 0, 0))
	Wait(2.5)
	ABL.DevAddWound(a, "chest", 3, false, 3, 0.55, 0.5)
	ABL.DevAddWound(a, "neck", 6, true, 3, 0.5, 0.5)
	Wait(5)
	Check("La_bleeding", "life")
	Shot("hL_a_bleeding")
	a:Kick("ABL hostile: kicked while bleeding")
	Wait(0.3)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Wait(3)
	Check("La_kicked_3s", "life")

	-- a player is killed, and the corpse is removed while it bleeds
	local b = Bleeder(p + Vector(-30, 0, 0))
	Wait(2.5)
	ABL.DevAddWound(b, "chest", 3, false, 3, 0.55, 0.5)
	Wait(3)
	b:Kill()
	Wait(4)
	Check("Lb_corpse", "life")
	local corpse = Z.GetCorpse(b)
	Log("  lifetime: corpse %s (bot alive %s)", tostring(corpse), tostring(IsValid(b) and b:Alive()))
	if IsValid(corpse) then corpse:Remove() end
	Wait(3)
	Check("Lb_corpse_removed_3s", "life")

	-- a living player's ragdoll is removed under it
	local c = Bleeder(p + Vector(30, 0, 0))
	Wait(2.5)
	ABL.DevAddWound(c, "chest", 3, false, 3, 0.55, 0.5)
	Hold(c, 30)
	Wait(2)
	local rag = Fake(c)
	Wait(3)
	Check("Lc_ragdolled", "life")
	Log("  lifetime: fake ragdoll %s", tostring(rag))
	if IsValid(rag) then rag:Remove() end
	Wait(3)
	Check("Lc_ragdoll_removed_3s", "life")

	-- a player respawns while bleeding
	if IsValid(c) then
		c:Spawn()
		Wait(0.3)
		Place(c, p + Vector(30, 0, 0), 90)
		Wait(3)
		Check("Lc_respawned_3s", "life")
	end

	-- a player is shot and gone a tick later (the event names an entity that is no more)
	local d = Bleeder(p + Vector(90, 0, 0))
	Wait(2.5)
	ABL.DevAddWound(d, "chest", 3, false, 3, 0.55, 0.5)
	ABL.DevShoot(host, d, 15, "front", "chest", "9x19mmparabellum")
	timer.Simple(0.03, function() if IsValid(d) then d:Kick("ABL hostile: gone a tick after the hit") end end)
	Wait(0.5)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Wait(3)
	Check("Ld_gone_after_hit_3s", "life")

	-- a player is knocked into a ragdoll by the shot, and the ragdoll is removed in the tick it appears
	local e = Bleeder(p + Vector(0, 70, 0))
	Wait(2.5)
	ABL.DevShoot(host, e, 15, "front", "chest", "9x19mmparabellum")
	Fake(e)
	local rag2 = ABL.DevRagdollOf(e)
	if IsValid(rag2) then rag2:Remove() end
	Wait(3)
	Check("Le_ragdoll_removed_at_once_3s", "life")

	-- the client switch off and on again in mid-bleed
	local f = Bleeder(p + Vector(0, -70, 0))
	Wait(2.5)
	ABL.DevAddWound(f, "chest", 3, false, 3, 0.55, 0.5)
	Hold(f, 30)
	Wait(4)
	ClientCvar("abl_cl_enabled", 0)
	Wait(1.5)
	Check("Lf_disabled", "life")
	ClientCvar("abl_cl_enabled", 1)
	Wait(4)
	Check("Lf_enabled_again_4s", "life")
	Shot("hL_f_enabled_again")

	-- everyone gone: nothing of a body may be left
	for _, bt in ipairs(player.GetBots()) do bt:Kick("ABL hostile: end of the scene") end
	Wait(0.3)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Wait(6.5)
	Check("Lz_all_gone_7s", "life")
end)

------------------------------------------------------------------------------------------
-- Models that change
------------------------------------------------------------------------------------------
local MODEL_A, MODEL_B, MODEL_C = "models/zcity/m/male_08.mdl", "models/zcity/f/female_07.mdl", "models/zcity/m/male_02.mdl"

ST.Add("hostile_model", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bleeder(p, 0, MODEL_A)
	View(p + Vector(70, -34, 52), p + Vector(0, 0, 40))
	Wait(3)
	local function Body(tag)
		local body = Z.GetBody(bot)
		Log("  model %s: body %s, model %s, ragdolled %s, alive %s", tag, tostring(body), IsValid(body) and tostring(body:GetModel()) or "-", tostring(IsValid(bot.FakeRagdoll)), tostring(bot:Alive()))
	end
	-- (the body must stand: a ragdoll keeps the model it was made with whatever the player's becomes)
	local function Stand()
		if IsValid(bot.FakeRagdoll) and hg and hg.FakeUp then
			hg.FakeUp(bot, true, true)
			Wait(1.2)
		end
	end
	Base("M0_before", "model")
	ABL.DevAddWound(bot, "chest", 1.5, false, 3, 0.55, 0.5)
	ABL.DevAddWound(bot, "lthigh", 1.0, false, 4, 0.5, 0.5)
	Hold(bot, 120)
	Wait(0.5)
	-- (a gunshot wound with its marks, without the shot that would knock the body down)
	local belly = bot:LookupBone("ValveBiped.Bip01_Spine1") or 0
	SendHit({ index = bot:EntIndex(), bone = belly, lpos = Vector(2, 6, 1), dir = -bot:GetForward(), seed = 777, own = bot:EntIndex() })
	Wait(7)
	Stand()
	Body("at the start")
	Check("M0_bleeding", "model")
	Shot("hM_0_bleeding")

	-- a bodygroup (clothing) changes
	local changed = false
	for i = 0, bot:GetNumBodyGroups() - 1 do
		local n = bot:GetBodygroupCount(i)
		if n > 1 then
			bot:SetBodygroup(i, (bot:GetBodygroup(i) + 1) % n)
			Log("  model: bodygroup %d of %s set to %d (of %d)", i, tostring(bot:GetModel()), bot:GetBodygroup(i), n)
			changed = true
			break
		end
	end
	if not changed then Log("  model: %s has no bodygroup with a choice", tostring(bot:GetModel())) end
	Wait(0.25)
	Body("bodygroup changed")
	Check("Ma_bodygroup_0.25s", "model")
	Wait(3)
	Check("Ma_bodygroup_3s", "model")
	Shot("hM_a_bodygroup")

	-- another model with the same skeleton
	Stand()
	bot:SetModel(MODEL_B)
	Wait(0.25)
	Body("other model")
	Check("Mb_other_model_0.25s", "model")
	Wait(1)
	Check("Mb_other_model_1.25s", "model")
	Wait(3)
	Check("Mb_other_model_4s", "model")
	Shot("hM_b_other_model")

	-- a model with another skeleton altogether, then one with a single bone
	for _, e in ipairs({ { "crow", "models/crow.mdl" }, { "melon", "models/props_junk/watermelon01.mdl" } }) do
		Stand()
		bot:SetModel(e[2])
		Wait(0.25)
		Body(e[1])
		Check("Mc_" .. e[1] .. "_0.25s", "model")
		Wait(3)
		Check("Mc_" .. e[1] .. "_3s", "model")
	end
	Stand()
	bot:SetModel(MODEL_A)
	Wait(4)
	Body("back")
	Check("Md_back_4s", "model")
	Shot("hM_d_back")

	-- ragdolled; the clothes of the ragdoll change; the model of the player changes under the
	-- ragdoll; the player gets up again
	local rag = Fake(bot)
	Wait(3)
	Body("ragdolled")
	Check("Me_ragdolled", "model")
	if IsValid(rag) then
		for i = 0, rag:GetNumBodyGroups() - 1 do
			local n = rag:GetBodygroupCount(i)
			if n > 1 then
				rag:SetBodygroup(i, (rag:GetBodygroup(i) + 1) % n)
				Log("  model: bodygroup %d of the ragdoll set to %d (of %d)", i, rag:GetBodygroup(i), n)
				break
			end
		end
	end
	Wait(0.25)
	Check("Me_ragdoll_bodygroup_0.25s", "model")
	Wait(3)
	Check("Me_ragdoll_bodygroup_3s", "model")
	bot:SetModel(MODEL_B)
	Wait(1)
	if hg and hg.FakeUp then hg.FakeUp(bot, true, true) end
	Wait(0.3)
	Body("up again with another model")
	Check("Me_up_0.3s", "model")
	Wait(1.2)
	Check("Me_up_1.5s", "model")
	Wait(2.5)
	Check("Me_up_4s", "model")
	Shot("hM_e_up")

	-- the model changes and the player dies a moment later: the corpse has the new model
	Stand()
	bot:SetModel(MODEL_C)
	Wait(0.1)
	bot:Kill()
	Wait(0.5)
	Body("dead")
	Check("Mf_died_0.5s", "model")
	Wait(3)
	Check("Mf_died_3.5s", "model")
	Shot("hM_f_corpse")
	Client("wounds", { name = "hM_end" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- Convars at their limits
------------------------------------------------------------------------------------------
ST.Add("hostile_extremes", function()
	local host = ST.Host()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(40, -150, 80), p + Vector(0, 0, 30))
	local function Round(tag, o)
		for k, v in pairs(o.sv or {}) do RunConsoleCommand(k, tostring(v)) end
		for k, v in pairs(o.cl or {}) do ClientCvar(k, v) end
		Wait(o.settle or 0.6)
		local bot = Bleeder(p, 90, "models/zcity/m/male_06.mdl")
		Wait(2.5)
		Base("X_" .. tag .. "_before", "x")
		ABL.DevAddWound(bot, "chest", o.amount or 3, false, 3, 0.55, 0.5)
		if o.arterial then ABL.DevAddWound(bot, "neck", o.arterial, true, 3, 0.5, 0.5) end
		Hold(bot, 20)
		for k = 1, 6 do
			Client("spray", { pos = p + Vector(-60 + k * 20, -40, 70), dir = Vector(0, 0.2, -1), speed = 200, count = 20, vol = 0.03, cone = 0.5 })
			Wait(0.5)
		end
		ABL.DevShoot(host, bot, 20, "front", "chest", "9x19mmparabellum")
		Wait(o.wait or 5)
		Shot("hX_" .. tag)
		Check("X_" .. tag, "x")
		Client("streamstat", { ent = bot:EntIndex(), name = "X_" .. tag })
		Client("profile", { name = "hX_" .. tag, reset = true })
		Wait(0.2)
		for k, v in pairs(o.svBack or {}) do RunConsoleCommand(k, tostring(v)) end
		for k, v in pairs(o.clBack or {}) do ClientCvar(k, v) end
		if IsValid(bot) then bot:Kick("ABL hostile: next round") end
		Wait(0.3)
		for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
		Client("clear", {})
		Wait(1.5)
	end
	Round("flow_max", { sv = { abl_volume_scale = 4 }, svBack = { abl_volume_scale = 1 }, amount = 200, arterial = 60 })
	Round("flow_min", { sv = { abl_volume_scale = 0.1 }, svBack = { abl_volume_scale = 1 }, amount = 0.001 })
	Round("drying_min", { sv = { abl_drying_scale = 0.1 }, svBack = { abl_drying_scale = 1 }, amount = 1.5, wait = 9 })
	Round("drying_max", { sv = { abl_drying_scale = 10 }, svBack = { abl_drying_scale = 1 }, amount = 1.5 })
	Round("budget_min", { cl = { abl_budget_ms = 0.3, abl_quality = 0, abl_sim_hz = 30 }, clBack = { abl_budget_ms = 2.5, abl_quality = 3, abl_sim_hz = 165 }, amount = 20, arterial = 10 })
	Round("budget_max", { cl = { abl_budget_ms = 20, abl_quality = 4, abl_sim_hz = 240 }, clBack = { abl_budget_ms = 2.5, abl_quality = 3, abl_sim_hz = 165 }, amount = 20, arterial = 10 })
	Round("caps_min", { cl = { abl_max_droplets = 16, abl_max_blobs = 8, abl_max_pools = 4, abl_max_flow_nodes = 200, abl_max_traces = 10, abl_max_ground_stains = 16, abl_max_overlays = 16, abl_decals_per_sec = 1, abl_max_particles = 0, abl_max_runoff = 4 },
		clBack = { abl_max_droplets = 420, abl_max_blobs = 120, abl_max_pools = 56, abl_max_flow_nodes = 3200, abl_max_traces = 150, abl_max_ground_stains = 320, abl_max_overlays = 450, abl_decals_per_sec = 60, abl_max_particles = 260, abl_max_runoff = 72 },
		amount = 20, arterial = 10 })
	Round("gravity_zero", { sv = { sv_gravity = 0 }, svBack = { sv_gravity = 600 }, settle = 3, amount = 6, arterial = 10 })
	Round("gravity_high", { sv = { sv_gravity = 2000 }, svBack = { sv_gravity = 600 }, settle = 3, amount = 6, arterial = 10 })
	Round("gravity_up", { sv = { sv_gravity = -600 }, svBack = { sv_gravity = 600 }, settle = 3, amount = 6, arterial = 10 })
	Wait(3)
end)

------------------------------------------------------------------------------------------
-- Frame rates and a stall: the same wound each time
------------------------------------------------------------------------------------------
ST.Add("hostile_fps", function()
	local p = FindSpot({ open = 140, outdoor = true })
	View(p + Vector(64, -32, 50), p + Vector(0, 0, 40))
	-- o.ms: time burnt every frame; o.stallAt: a stall of two seconds at that time; o.maxFrame: the
	-- longest frame the simulation follows (C.MAX_FRAME) for this run
	local function Run(tag, o)
		local bot = Bleeder(p, 0, "models/zcity/m/male_06.mdl")
		Wait(3)
		if o.maxFrame then Client("poke", { key = "MAX_FRAME", value = o.maxFrame }) end
		Client("burn", { ms = o.ms or 0 })
		Wait(1)
		-- (a wound large enough to bleed steadily: one that is let through at less than 4 ml/s clots
		-- and opens again at random. Since phase 30 the governor no longer lets a wound run at its
		-- full rate for its first seconds, so the wound is larger than it was: 60, not 16)
		ABL.DevAddWound(bot, "chest", 60, false, 3, 0.55, 0.5)
		Hold(bot, 40)
		local ent = bot:EntIndex()
		local t0 = CurTime()
		local sys0 = SysTime()
		for _, tt in ipairs({ 5, 10, 20 }) do
			local w = t0 + tt - CurTime()
			if w > 0 then Wait(w) end
			if o.stallAt == tt then
				Client("streamstat", { ent = ent, name = string.format("F_%s_%02ds_before_stall", tag, tt) })
				Wait(0.1)
				Client("burn", { once = 2000 })
				Wait(1)
				Client("streamstat", { ent = ent, name = string.format("F_%s_%02ds_1s_after_stall", tag, tt) })
				Client("scan", { name = string.format("F_%s_after_stall", tag) })
				Wait(0.2)
			else
				Client("streamstat", { ent = ent, name = string.format("F_%s_%02ds", tag, tt) })
			end
			-- (Z-City's side of it: the server runs in the same thread, at the same frame rate)
			local org = IsValid(bot) and bot.organism or nil
			Log("  fps %s at %d s: Z-City's reservoir %.1f ml (lost %.1f), bleed %.2f, pulse %.0f, real time since the wound %.1f s", tag, tt,
				tonumber(org and org.blood) or -1, 5000 - (tonumber(org and org.blood) or 5000), tonumber(org and org.bleed) or -1,
				tonumber(org and org.pulse) or -1, SysTime() - sys0)
			Client("fps", { name = string.format("F_%s_%02ds", tag, tt) })
			Wait(0.1)
		end
		Shot("hF_" .. tag .. "_20s")
		Check("F_" .. tag, "fps")
		Client("burn", { ms = 0 })
		if o.maxFrame then Client("poke", { key = "MAX_FRAME", value = 0.25 }) end
		Wait(0.3)
		if IsValid(bot) then bot:Kick("ABL hostile: next rate") end
		Wait(0.3)
		for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
		Client("clear", {})
		Wait(1.5)
	end
	Base("F0", "fps")
	-- (the first run of a session is slower whatever is done in it: one that does not count)
	Run("warmup", {})
	Run("natural", {})
	-- (once more: how much two runs at the same rate differ. A rate above the natural one cannot be
	-- set from Lua: fps_max is a blocked command.)
	Run("natural_again", {})
	Run("20fps", { ms = 42 })
	Run("10fps", { ms = 92 })
	Run("5fps", { ms = 192 })
	-- (as it was before: a frame longer than a tenth of a second counted as a tenth)
	Run("5fps_frame_capped_at_100ms", { ms = 192, maxFrame = 0.1 })
	Run("stall", { stallAt = 10 })
end)

-- A corpse stops bleeding: its post-mortem ooze must fade (not start again every few seconds).
ST.Add("hostile_corpse", function()
	local p = FindSpot({ open = 160, outdoor = true })
	View(p + Vector(80, -60, 60), p + Vector(0, 0, 20))
	local bot = Bleeder(p, 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	Base("C0_before", "corpse")
	ABL.DevAddWound(bot, "chest", 16, false, 3, 0.55, 0.5)
	ABL.DevAddWound(bot, "lthigh", 10, false, 4, 0.5, 0.5)
	Wait(3)
	Client("streamstat", { ent = bot:EntIndex(), name = "C1_alive_3s" })
	bot:Kill()
	Wait(1.5)
	local corpse = Z.GetCorpse(bot)
	Log("  corpse: %s (bot alive %s)", tostring(corpse), tostring(bot:Alive()))
	local ent = IsValid(corpse) and corpse:EntIndex() or bot:EntIndex()
	local t0 = CurTime()
	for _, tt in ipairs({ 2, 6, 10, 14, 18, 22, 26, 30, 36, 42, 48 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Client("streamstat", { ent = ent, name = string.format("C2_dead_%02ds", tt) })
		if tt % 12 == 6 then Client("leakcheck", { name = string.format("C2_dead_%02ds", tt), key = "corpse" }) end
	end
	Check("C3_dead_48s", "corpse")
	Shot("hC_corpse_48s")
end)

-- A head that Z-City has destroyed: its bone is scaled away under the wounds, the marks and the
-- streams that are on it.
ST.Add("hostile_head", function()
	local host = ST.Host()
	local p = FindSpot({ open = 160, outdoor = true })
	View(p + Vector(64, -32, 62), p + Vector(0, 0, 58))
	local bot = Bleeder(p, 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	Base("H0_before", "head")
	ABL.DevAddWound(bot, "head", 1.5, false, 3, 0.6, 0.5)
	ABL.DevAddWound(bot, "neck", 1.5, false, 3, 0.5, 0.5)
	Hold(bot, 30)
	Wait(5)
	Check("H1_bleeding_from_the_head", "head")
	Shot("hH_before")
	-- rifle cartridges into the head from close by, until Z-City takes it off
	for k = 1, 4 do
		if IsValid(bot) then ABL.DevShoot(host, bot, nil, k % 2 == 0 and "left" or "front", "head", "7.62x51mm", 30) end
		Wait(0.4)
	end
	Wait(2)
	local body = ABL.DevRagdollOf(bot)
	local gone, scale = false, "-"
	if IsValid(body) then
		local hb = body:LookupBone("ValveBiped.Bip01_Head1")
		local sc = hb and body:GetManipulateBoneScale(hb)
		scale = sc and tostring(sc) or "-"
		gone = (body.headexploded and true) or (sc ~= nil and sc:LengthSqr() < 0.01) or false
	end
	Log("  head: body %s, head destroyed %s (bone scale %s), bot alive %s", tostring(body), tostring(gone), scale, tostring(IsValid(bot) and bot:Alive()))
	Check("H2_after_the_shots_2s", "head")
	-- (Z-City takes a head off by scaling its bone away, and not at every shot: done here as it
	-- does it, so that the case is there in every run)
	if IsValid(body) and not gone then
		local hb = body:LookupBone("ValveBiped.Bip01_Head1")
		if hb then
			body:ManipulateBoneScale(hb, Vector(0, 0, 0))
			Log("  head: bone %d of %s scaled away", hb, tostring(body))
		end
	end
	Wait(1)
	Check("H3_head_scaled_away_1s", "head")
	Wait(6)
	Check("H4_head_scaled_away_7s", "head")
	Shot("hH_after")
	Client("wounds", { name = "hH_end" })
	Client("flowstats", { name = "hH_end" })
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- Events that are wrong
------------------------------------------------------------------------------------------
ST.Add("hostile_net", function()
	local host = ST.Host()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(70, -60, 56), p + Vector(0, 0, 40))
	local bot = Bleeder(p, 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	Base("N0_before", "net")
	Client("netstat", { name = "N0" })
	local chest = bot:LookupBone("ValveBiped.Bip01_Spine2") or 0
	local fwd = bot:GetForward()

	-- one real shot: what one hit makes
	ABL.DevShoot(host, bot, 10, "front", "chest", "9x19mmparabellum")
	Wait(2)
	Client("wounds", { name = "hN_one_shot" })
	Check("N1_one_shot", "net")

	-- the same event twice in one tick, and once more a second later
	local ev = { index = bot:EntIndex(), bone = chest, lpos = Vector(2, 5, 3), dir = -fwd, seed = 4242, own = bot:EntIndex() }
	SendHit(ev)
	SendHit(ev)
	Wait(1)
	SendHit(ev)
	Wait(1.5)
	Client("wounds", { name = "hN_same_event_three_times" })
	Check("N2_same_event_three_times", "net")

	-- an event that names something that is no character (an entity index used again), nothing at
	-- all, and the world
	local prop = ents.Create("prop_physics")
	prop:SetModel("models/props_junk/wood_crate001a.mdl")
	prop:SetPos(p + Vector(0, 90, 30))
	prop:Spawn()
	local phys = prop:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	Wait(1)
	SendHit({ index = prop:EntIndex(), bone = 0, lpos = Vector(0, 0, 0), dir = Vector(0, -1, 0), seed = 5001 })
	SendHit({ index = 3900, bone = 0, seed = 5002 })
	SendHit({ index = 0, bone = 0, seed = 5003 })
	Wait(2)
	Check("N3_not_a_character", "net")

	-- values no hit has: a bone that is not there, a position at the edge of the range, no direction,
	-- a class and codes beyond the known ones, an owner that is no player
	SendHit({ index = bot:EntIndex(), bone = 255, seed = 5101 })
	SendHit({ index = bot:EntIndex(), bone = chest, lpos = Vector(127.9, 127.9, 127.9), dir = -fwd, seed = 5102 })
	SendHit({ index = bot:EntIndex(), bone = chest, lpos = Vector(2, 5, -3), dir = Vector(0, 0, 0), seed = 5103 })
	SendHit({ index = bot:EntIndex(), bone = chest, lpos = Vector(-2, 5, 0), dir = -fwd, class = 7, damage = 1023, bleed = 1023, hitgroup = 15, pen = 3, energy = 7, velocity = 3, diameter = 15, range = 3, flags = 4095, seed = 5104 })
	SendHit({ index = bot:EntIndex(), bone = chest, lpos = Vector(0, 5, 5), dir = -fwd, damage = 0, bleed = 0, seed = 5105, own = math.min(prop:EntIndex(), 255) })
	SendHit({ index = bot:EntIndex(), bone = chest, lpos = Vector(1, 5, 1), dir = -fwd, seed = 5106, continued = true, second = true, lexit = Vector(-127.9, -127.9, -127.9) })
	Wait(2.5)
	Client("wounds", { name = "hN_malformed" })
	Check("N4_malformed", "net")

	-- a collision event with a position that is not a number, a bone that is not there, and for
	-- something that is no ragdoll
	local nan = 0 / 0
	SendCollide({ index = bot:EntIndex(), bone = chest, pos = Vector(nan, nan, nan) })
	SendCollide({ index = bot:EntIndex(), bone = 255, pos = p + Vector(0, 0, 40) })
	SendCollide({ index = prop:EntIndex(), bone = 0, pos = p + Vector(0, 90, 30) })
	SendCollide({ index = 3900, bone = 0, pos = p })
	Wait(1.5)
	Check("N5_bad_collisions", "net")
	prop:Remove()

	-- spam: a shot cartridge ten times a second for five seconds
	local bot2 = Bleeder(p + Vector(0, -60, 0), 0, "models/zcity/m/male_06.mdl")
	Wait(2.5)
	Client("netstat", { name = "N6_before_spam" })
	Client("profile", { reset = true })
	local shots = 0
	for _ = 1, 50 do
		if IsValid(bot2) then
			ABL.DevShoot(host, bot2, 2, "front", "chest", "12/70gauge", 40)
			shots = shots + 1
		end
		Wait(0.1)
	end
	Log("  net: %d shot cartridges fired at %s (alive %s)", shots, tostring(bot2), tostring(IsValid(bot2) and bot2:Alive()))
	Client("netstat", { name = "N6_spam_5s" })
	Client("profile", { name = "hN_spam", reset = true })
	Wait(2)
	Client("wounds", { name = "hN_spam" })
	Check("N6_spam", "net")
	Shot("hN_spam")
	Wait(4)
	Check("N7_spam_6s_later", "net")

	-- a snapshot of pools for a late joiner in which one record has no place, one no surface
	-- normal and one lies far under the floor; and one that is in order
	-- (nobody bleeding meanwhile: every pool there is afterwards came from the snapshot)
	for _, bt in ipairs(player.GetBots()) do bt:Kick("ABL hostile: before the snapshot") end
	Wait(0.3)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Wait(1)
	Client("clear", {})
	Wait(1)
	Base("N8_before_snapshot", "net2")
	net.Start(N.PERSIST)
	net.WriteUInt(4, 7)
	net.WriteVector(Vector(nan, nan, nan)) net.WriteNormal(Vector(0, 0, 1)) net.WriteUInt(60, 14) net.WriteUInt(0, 14)
	net.WriteVector(p + Vector(40, 40, 1)) net.WriteNormal(Vector(0, 0, 0)) net.WriteUInt(60, 14) net.WriteUInt(0, 14)
	net.WriteVector(p + Vector(-40, 40, -300)) net.WriteNormal(Vector(0, 0, 1)) net.WriteUInt(60, 14) net.WriteUInt(0, 14)
	net.WriteVector(p + Vector(-40, -40, 1)) net.WriteNormal(Vector(0, 0, 1)) net.WriteUInt(60, 14) net.WriteUInt(30, 14)
	net.Send(host)
	Wait(2)
	Check("N8_snapshot_with_bad_records", "net2")

	-- Z-City's functions put back over ABL's wrappers: within a few seconds they are wrapped again
	Client("wrapstate", { name = "N9_before" })
	Client("unwrap", {})
	Wait(0.3)
	Client("wrapstate", { name = "N9_unwrapped" })
	Wait(7)
	Client("wrapstate", { name = "N9_7s_later" })
	Wait(0.2)
end)

-- Surface models are kept for a number of models and outfits only. Here for two, and unasked for
-- for a second: a character that goes through five models has each built again, and the ones
-- before it dropped.
ST.Add("hostile_cache", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bleeder(p, 0, MODEL_A)
	View(p + Vector(70, -34, 52), p + Vector(0, 0, 40))
	Wait(3)
	Client("poke", { key = "MESH_KEEP", value = 2 })
	Client("poke", { key = "MESH_IDLE", value = 1 })
	Base("K0_before", "cache")
	ABL.DevAddWound(bot, "chest", 1.5, false, 3, 0.55, 0.5)
	Hold(bot, 60)
	Wait(4)
	Check("K1_bleeding", "cache")
	for i, mdl in ipairs({ MODEL_B, MODEL_C, "models/zcity/m/male_06.mdl", MODEL_A, MODEL_B, MODEL_C }) do
		if IsValid(bot.FakeRagdoll) and hg and hg.FakeUp then
			hg.FakeUp(bot, true, true)
			Wait(1.2)
		end
		bot:SetModel(mdl)
		Wait(4)
		Client("streamstat", { ent = bot:EntIndex(), name = "K2_model_" .. i })
		Check("K2_model_" .. i .. "_4s", "cache")
	end
	Shot("hK_last_model")
	Client("poke", { key = "MESH_KEEP", value = 24 })
	Client("poke", { key = "MESH_IDLE", value = 60 })
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- Walls full of dry streams: is there room left for a body?
------------------------------------------------------------------------------------------
ST.Add("hostile_world", function()
	local p, wallDir, wallDist = FindSpot({ open = 120, wall = true })
	if not p or not wallDir then Log("  world: no spot with a wall") return end
	local side = wallDir:Cross(Vector(0, 0, 1))
	View(p - wallDir * 90 + Vector(0, 0, 60), p + wallDir * wallDist + Vector(0, 0, 45))
	ClientCvar("abl_max_flow_nodes", 200)
	Wait(1)
	Base("W0_before", "world")
	-- blood thrown at the wall, again and again, along it
	for k = 1, 36 do
		local o = side * ((k % 9) - 4) * 14
		Client("spray", { pos = p + o + Vector(0, 0, 50 + (k % 4) * 12), dir = wallDir, speed = 240, count = 24, vol = 0.14, cone = 0.22 })
		Wait(0.4)
		if k % 12 == 0 then Check("W1_spray_" .. k, "world") end
	end
	Wait(6)
	Shot("hW_wall")
	Client("flowstats", { name = "hW_wall" })
	Check("W2_wall_full", "world")
	-- the streams dry (on a clock ten times as fast), and more blood comes: the dry ones make way
	RunConsoleCommand("abl_drying_scale", "0.1")
	Wait(25)
	Check("W2_wall_dried_25s", "world")
	for k = 1, 18 do
		local o = side * ((k % 9) - 4) * 14
		Client("spray", { pos = p + o + Vector(0, 0, 44 + (k % 4) * 12), dir = wallDir, speed = 240, count = 24, vol = 0.14, cone = 0.22 })
		Wait(0.4)
	end
	Wait(3)
	Check("W2_more_blood_on_the_dried_wall", "world")
	RunConsoleCommand("abl_drying_scale", "1")
	Wait(0.5)
	-- a body bleeds next to it: does it still get a stream?
	local bot = Bleeder(p - wallDir * 20 + side * 30, 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	ABL.DevAddWound(bot, "chest", 1.5, false, 3, 0.55, 0.5)
	Hold(bot, 30)
	Wait(10)
	Client("streamstat", { ent = bot:EntIndex(), name = "W3_body_beside_full_wall_10s" })
	Check("W3_body_beside_full_wall", "world")
	View(bot:GetPos() + Vector(60, -30, 50), bot:GetPos() + Vector(0, 0, 40))
	Wait(0.4)
	Shot("hW_body")
	ClientCvar("abl_max_flow_nodes", 3200)
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- Traces that find nothing, or the wrong thing
------------------------------------------------------------------------------------------
ST.Add("hostile_traces", function()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(40, -150, 80), p + Vector(0, 0, 20))
	Wait(1)
	Base("T0_before", "trace")
	Client("impactstat", { name = "T0" })

	-- into the sky
	for _ = 1, 4 do
		Client("spray", { pos = p + Vector(0, 0, 60), dir = Vector(0, 0, 1), speed = 1400, count = 30, vol = 0.05, cone = 0.15 })
		Wait(0.3)
	end
	Wait(7.5)
	Client("impactstat", { name = "T1_sky" })
	Check("T1_sky", "trace")

	-- from inside the floor and from inside a wall of the map
	for _ = 1, 4 do
		Client("spray", { pos = p - Vector(0, 0, 6), dir = Vector(0.3, 0, -1), speed = 60, count = 30, vol = 0.05, cone = 0.6 })
		Client("spray", { pos = p - Vector(0, 0, 2), dir = Vector(1, 0, 0.2), speed = 80, count = 20, vol = 0.05, cone = 0.4 })
		Wait(0.3)
	end
	Wait(8)
	Client("impactstat", { name = "T2_from_inside_solid" })
	Check("T2_from_inside_solid", "trace")

	-- a body lying on its wound
	local bot = Bleeder(p + Vector(60, 0, 0), 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	local rag = Fake(bot)
	Wait(1)
	if IsValid(rag) then ABL.DevPose(rag, "front") end
	Wait(1.5)
	ABL.DevAddWound(bot, "chest", 6, false, 3, 0.55, 0.5)
	ABL.DevAddWound(bot, "stomach", 6, false, 3, 0.5, 0.5)
	Hold(bot, 20)
	Wait(9)
	Client("impactstat", { name = "T3_lying_on_its_wound" })
	Client("streamstat", { ent = bot:EntIndex(), name = "T3_lying_on_its_wound" })
	Check("T3_lying_on_its_wound", "trace")
	Shot("hT_lying")

	-- onto a prop; the prop is moved, then removed
	local prop = ents.Create("prop_physics")
	prop:SetModel("models/props_junk/wood_crate001a.mdl")
	prop:SetPos(p + Vector(-70, 0, 22))
	prop:Spawn()
	local phys = prop:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	Wait(1)
	for k = 1, 10 do
		Client("spray", { pos = p + Vector(-70, 0, 90), dir = Vector(0, 0, -1), speed = 30, count = 10, vol = 0.3, cone = 0.1 })
		Client("spray", { pos = p + Vector(-70, -60, 40), dir = Vector(0, 1, 0), speed = 200, count = 14, vol = 0.15, cone = 0.2 })
		Wait(0.4)
	end
	Wait(3)
	Check("T4_on_a_prop", "trace")
	Shot("hT_prop")
	prop:SetPos(p + Vector(-70, 80, 22))
	Wait(3)
	Check("T5_prop_moved_3s", "trace")
	-- (blood falling onto it while it moves)
	if IsValid(phys) then
		phys:EnableMotion(true)
		phys:Wake()
		phys:SetVelocity(Vector(120, 0, 260))
		phys:AddAngleVelocity(Vector(200, 150, 0))
	end
	for k = 1, 8 do
		local q = prop:GetPos()
		Client("spray", { pos = q + Vector(0, 0, 60), dir = Vector(0, 0, -1), speed = 80, count = 12, vol = 0.2, cone = 0.2 })
		Wait(0.25)
	end
	Wait(2)
	Check("T6_onto_a_moving_prop", "trace")
	prop:Remove()
	Wait(3)
	Check("T7_prop_removed_3s", "trace")
	Client("impactstat", { name = "T7" })
	Client("flowstats", { name = "hT_end" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- Values that are not numbers (last: at the worst this scene ends the run)
------------------------------------------------------------------------------------------
ST.Add("hostile_bad", function()
	local p = FindSpot({ open = 160, outdoor = true })
	View(p + Vector(70, -34, 52), p + Vector(0, 0, 40))
	-- a character whose bank is empty before its first wound asks for anything
	local bot = Bleeder(p, 0, "models/zcity/m/male_06.mdl")
	Wait(3)
	Base("B0_before", "bad")
	Client("emptybank", { ent = bot:EntIndex() })
	Wait(0.2)
	ABL.DevAddWound(bot, "chest", 1.5, false, 3, 0.55, 0.5)
	Hold(bot, 40)
	Wait(4)
	Client("streamstat", { ent = bot:EntIndex(), name = "B1_empty_bank_4s" })
	Check("B1_empty_bank_4s", "bad")
	Wait(6)
	Client("streamstat", { ent = bot:EntIndex(), name = "B1_empty_bank_10s" })
	Check("B1_empty_bank_10s", "bad")
	Shot("hB_empty_bank")
	Client("clear", {})
	Wait(3)
	-- (the wound is still there: blood begins again from an empty state)
	Check("B2_cleared", "bad")
	-- values that must be turned away where they enter
	Client("badvalues", { name = "B3", pos = p + Vector(40, 0, 0) })
	Wait(3)
	Check("B3_bad_values_3s", "bad")
	Client("flowstats", { name = "hB_end" })
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- Z-City: one blood system on screen
------------------------------------------------------------------------------------------
-- What Z-City's server code asked for in blood decals and puffs and what was left out, and the
-- physiology of one character as Z-City has it.
local zPrev = { hits = 0, decals = 0, effects = 0 }
local function ZServer(name, bot)
	local SVC = ABL.CompatSV
	local st = SVC and SVC.stat or { hits = 0, decals = 0, effects = 0, names = {} }
	local names = {}
	for k, v in pairs(st.names or {}) do names[#names + 1] = k .. " " .. v end
	table.sort(names)
	local phys = "-"
	local org = IsValid(bot) and istable(bot.organism) and bot.organism or nil
	if org then
		phys = string.format("alive %s blood %.1f bleed %.3f pulse %.0f wounds %d+%d pain %.1f shock %.1f consciousness %.2f",
			tostring(not bot:IsPlayer() or bot:Alive()), tonumber(org.blood) or -1, tonumber(org.bleed) or -1, tonumber(org.pulse) or -1,
			istable(org.wounds) and #org.wounds or 0, istable(org.arterialwounds) and #org.arterialwounds or 0,
			tonumber(org.pain) or -1, tonumber(org.shock) or -1, tonumber(org.consciousness) or -1)
	end
	Log("  zcity %s | server left out: hit decals +%d, blood decals +%d, blood puffs +%d (so far by name: %s) | suppressing %s | physiology: %s",
		name, st.hits - zPrev.hits, st.decals - zPrev.decals, st.effects - zPrev.effects, #names > 0 and table.concat(names, ", ") or "none",
		tostring(SVC ~= nil and SVC.Suppressing()), phys)
	zPrev.hits, zPrev.decals, zPrev.effects = st.hits, st.decals, st.effects
end

local function ZC(name, bot)
	ZServer(name, bot)
	Client("zcstat", { name = name, ent = IsValid(bot) and bot:EntIndex() or 0 })
	Wait(0.2)
end

-- A cut through Z-City's damage call.
local function Cut(host, bot, damage)
	local body = Z.GetBody(bot)
	local pos = ABL.DevHitboxCenter(body, "chest") or (bot:GetPos() + Vector(0, 0, 50))
	local dir = (pos - host:EyePos()):GetNormalized()
	local d = DamageInfo()
	d:SetDamage(damage or 18)
	d:SetDamageType(DMG_SLASH)
	d:SetAttacker(host)
	d:SetInflictor(host)
	d:SetDamagePosition(pos - dir * 4)
	d:SetDamageForce(dir * 400)
	d:SetReportedPosition(pos - dir * 40)
	body:TakeDamageInfo(d)
	return pos, dir
end

-- What Z-City's cutting weapons do at a hit on flesh (weapon_melee, SWEP:PlayEffects): through the
-- weapon's own method when one can be had, else the two calls it makes.
local function MeleeEffects(host, bot, pos, dir)
	local done = false
	local stored = weapons.GetStored("weapon_melee")
	if istable(stored) and isfunction(stored.PlayEffects) then
		local fake = setmetatable({ DamageType = DMG_SLASH, AttackHitFlesh = "Flesh.ImpactHard", Attack2HitFlesh = "Flesh.ImpactHard",
			GetOwner = function() return host end, IsEntSoft = function() return true end }, { __index = stored })
		local ok, err = pcall(stored.PlayEffects, fake, { Entity = Z.GetBody(bot), HitPos = pos, HitNormal = -dir, MatType = MAT_FLESH }, false)
		done = ok
		if not ok then Log("  zcity: weapon_melee PlayEffects could not be run here (%s)", tostring(err)) end
	end
	if not done then
		util.Decal("Blood", pos - dir * 15, pos + dir * 15, host)
		util.Decal("Blood", pos - dir * 2, host:GetPos(), Z.GetBody(bot))
	end
	Log("  zcity: melee hit effects %s", done and "through Z-City's weapon_melee PlayEffects" or "as the two decal calls that method makes")
end

-- (an artery: Z-City's blood volume falls fast enough to be compared in 20 s)
local function Wound3(bot)
	ABL.DevAddWound(bot, "neck", 6, true, 3, 0.5, 0.5)
end

-- The head of a body that already lies there comes off (the burst reaches every client then).
local function HeadOffCorpse(bot, label)
	if not (hg and isfunction(hg.ExplodeHead)) then return end
	bot:Kill()
	Wait(2.5)
	local corpse = bot:GetNWEntity("RagdollDeath")
	if not IsValid(corpse) then Log("  zcity %s: no corpse", label) return end
	hg.ExplodeHead(corpse)
	Wait(1)
	ZC(label .. "_1s", bot)
	Wait(5)
	ZC(label .. "_6s", bot)
	Log("  zcity %s: headless body %s, fountain kept by Z-City %s, neck told to clients %s", label, tostring(corpse),
		tostring(istable(hg.fountains) and hg.fountains[corpse] ~= nil), tostring(corpse:GetNW2Vector("ABL_Neck", vector_origin)))
	Client("zcsources", { name = label })
	Client("streamstat", { ent = corpse:EntIndex(), name = label .. "_neck_6s" })
	Wait(10)
	ZC(label .. "_16s", bot)
	Client("streamstat", { ent = corpse:EntIndex(), name = label .. "_neck_16s" })
end

ST.Add("hostile_zcity", function()
	local host = ST.Host()
	-- (the switches this scene turns, where they belong: an earlier run may have ended half way)
	RunConsoleCommand("abl_enabled", "1")
	RunConsoleCommand("abl_zcity_hitdecals", "0")
	ClientCvar("abl_zcity_takeover", 1)
	local p = FindSpot({ open = 220, outdoor = true })
	View(p + Vector(0, -200, 95), p + Vector(0, 0, 35))
	Wait(1)
	Log("  zcity: signs on the server: %s", (function()
		local t = {}
		for _, sg in ipairs(Z.Signals()) do t[#t + 1] = (sg[2] and "+" or "-") .. sg[1] end
		return table.concat(t, " ")
	end)())
	Base("Z0_empty", "zc")
	Client("zcstatus", { name = "Z0" })
	ZC("Z0_start", nil)

	-- A: the takeover on (the default) -------------------------------------------------------
	local a = Bleeder(p + Vector(-80, 0, 0))
	Wait(2.5)
	-- a small wound: a cut
	local pos, dir = Cut(host, a, 18)
	MeleeEffects(host, a, pos, dir)
	Wait(4)
	ZC("ZA1_cut_4s", a)
	Client("zcsources", { name = "ZA1_cut" })
	Shot("hZ_a1_cut")
	-- a gunshot
	ABL.DevShoot(host, a, 15, "front", "chest", "9x19mmparabellum")
	Wait(4)
	ZC("ZA2_gunshot_4s", a)
	Client("zcsources", { name = "ZA2_gunshot" })
	-- several wounds
	ABL.DevShoot(host, a, 12, "right", "rupperarm", "9x19mmparabellum")
	Wait(0.6)
	ABL.DevShoot(host, a, 12, "front", "lthigh", "9x19mmparabellum")
	Wait(0.6)
	Cut(host, a, 14)
	Wait(4)
	ZC("ZA3_several_wounds_4s", a)
	Client("zcsources", { name = "ZA3_several" })
	Shot("hZ_a3_several")
	-- bleeding for a while: Z-City's blood volume must go on falling, ABL must go on bleeding
	for k = 1, 3 do
		Wait(10)
		ZC("ZA4_bleeding_" .. (k * 10) .. "s", a)
	end
	Client("streamstat", { ent = a:EntIndex(), name = "ZA4_bleeding_30s" })
	-- ragdolled
	Fake(a)
	Wait(4)
	ZC("ZA5_ragdolled_4s", a)
	Client("zcsources", { name = "ZA5_ragdolled" })
	-- killed: rifle shots into the head (brain hits ask for the engine's blood puff)
	for k = 1, 3 do
		if IsValid(a) and a:Alive() then ABL.DevShoot(host, a, nil, k % 2 == 0 and "left" or "front", "head", "7.62x51mm", 40) end
		Wait(0.5)
	end
	if IsValid(a) and a:Alive() then a:Kill() end
	Wait(5)
	ZC("ZA6_dead_5s", a)
	Client("zcsources", { name = "ZA6_dead" })
	Shot("hZ_a6_dead")

	-- a head comes off (Z-City: hg.ExplodeHead; a burst, meat that lands, a fountain at the neck)
	local b = Bleeder(p + Vector(0, 0, 0))
	Wait(2.5)
	if hg and isfunction(hg.ExplodeHead) then
		hg.ExplodeHead(b)
		Wait(1)
		ZC("ZA7_head_off_1s", b)
		Shot("hZ_a7_head_1s")
		Wait(5)
		ZC("ZA7_head_off_6s", b)
		local corpse = IsValid(b) and b:GetNWEntity("RagdollDeath") or NULL
		Log("  zcity: headless body %s, fountain kept by Z-City %s, neck told to clients %s", tostring(corpse),
			tostring(IsValid(corpse) and istable(hg.fountains) and hg.fountains[corpse] ~= nil), tostring(IsValid(corpse) and corpse:GetNW2Vector("ABL_Neck", vector_origin)))
		Client("zcsources", { name = "ZA7_head_off" })
		if IsValid(corpse) then Client("streamstat", { ent = corpse:EntIndex(), name = "ZA7_neck_6s" }) end
		Wait(10)
		ZC("ZA7_head_off_16s", b)
		if IsValid(corpse) then Client("streamstat", { ent = corpse:EntIndex(), name = "ZA7_neck_16s" }) end
		Shot("hZ_a7_head_16s")
	else
		Log("  zcity: this Z-City has no hg.ExplodeHead")
	end

	-- and the head of a body that already lies there
	local b2 = Bleeder(p + Vector(40, 60, 0))
	Wait(2.5)
	HeadOffCorpse(b2, "ZA7b_corpse_head_off")
	Shot("hZ_a7b_corpse_head")

	-- a leg comes off (Z-City: hg.organism.AmputateLimb; a burst, an arterial wound and five more)
	local c = Bleeder(p + Vector(80, 0, 0))
	Wait(2.5)
	if hg and hg.organism and isfunction(hg.organism.AmputateLimb) and istable(c.organism) then
		local ok, err = pcall(hg.organism.AmputateLimb, c.organism, "rleg")
		if not ok then Log("  zcity: AmputateLimb raised %s", tostring(err)) end
		Wait(1)
		ZC("ZA8_leg_off_1s", c)
		Wait(6)
		ZC("ZA8_leg_off_7s", c)
		Client("zcsources", { name = "ZA8_leg_off" })
		Shot("hZ_a8_leg")
	else
		Log("  zcity: this Z-City has no hg.organism.AmputateLimb")
	end

	-- an NPC: a wound put into Z-City's list with no hit (no abl_hit reaches the client), then a shot
	local npc = ents.Create("npc_citizen")
	if IsValid(npc) then
		npc:SetPos(p + Vector(-40, 70, 4))
		npc:SetAngles(Angle(0, -90, 0))
		npc:Spawn()
		npc:Activate()
		Wait(2)
		local hasOrg = istable(npc.organism)
		local ok, res, msg = pcall(ABL.DevAddWound, npc, "chest", 3, false, 3, 0.55, 0.5)
		Log("  zcity: NPC %s, Z-City organism %s, wound added by hand: %s %s", tostring(npc), tostring(hasOrg), tostring(ok and res ~= false), tostring(ok and msg or res))
		Wait(4)
		ZC("ZA8n_npc_wound_4s", npc)
		Client("zcsources", { name = "ZA8n_npc_wound" })
		local aim = ABL.DevHitboxCenter(npc, "chest") or (npc:GetPos() + Vector(0, 0, 48))
		pcall(ABL.DevShootAt, host, aim, Vector(0, -1, 0), 15, 80, "9x19mmparabellum")
		Wait(4)
		ZC("ZA8n_npc_shot_4s", npc)
		Client("zcsources", { name = "ZA8n_npc_shot" })
		Shot("hZ_a8n_npc")
		if IsValid(npc) then npc:Remove() end
		Wait(1)
	end

	-- Z-City's own blood messages, as its server sends them
	if util.NetworkStringToID("hg_bloodimpact") ~= 0 then
		for _ = 1, 5 do
			net.Start("hg_bloodimpact")
			net.WriteVector(p + Vector(120, 0, 50))
			net.WriteVector(Vector(0, 1, 0) / 15)
			net.WriteFloat(3)
			net.WriteInt(4, 8)
			net.Send(host)
		end
	end
	if hg and hg.organism and isfunction(hg.organism.Vomit) and IsValid(c) and c:Alive() then pcall(hg.organism.Vomit, c) end
	Wait(3)
	ZC("ZA9_zcity_messages_3s", c)
	Check("ZA_end", "zc")
	Client("zcstatus", { name = "ZA_end" })
	Wait(0.5)

	-- B: the takeover off, the server's part off (Z-City's own blood runs: the probes must see it,
	-- and the physiology must be what it was) ---------------------------------------------------
	for _, e in ipairs(player.GetBots()) do e:Kick("ABL hostile: next part") end
	Wait(0.5)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Client("clear", {})
	Wait(2)
	-- the same wound under three settings: what Z-City's blood volume does in 20 s
	local function Loss(label)
		local bot = Bleeder(p + Vector(-80, 60, 0))
		Wait(2.5)
		local b0 = tonumber(bot.organism and bot.organism.blood) or 0
		Wound3(bot)
		Wait(20)
		local b1 = tonumber(bot.organism and bot.organism.blood) or 0
		Log("  zcity physiology %s: blood %.1f -> %.1f ml in 20 s (lost %.1f), bleed %.3f, pulse %.0f, wounds %d", label, b0, b1, b0 - b1,
			tonumber(bot.organism and bot.organism.bleed) or -1, tonumber(bot.organism and bot.organism.pulse) or -1,
			istable(bot.organism and bot.organism.wounds) and #bot.organism.wounds or 0)
		ZC("ZB_" .. label, bot)
		bot:Kick("ABL hostile: measured")
		Wait(0.5)
		for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
		Wait(1)
	end
	Loss("takeover_on")
	ClientCvar("abl_zcity_takeover", 0)
	RunConsoleCommand("abl_zcity_hitdecals", "1")
	Wait(1)
	Client("zcstatus", { name = "ZB_off" })
	Loss("takeover_off")
	-- the same injuries as in A, Z-City's blood allowed
	local d = Bleeder(p + Vector(-80, 0, 0))
	Wait(2.5)
	pos, dir = Cut(host, d, 18)
	MeleeEffects(host, d, pos, dir)
	Wait(1)
	ABL.DevShoot(host, d, 15, "front", "chest", "9x19mmparabellum")
	Wait(4)
	ZC("ZB1_cut_and_gunshot_5s", d)
	Shot("hZ_b1_both_systems")
	Wait(8)
	ZC("ZB2_bleeding_13s", d)
	HeadOffCorpse(d, "ZB3_corpse_head_off")
	Shot("hZ_b3_head_both_systems")
	-- AdvancedBlood off altogether: Z-City as it is without the addon
	RunConsoleCommand("abl_enabled", "0")
	Wait(1.5)
	Loss("abl_disabled")
	local e2 = Bleeder(p + Vector(80, 0, 0))
	Wait(2.5)
	pos, dir = Cut(host, e2, 18)
	MeleeEffects(host, e2, pos, dir)
	ABL.DevShoot(host, e2, 15, "front", "chest", "9x19mmparabellum")
	Wait(6)
	ZC("ZB4_abl_disabled_6s", e2)
	Client("zcstatus", { name = "ZB_disabled" })
	-- and back: on again, the takeover on again; what Z-City had in the air is gone at once
	RunConsoleCommand("abl_enabled", "1")
	RunConsoleCommand("abl_zcity_hitdecals", "0")
	ClientCvar("abl_zcity_takeover", 1)
	Wait(1)
	ZC("ZC1_on_again_1s", e2)
	Wait(6)
	ZC("ZC1_on_again_7s", e2)
	Client("zcsources", { name = "ZC1_on_again" })
	-- the map is cleaned up (Z-City replaces its particle lists)
	game.CleanUpMap()
	Wait(3)
	local f = Bleeder(p + Vector(0, 0, 0))
	Wait(2.5)
	Cut(host, f, 18)
	ABL.DevShoot(host, f, 15, "front", "chest", "9x19mmparabellum")
	Wait(5)
	ZC("ZC2_after_cleanup_5s", f)
	Check("ZC_end", "zc")
	Client("zcstatus", { name = "ZC_end" })
	Client("wrapstate", { name = "ZC_end" })
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- The first seconds of a wound
------------------------------------------------------------------------------------------
-- One wound on a fresh character, watched from close by; the client samples every frame
-- (cl_hostile.lua, H.onset) and writes the windows when the time is up. o.act makes the wound.
local function OnsetCase(p, name, o)
	for _, e in ipairs(player.GetBots()) do e:Kick("ABL onset: next case") end
	Wait(0.4)
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
	Client("clear", {})
	Wait(1.2)
	local bot = Bleeder(p, -90, o.model)
	if not IsValid(bot) then Log("  onset %s: no bot", name) return end
	Wait(2.5)
	local at = ABL.DevHitboxCenter(Z.GetBody(bot), o.aim or "chest") or (bot:GetPos() + Vector(0, 0, 50))
	local off = Vector(o.side or 22, -(o.back or 46), o.up or 4)
	View(at + off, at - Vector(0, 0, o.down or 6))
	Wait(0.6)
	if o.burn then Client("burn", { ms = o.burn }) Wait(0.8) end
	Client("onset", { ent = bot:EntIndex(), name = name, dur = o.dur or 3, shots = o.shots == true,
		bone = o.shots == true and (o.bone or "ValveBiped.Bip01_Spine2") or nil, off = off, down = o.down or 6 })
	Wait(0.25)
	o.act(bot)
	if o.during then o.during(bot, at) else Wait((o.wait or o.dur or 3) + 0.6) end
	if o.burn then Client("burn", { ms = 0 }) Wait(0.3) end
	Client("streamstat", { ent = bot:EntIndex(), name = "O_" .. name })
	Client("scan", { name = "O_" .. name })
	Wait(0.3)
	return bot
end

ST.Add("onset", function()
	local host = ST.Host()
	local p = FindSpot({ open = 200, outdoor = true })
	-- a pistol bullet into the chest (Z-City's most common wound)
	OnsetCase(p, "pistol_chest", { act = function(bot) ABL.DevShoot(host, bot, 20, "front", "chest", "9x19mmparabellum") end })
	-- a rifle bullet through the chest: entry and exit
	OnsetCase(p, "rifle_chest", { act = function(bot) ABL.DevShoot(host, bot, nil, "front", "chest", "7.62x51mm", 60) end })
	-- a rifle bullet through the thigh, seen from the side the bullet leaves by
	OnsetCase(p, "rifle_thigh", { aim = "lthigh", act = function(bot) ABL.DevShoot(host, bot, nil, "front", "lthigh", "7.62x51mm", 60) end })
	-- a cut
	OnsetCase(p, "cut_chest", { act = function(bot) Cut(host, bot, 18) end })
	-- a small wound with no hit behind it (a wound value of 1)
	OnsetCase(p, "small_wound", { act = function(bot) ABL.DevAddWound(bot, "chest", 1, false, 3, 0.55, 0.5) Hold(bot, 10) end })
	-- a moderate wound with no hit behind it
	OnsetCase(p, "moderate_wound", { act = function(bot) ABL.DevAddWound(bot, "chest", 4, false, 3, 0.55, 0.5) Hold(bot, 10) end })
	-- an artery in the neck
	OnsetCase(p, "artery_neck", { aim = "neck", back = 60, act = function(bot) ABL.DevAddWound(bot, "neck", 6, true, 3, 0.5, 0.5) end })
	-- a wound that is closed again after two seconds (bandaged): how the flow ends
	OnsetCase(p, "closed_after_2s", { dur = 5, act = function(bot)
		ABL.DevAddWound(bot, "chest", 6, false, 3, 0.55, 0.5)
		Hold(bot, 1.9)
		timer.Simple(2, function() if IsValid(bot) then ABL.DevHeal(bot) end end)
	end })
	-- death in the middle of a bleed (the heart stops: the pressure goes)
	OnsetCase(p, "killed_after_2s", { dur = 5, act = function(bot)
		ABL.DevAddWound(bot, "chest", 6, false, 3, 0.55, 0.5)
		Hold(bot, 1.9)
		timer.Simple(2, function() if IsValid(bot) then bot:Kill() end end)
	end })
	-- a second, heavy wound on a body that already bleeds a little
	OnsetCase(p, "second_wound", { dur = 5, wait = 7, act = function(bot)
		ABL.DevAddWound(bot, "chest", 2, false, 3, 0.55, 0.5)
		timer.Simple(2, function() if IsValid(bot) then ABL.DevShoot(host, bot, nil, "front", "lthigh", "7.62x51mm", 60) end end)
	end })
	-- the same to look at: screenshots 30, 100, 250, 500, 1000 and 2000 ms after the event, the
	-- camera on the wounded part wherever the body goes
	OnsetCase(p, "look_pistol_chest", { shots = true, act = function(bot) ABL.DevShoot(host, bot, 20, "front", "chest", "9x19mmparabellum") end })
	OnsetCase(p, "look_rifle_thigh", { shots = true, aim = "lthigh", bone = "ValveBiped.Bip01_L_Thigh", back = 52, act = function(bot) ABL.DevShoot(host, bot, nil, "front", "lthigh", "7.62x51mm", 60) end })
	OnsetCase(p, "look_cut_chest", { shots = true, act = function(bot) Cut(host, bot, 18) end })
	OnsetCase(p, "look_artery_neck", { shots = true, aim = "neck", bone = "ValveBiped.Bip01_Neck1", back = 60, act = function(bot) ABL.DevAddWound(bot, "neck", 6, true, 3, 0.5, 0.5) end })
end)

ST.Add("onset_rates", function()
	local p = FindSpot({ open = 200, outdoor = true })
	-- (large enough to bleed steadily, held at its value: a smaller one clots and opens again at
	-- random, and two runs at the same settings differ by more than any setting does)
	local function Wound(bot)
		ABL.DevAddWound(bot, "chest", 16, false, 3, 0.55, 0.5)
		Hold(bot, 14)
	end
	-- (one model for all of them: where a stream runs and where it ends is the body's shape)
	local M = "models/zcity/m/male_06.mdl"
	-- (the first case of a session runs slower whatever is done in it: one that does not count)
	OnsetCase(p, "rate_warmup", { dur = 4, model = M, act = Wound })
	OnsetCase(p, "rate_natural", { dur = 4, model = M, act = Wound })
	OnsetCase(p, "rate_natural_again", { dur = 4, model = M, act = Wound })
	OnsetCase(p, "rate_20fps", { dur = 4, model = M, burn = 42, act = Wound })
	OnsetCase(p, "rate_10fps", { dur = 4, model = M, burn = 92, act = Wound })
	OnsetCase(p, "rate_5fps", { dur = 4, model = M, burn = 192, act = Wound })
	-- a stall of a second and a half, 0.3 s after the wound opens (a hitch, the game in the
	-- background for a moment)
	OnsetCase(p, "stall_at_300ms", { dur = 5, model = M, act = function(bot)
		Wound(bot)
		timer.Simple(0.3, function() Client("burn", { once = 1500 }) end)
	end })
	-- the same wound from three distances (other levels of detail)
	OnsetCase(p, "dist_60", { dur = 8, model = M, back = 60, act = Wound })
	OnsetCase(p, "dist_60_again", { dur = 8, model = M, back = 60, act = Wound })
	OnsetCase(p, "dist_500", { dur = 8, model = M, back = 500, up = 60, act = Wound })
	OnsetCase(p, "dist_500_again", { dur = 8, model = M, back = 500, up = 60, act = Wound })
	OnsetCase(p, "dist_1500", { dur = 8, model = M, back = 1500, up = 200, act = Wound })
	-- ... and the camera going from near to far and back while it bleeds: nothing may jump
	OnsetCase(p, "dist_changes", { dur = 10, model = M, back = 60, act = Wound, during = function(bot, at)
		local ent = bot:EntIndex()
		Wait(3)
		Client("streamstat", { ent = ent, name = "D_near_3s" })
		View(at + Vector(22, -900, 120), at)
		Wait(0.4)
		Client("streamstat", { ent = ent, name = "D_far_0.4s_later" })
		Wait(2.6)
		Client("streamstat", { ent = ent, name = "D_far_3s_later" })
		View(at + Vector(22, -60, 4), at)
		Wait(0.4)
		Client("streamstat", { ent = ent, name = "D_near_again_0.4s_later" })
		Wait(4.2)
	end })
end)

------------------------------------------------------------------------------------------
-- Churn: a wound opens, bleeds for a moment, is closed; every tenth time the character is
-- kicked and its body removed. 240 wounds on 24 characters in all. What the blood system keeps
-- alive is counted against the empty map before, every 60 wounds, and when all is cleared.
------------------------------------------------------------------------------------------
ST.Add("hostile_churn", function()
	local host = ST.Host()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(0, -220, 110), p + Vector(0, 0, 30))
	for _, e in ipairs(player.GetBots()) do e:Kick("ABL churn") end
	Wait(0.5)
	Client("clear", {})
	Wait(2)
	Base("K0_empty", "churn")
	local bones = { "chest", "lthigh", "rupperarm", "neck", "pelvis", "head" }
	local bot
	local n = 0
	for round = 1, 24 do
		bot = Bleeder(p + Vector(((round - 1) % 4 - 1.5) * 50, 0, 0), -90)
		if not IsValid(bot) then Log("  churn: no bot in round %d", round) break end
		Wait(1.2)
		for k = 1, 10 do
			n = n + 1
			local bone = bones[(n - 1) % #bones + 1]
			if k % 5 == 0 then
				-- (every fifth wound is a real shot: a record, marks, a burst)
				ABL.DevShoot(host, bot, 8, "front", bone == "head" and "chest" or bone, "9x19mmparabellum")
			else
				ABL.DevAddWound(bot, bone, 2 + (n % 4), n % 7 == 0, 3, 0.5, 0.5)
			end
			Wait(0.45)
			if IsValid(bot) and bot:Alive() then ABL.DevHeal(bot) end
			Wait(0.15)
		end
		if IsValid(bot) then bot:Kick("ABL churn: next") end
		Wait(0.2)
		for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do r:Remove() end
		if round % 6 == 0 then
			Wait(1.5)
			Check(string.format("K%d_after_%d_wounds", round / 6, n), "churn")
		end
	end
	Client("clear", {})
	Wait(4)
	Check("K9_cleared", "churn")
	Client("clear", {})
	Wait(3)
	Check("K9_cleared_again", "churn")
end)
