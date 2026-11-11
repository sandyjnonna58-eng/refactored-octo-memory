-- Scenes of the blood film (developer tool; only with the test harness, see sv_selftest.lua). They
-- run only when asked for by name.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

------------------------------------------------------------------------------------------
-- The film in the game. One case a scene: a character with wounds, photographed at set times from
-- where its film faces, with the film's own numbers in the log (cl_filmtest.lua, H.filmstats).
------------------------------------------------------------------------------------------
local MODEL = "models/zcity/m/male_06.mdl"

local function FStats(name)
	Client("filmstats", { name = name })
	Wait(0.1)
end

-- Z-City closes a small wound within seconds. A case of a wound that goes on bleeding keeps the
-- wound values where they were set (as sv_flowtest.lua does).
local function Hold(bot, seconds)
	local org = bot.organism
	if not istable(org) or not istable(org.wounds) or not org.wounds[1] then return end
	local values = {}
	for i, w in ipairs(org.wounds) do values[i] = w[1] end
	local name = "ABL_FilmHold" .. bot:EntIndex()
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
	Log("  %d wound value(s) held for %d s (first %.3f)", #values, seconds, values[1])
end

local function Fake(bot)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	return ABL.DevRagdollOf(bot)
end

local function Bot(p, yaw, model)
	local bot = NewBot()
	Place(bot, p, yaw or 0)
	-- (light clothes, where the engine lets them be chosen: blood reads best on them)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel(model or MODEL)
	return bot
end

local function Wound(bot, w)
	local ok, err = ABL.DevAddWound(bot, w.bone or "chest", w.amount or 0.6, w.arterial or false, w.side or 3, w.f1 or 0.55, w.f2 or 0.5)
	Log("  wound on %s of %s, amount %.2f: %s %s", w.bone or "chest", bot:Nick(), w.amount or 0.6, tostring(ok), tostring(err or ""))
end

-- The film of one character from where it faces, and the same picture's numbers.
local function Photo(bot, name, o)
	o = o or {}
	Client("filmcam", { ent = bot:EntIndex(), min = o.min, max = o.max, dist = o.dist, pad = o.pad })
	Wait(0.3)
	Shot(name)
end

-- A character with wounds, watched for a while.
--   o.wounds: { { bone =, amount =, side =, f1 =, f2 =, arterial = }, ... } (one on the chest when left out)
--   o.hold: seconds the wound values are kept; o.model; o.pose: lying so before it is wounded
--   o.turnAt / o.turnTo: laid down another way at that time; o.healAt: the wounds close at that time
--   o.dryAfter = { at seconds, scale }: abl_drying_scale from then on (what has stopped is seen drying)
--   o.figureAt[seconds], o.floorAt[seconds], o.lowAt[seconds], o.backAt[seconds]: more pictures at those times
local function Case(name, o, times)
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 0, o.model)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	-- (the surface model of its body and the film's chart are built over the first frames it is in view)
	Wait(3.5)
	Log("  %s: model %s", name, tostring(bot:GetModel()))
	local rag
	if o.pose then
		rag = Fake(bot)
		Wait(1)
		if IsValid(rag) then ABL.DevPose(rag, o.pose, o.freeze) end
		Wait(1.5)
	end
	for _, w in ipairs(o.wounds or { {} }) do Wound(bot, w) end
	if o.hold then Hold(bot, o.hold) end
	local t0 = CurTime()
	Wait(0.3)
	for _, tt in ipairs(times) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		if o.turnAt == tt then
			rag = rag or Fake(bot)
			if IsValid(rag) then ABL.DevPose(rag, o.turnTo or "back") end
			Log("  %s: laid on its %s", name, o.turnTo or "back")
			Wait(1.5)
		end
		if o.healAt == tt then
			timer.Remove("ABL_FilmHold" .. bot:EntIndex())
			ABL.DevHeal(bot)
			Log("  %s: wounds closed", name)
			Wait(0.6)
		end
		if o.dryAfter and o.dryAfter[1] == tt then RunConsoleCommand("abl_drying_scale", tostring(o.dryAfter[2])) end
		local tag = string.format("%s_%03ds", name, tt)
		Photo(bot, tag, o)
		if o.lowAt and o.lowAt[tt] then
			Client("filmcam", { ent = bot:EntIndex(), low = true, dist = o.lowDist or 16 })
			Wait(0.3)
			Shot(tag .. "_low")
		end
		if o.aroundAt and o.aroundAt[tt] then
			-- (round the lowest place blood has reached, from four sides: what hangs there and what
			-- falls from it is in some of them)
			for _, yaw in ipairs({ 0, 90, 180, 270 }) do
				Client("filmcam", { ent = bot:EntIndex(), low = true, drop = 5, dist = o.aroundDist or 24, yaw = yaw })
				Wait(0.3)
				Shot(string.format("%s_around%03d", tag, yaw))
				-- (and a second of frames from there: a drop that falls is in a few of them in a row)
				if yaw % 180 == 0 then
					Client("poolburst", { name = string.format("%s_fall%03d", tag, yaw), frames = 24, every = 2, x = 480, y = 180, w = 960, h = 720, quality = 88 })
					Wait(1.3)
				end
			end
		end
		if o.macroAt and o.macroAt[tt] then
			Client("filmcam", { ent = bot:EntIndex(), dist = 9, side = 0.5 })
			Wait(0.3)
			Shot(tag .. "_macro")
			-- (the same without the light's highlight on what is wet)
			Client("cvar", { name = "abl_film_gloss", value = "0" })
			Wait(0.3)
			Shot(tag .. "_macro_nogloss")
			Client("cvar", { name = "abl_film_gloss", value = "1" })
			Wait(0.1)
		end
		if o.backAt and o.backAt[tt] then
			View(p + Vector(-58, 20, 52), p + Vector(0, 0, 42))
			Wait(0.4)
			Shot(tag .. "_back")
		end
		if o.figureAt and o.figureAt[tt] then
			local c = IsValid(rag) and rag:WorldSpaceCenter() or (p + Vector(0, 0, 36))
			if IsValid(rag) then View(c + Vector(46, -30, 52), c) else View(p + Vector(64, -30, 44), p + Vector(0, 0, 34)) end
			Wait(0.4)
			Shot(tag .. "_figure")
		end
		if o.floorAt and o.floorAt[tt] then
			local c = IsValid(rag) and rag:WorldSpaceCenter() or p
			View(Vector(c.x + 36, c.y - 22, p.z + 24), Vector(c.x + 3, c.y, p.z + 1))
			Wait(0.4)
			Shot(tag .. "_floor")
		end
		FStats(tag)
	end
	Client("stats", { name = name })
	Wait(0.2)
	if o.dryAfter then RunConsoleCommand("abl_drying_scale", "1") end
	return bot, p
end

-- How the film is drawn, on one film that is there: a few values of its highlight and of how
-- uneven its surface is, with the character turned four ways (one of them has the sun on the
-- wound), from close by. What this build of the game makes of each is in the pictures.
ST.Add("film_look", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(bot, { amount = 2.5 })
	Hold(bot, 80)
	Wait(22)
	local ent = bot:EntIndex()
	local KF = ABL.Config.Film
	local glint, relief = KF.glint, KF.relief
	local variants = {
		{ name = "1_default" },
		{ name = "2_broad", phong = { 8, KF.phongBoost } },
		{ name = "3_strong", phong = { KF.phongExp, KF.phongBoost * 4 } },
		{ name = "4_even", phong = { KF.phongExp, KF.phongBoost }, k = { glint = 0, relief = 0 } },
	}
	for _, v in ipairs(variants) do
		Client("filmlook", v)
		Wait(1.2)
		for _, yaw in ipairs({ 0, 90, 180, 270 }) do
			bot:SetEyeAngles(Angle(0, yaw, 0))
			bot:SetAngles(Angle(0, yaw, 0))
			Wait(0.9)
			Client("filmcam", { ent = ent, dist = 13, side = 0.35 })
			Wait(0.3)
			Shot(string.format("k%s_yaw%03d", v.name, yaw))
		end
	end
	Client("filmlook", { name = "back to the first", phong = { KF.phongExp, KF.phongBoost }, k = { glint = glint, relief = relief } })
	bot:SetEyeAngles(Angle(0, 0, 0))
	bot:SetAngles(Angle(0, 0, 0))
	Wait(1)
	View(p + Vector(64, -30, 44), p + Vector(0, 0, 34))
	Wait(0.4)
	Shot("k_figure")
	FStats("k_look")
end)

-- The highlight where it is at its worst: a body on its back with the sun on its wet chest, seen
-- from where the film is photographed and from where the sun is mirrored in it. As it is set; with
-- a level sheet of liquid shining as much as its rims and ridges do, some, and not at all; stronger;
-- lumpier; wide, as the engine's highlight comes; and with none.
ST.Add("film_shine", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	local rag = Fake(bot)
	Wait(1)
	if IsValid(rag) then ABL.DevPose(rag, "back") end
	Wait(1.5)
	Wound(bot, { amount = 1.2 })
	Hold(bot, 70)
	Wait(30)
	local KF = ABL.Config.Film
	local e0, b0, flat, glint = KF.phongExp, KF.phongBoost, KF.flatShine, KF.glint
	local variants = {
		{ name = "1_as_set", phong = { e0, b0 } },
		{ name = "2_level_shines", phong = { e0, b0 }, k = { flatShine = 1 } },
		{ name = "3_level_some", phong = { e0, b0 }, k = { flatShine = 0.35 } },
		{ name = "4_level_none", phong = { e0, b0 }, k = { flatShine = 0 } },
		{ name = "5_strong", phong = { e0, b0 * 1.7 } },
		{ name = "6_lumpy", phong = { e0, b0 }, k = { glint = glint * 2 } },
		{ name = "7_wide", phong = { 28, b0 }, k = { flatShine = 1 } },
	}
	local ent = bot:EntIndex()
	local function Two(name)
		Client("filmcam", { ent = ent })
		Wait(0.3)
		Shot("s" .. name)
		Client("filmcam", { ent = ent, sun = true })
		Wait(0.3)
		Shot("s" .. name .. "_sun")
	end
	for _, v in ipairs(variants) do
		v.k = v.k or {}
		if v.k.flatShine == nil then v.k.flatShine = flat end
		if v.k.glint == nil then v.k.glint = glint end
		Client("filmlook", v)
		Wait(1.2)
		Two(v.name)
	end
	Client("filmlook", { name = "back to what is set", phong = { e0, b0 }, k = { flatShine = flat, glint = glint } })
	Wait(0.6)
	Client("cvar", { name = "abl_film_gloss", value = "0" })
	Wait(0.4)
	Two("8_no_highlight")
	Client("cvar", { name = "abl_film_gloss", value = "1" })
	Wait(0.2)
	FStats("s_shine")
end)

-- What this build of the game makes of a material: the film of a wound on cloth and of one on bare
-- skin, drawn by a few recipes (cl_filmdraw.lua, D.Try), from close by and from some way off.
ST.Add("film_try", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local a, b = Bot(p + Vector(0, -17, 0), 0), Bot(p + Vector(0, 17, 0), 0)
	View(p + Vector(56, 0, 50), p + Vector(0, 0, 42))
	Wait(3.5)
	Wound(a, { amount = 1.5 })
	Wound(b, { bone = "head", amount = 0.5, side = 4, f1 = 0.72, f2 = 0.5 })
	Hold(a, 110)
	Hold(b, 110)
	Wait(18)
	local list = {
		{ "0_lit", "lit" }, { "1_lit_detail", "lit_detail" }, { "2_stain_bump", "stain_bump" }, { "3_stain_bump_nodetail", "stain_bump_nodetail" },
		{ "4_stain_plain", "stain_plain" }, { "5_stain_phong", "stain_phong" }, { "6_stain_bump_fringe", "stain_bump", "fringe" },
		{ "7_lit_env", "lit_env" }, { "8_lit_rim", "lit_rim" }, { "9_lit_detail8", "lit_detail8" },
	}
	local ea, eb = a:EntIndex(), b:EntIndex()
	for _, v in ipairs(list) do
		Client("filmtry", { preset = v[2], under = v[3] })
		Wait(0.7)
		Client("filmcam", { ent = ea, dist = 15, side = 0.3 })
		Wait(0.3)
		Shot("t" .. v[1] .. "_cloth")
		Client("filmcam", { ent = ea, dist = 42, side = 0.3 })
		Wait(0.3)
		Shot("t" .. v[1] .. "_cloth_mid")
		Client("filmcam", { ent = eb, dist = 13 })
		Wait(0.3)
		Shot("t" .. v[1] .. "_skin")
	end
	Client("filmtry", {})
	Wait(0.5)
	FStats("t_try")
end)

-- The film as it is drawn now and as it was drawn before (one layer), the same blood at the same
-- moment: a wound on cloth and one on bare skin, from close by, from some way off and from far;
-- a second of frames of the running blood from close by; and the first body turned four ways (a
-- body's front follows the way it is told to look only roughly: one of the four has the sun on
-- the blood, one has it grazing, the others are in the body's own shade. Which is which is in
-- the log: where the film faces.)
ST.Add("film_ab", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local a, b = Bot(p + Vector(0, -17, 0), 0), Bot(p + Vector(0, 17, 0), 0)
	View(p + Vector(56, 0, 50), p + Vector(0, 0, 42))
	Wait(3.5)
	Wound(a, { amount = 1.5 })
	Wound(b, { bone = "head", amount = 0.5, side = 4, f1 = 0.72, f2 = 0.5 })
	Hold(a, 110)
	Hold(b, 110)
	local ea, eb = a:EntIndex(), b:EntIndex()
	-- (the same pictures of both ways of drawing, one after the other)
	local function Pair(tag, skin)
		for _, mode in ipairs({ 1, 0 }) do
			Client("filmlook", { name = mode == 1 and "two layers" or "one layer, as before", k = { material = mode } })
			Wait(1.4)
			local name = tag .. (mode == 1 and "_new" or "_old")
			Client("filmcam", { ent = ea, dist = 15, side = 0.3, sun = "say" })
			Wait(0.3)
			Shot(name .. "_cloth")
			Client("filmcam", { ent = ea, dist = 40, side = 0.3 })
			Wait(0.3)
			Shot(name .. "_cloth_mid")
			if skin then
				Client("filmcam", { ent = eb, dist = 13 })
				Wait(0.3)
				Shot(name .. "_skin")
			end
		end
		Client("filmlook", { name = "two layers", k = { material = 1 } })
		Wait(1.4)
	end
	local t0 = CurTime()
	for _, tt in ipairs({ 7, 22, 42 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Pair(string.format("ab_%02ds", tt), true)
		if tt == 22 then
			Client("filmcam", { ent = ea, dist = 15, side = 0.3 })
			Wait(0.4)
			Client("poolburst", { name = "ab_run", frames = 16, every = 2, x = 480, y = 90, w = 960, h = 900, quality = 90 })
			Wait(2.2)
		end
		FStats(string.format("ab_%02ds", tt))
	end
	for _, yaw in ipairs({ 90, 180, 270 }) do
		a:SetEyeAngles(Angle(0, yaw, 0))
		a:SetAngles(Angle(0, yaw, 0))
		Wait(1.2)
		Pair(string.format("ab_yaw%03d", yaw), false)
		-- (and from where the sun is mirrored in the blood, if there is such a place: both ways)
		for _, mode in ipairs({ 1, 0 }) do
			Client("filmlook", { name = mode == 1 and "two layers" or "one layer, as before", k = { material = mode } })
			Wait(1.4)
			Client("filmcam", { ent = ea, dist = 15, sun = true })
			Wait(0.3)
			Shot(string.format("ab_yaw%03d_%s_mirror", yaw, mode == 1 and "new" or "old"))
		end
		Client("filmlook", { name = "two layers", k = { material = 1 } })
		Wait(1.2)
	end
	View(p + Vector(150, 0, 54), p + Vector(0, 0, 40))
	for _, mode in ipairs({ 1, 0 }) do
		Client("filmlook", { name = mode == 1 and "two layers" or "one layer, as before", k = { material = mode } })
		Wait(1.4)
		View(p + Vector(150, 0, 54), p + Vector(0, 0, 40))
		Wait(0.4)
		Shot("ab_far_" .. (mode == 1 and "new" or "old"))
	end
	Client("filmlook", { name = "two layers", k = { material = 1 } })
	Wait(0.5)
	FStats("ab_end")
end)

-- A character's clothes by name (Z-City dresses its characters by chance): the material of the
-- part of the model that carries its upper clothes.
local function Dress(bot, material)
	for i, m in ipairs(bot:GetMaterials() or {}) do
		if string.find(string.lower(m), "players_sheet", 1, true) then
			bot:SetSubMaterial(i - 1, material)
			Log("  %s wears %s (slot %d)", bot:Nick(), material, i - 1)
			return true
		end
	end
	Log("  %s: no part for its upper clothes", bot:Nick())
	return false
end
local WHITE, BLACK, STRIPED = "models/humans/male/group01/sweater", "models/humans/male/group01/formal", "models/humans/female/group01/striped"

-- The two ways of drawing from one and the same place, switched from the console
-- (abl_film_layers): the camera is set once on a subject and stays there while the film is drawn
-- the new way, the old way and the new way again (what differs between the first and the third
-- picture is what the blood did meanwhile, and how the body swayed). The log says how the sun
-- stands to each film, and with o.stats, after each switch, which way the films are drawn.
--   o.phong = { { exponent, boost }, ... }: more pictures the new way, with the light's highlight
--   on the liquid that small and that bright
local function Pair(tag, cam, o)
	o = o or {}
	Client("cvar", { name = "abl_film_layers", value = "1" })
	Wait(0.3)
	Client("filmcam", cam)
	Wait(0.4)
	for i, v in ipairs({ "1", "0", "1" }) do
		Client("cvar", { name = "abl_film_layers", value = v })
		Wait(i == 1 and 0.3 or 2.0)
		local name = string.format("%s_%d_%s", tag, i, v == "1" and "new" or "old")
		Shot(name)
		if o.stats then FStats(name) end
	end
	if o.phong then
		local K = ABL.Config.Film
		for _, ph in ipairs(o.phong) do
			Client("filmlook", { name = string.format("highlight: exponent %d, boost %.1f", ph[1], ph[2]), phong = ph })
			Wait(1.8)
			Shot(string.format("%s_hl_%03d_%02d", tag, ph[1], math.floor(ph[2] * 10 + 0.5)))
		end
		Client("filmlook", { name = "highlight as set", phong = { K.phongExp, K.phongBoost } })
		Wait(1.6)
	end
end

-- (the host stands where the first view is taken from, and stays there while the camera goes round
-- the bodies: inside the open ground the spot was chosen for. Farther out it may stand behind a
-- corner, and bodies it cannot see are not sent to it: they have no film and are not drawn.)
local function PairsStart(name, p, subjects)
	local bots, e = {}, {}
	for i, sub in ipairs(subjects) do
		bots[i] = Bot(p + sub.at, 0, sub.model)
		if not IsValid(bots[i]) then Log("  %s: no bot for subject %d", name, i) return nil end
		e[i] = bots[i]:EntIndex()
	end
	View(p + Vector(-110, 70, 60), p + Vector(-20, 0, 36))
	Wait(3.5)
	for i, sub in ipairs(subjects) do
		Log("  subject %d: %s, model %s, in the host's sight: %s", i, bots[i]:Nick(), tostring(bots[i]:GetModel()), tostring(Entity(1):TestPVS(bots[i])))
		if sub.cloth then Dress(bots[i], sub.cloth) end
		if sub.pose then
			local rag = Fake(bots[i])
			Wait(1)
			if IsValid(rag) then ABL.DevPose(rag, sub.pose) end
			Wait(1.5)
		end
	end
	for i, sub in ipairs(subjects) do
		for _, w in ipairs(sub.wounds) do Wound(bots[i], w) end
		Hold(bots[i], 150)
	end
	return bots, e
end

-- Three bodies as they are put down, their fronts in their own shade: one in a white sweater
-- wounded on the back, where the sun falls, one in a black suit wounded on the chest, and one in a
-- striped sweater that lies on its back with the sun on its chest. Then the wounds close, and what
-- has run is photographed again when it has come to rest.
ST.Add("film_pairs", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local bots, e = PairsStart("film_pairs", p, {
		{ at = Vector(0, -30, 0), cloth = WHITE, wounds = { { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 } } },
		{ at = Vector(0, 30, 0), cloth = BLACK, wounds = { { amount = 1.5 } } },
		{ at = Vector(-90, 0, 0), cloth = STRIPED, wounds = { { amount = 1.2 } }, pose = "back" },
	})
	if not bots then return end
	Wait(24)
	local glints = { { 80, 1.0 }, { 50, 0.8 }, { 30, 0.6 } }
	Pair("p_sun", { ent = e[1], dist = 15, side = 0.3, sun = "say" }, { stats = true, phong = glints })
	Pair("p_sun_mid", { ent = e[1], dist = 40, side = 0.3 })
	Pair("p_shade", { ent = e[2], dist = 15, side = 0.3, sun = "say" })
	Pair("p_shade_mid", { ent = e[2], dist = 40, side = 0.3 })
	Pair("p_lying", { ent = e[3], dist = 22, sun = "say" }, { phong = glints })
	FStats("p_running")
	-- the wounds close: what has run comes to rest
	for i = 1, #bots do
		timer.Remove("ABL_FilmHold" .. e[i])
		ABL.DevHeal(bots[i])
	end
	Log("  film_pairs: wounds closed")
	Wait(16)
	Pair("p_lying_rest", { ent = e[3], dist = 22, sun = "say" })
	Client("cvar", { name = "abl_film_layers", value = "1" })
	Wait(2.0)
	View(p + Vector(-120, 110, 75), p + Vector(-20, 0, 30))
	Wait(0.5)
	Shot("p_all")
	FStats("p_end")
end)

-- The same on bare skin, of two characters: a wound on the brow and one on either side of the
-- head, photographed from the left (where the sun falls) and from the right.
ST.Add("film_pairs_skin", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local HEAD = "ValveBiped.Bip01_Head1"
	local head = {
		{ bone = "head", amount = 0.35, side = 4, f1 = 0.72, f2 = 0.5 },
		{ bone = "head", amount = 0.35, side = 5, f1 = 0.5, f2 = 0.3 },
		{ bone = "head", amount = 0.35, side = 6, f1 = 0.5, f2 = 0.3 },
	}
	local bots, e = PairsStart("film_pairs_skin", p, {
		{ at = Vector(0, -30, 0), wounds = head },
		{ at = Vector(0, 30, 0), wounds = head, model = "models/zcity/m/male_01.mdl" },
	})
	if not bots then return end
	Wait(20)
	Pair("s_a_left", { ent = e[1], bone = HEAD, lift = 2, yaw = 90, dist = 11 }, { stats = true })
	Pair("s_b_left", { ent = e[2], bone = HEAD, lift = 2, yaw = 90, dist = 11 })
	Pair("s_a_right", { ent = e[1], bone = HEAD, lift = 2, yaw = 270, dist = 11 })
	Pair("s_b_right", { ent = e[2], bone = HEAD, lift = 2, yaw = 270, dist = 11 })
	Client("cvar", { name = "abl_film_layers", value = "1" })
	Wait(2.0)
	FStats("s_end")
end)

-- How the two layers stand to each other in tone, under the sun and in a body's own shade: one
-- body wounded on the back (the sun falls there), one on the chest (its own shade), the camera set
-- once on each, and the film drawn with a few settings one after the other. (The bodies sway while
-- they stand: what compares from one picture to the next is how the liquid stands to the stain
-- round it in the same picture, tools/harness/profile.ps1, not how bright either is.)
ST.Add("film_tone", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local a, b = Bot(p + Vector(0, -24, 0), 0), Bot(p + Vector(0, 24, 0), 0)
	View(p + Vector(-110, 70, 60), p + Vector(-20, 0, 36))
	Wait(3.5)
	Wound(a, { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 })
	Wound(b, { amount = 1.5 })
	Hold(a, 150)
	Hold(b, 150)
	Wait(26)
	local K = ABL.Config.Film
	local base = { clothShow = K.clothShow, liquidShow = K.liquidShow, bead = K.bead, deepLiquid = K.deepLiquid, liquidTint = K.liquidTint, soakDeep = K.soakDeep }
	local variants = {
		{ "0_as_set", {} },
		{ "1_show0", { clothShow = 0 } },
		{ "2_show035", { clothShow = 0.35 } },
		{ "3_soak16", { soakDeep = 1.6 } },
		{ "4_liquid012", { deepLiquid = 0.12 } },
		{ "5_bead05", { bead = 0.5 } },
	}
	local function Round(tag, cam)
		Client("filmcam", cam)
		Wait(0.4)
		for _, v in ipairs(variants) do
			local k = table.Copy(base)
			for n, x in pairs(v[2]) do k[n] = x end
			Client("filmlook", { name = v[1], k = k })
			Wait(1.8)
			Shot(tag .. "_" .. v[1])
		end
		Client("filmlook", { name = "as set", k = base })
		Wait(1.5)
	end
	local ea, eb = a:EntIndex(), b:EntIndex()
	Round("tone_sun", { ent = ea, dist = 15, side = 0.3, sun = "say" })
	Round("tone_sun_mid", { ent = ea, dist = 40, side = 0.3 })
	Round("tone_shade", { ent = eb, dist = 15, side = 0.3, sun = "say" })
	FStats("tone_end")
end)

-- The stain's smoothed rim (a pass of its own, K.softPx; not used): how wide it is drawn for the
-- width its material is told. One body, the camera set once, the rim told a hair's width, a sixth
-- and half of the way to the next texel, and no rim at all.
ST.Add("film_rim", function()
	local p = FindSpot({ open = 200, outdoor = true })
	local a = Bot(p, 0)
	View(p + Vector(70, 40, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(a, { amount = 1.5 })
	Hold(a, 100)
	Wait(22)
	Client("filmcam", { ent = a:EntIndex(), dist = 15, side = 0.3, sun = "say" })
	Wait(0.5)
	local K = ABL.Config.Film
	local base = { softPx = K.softPx, softMin = K.softMin }
	for _, v in ipairs({
		{ "0_as_set", {} },
		{ "1_w004", { softPx = 0.0001, softMin = 0.004 } },
		{ "2_w05", { softPx = 0.0001, softMin = 0.05 } },
		{ "3_w15", { softPx = 0.0001, softMin = 0.15 } },
		{ "4_no_rim", { softPx = 0 } },
	}) do
		local k = table.Copy(base)
		for n, x in pairs(v[2]) do k[n] = x end
		Client("filmlook", { name = v[1], k = k })
		Wait(1.8)
		Shot("rim_" .. v[1])
		FStats("rim_" .. v[1])
	end
	Client("filmlook", { name = "as set", k = base })
	Wait(1)
end)

-- What is drawn of the liquid over the stain (K.liquidPasses), and the film as one layer: on white
-- cloth and on black, in a body's own shade (a wound on the chest) and in the sun (one on the
-- back), from one place each. Where the liquid ends on the stain is what to look at: the two are
-- one blood, and a step in brightness along that line is an outline. And the deepest colour of the
-- palette a little lighter, and lighter again.
ST.Add("film_liquid", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local front, back = { { amount = 1.5 } }, { { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 } }
	local bots, e = PairsStart("film_liquid", p, {
		{ at = Vector(0, -66, 0), wounds = front },
		{ at = Vector(0, -22, 0), wounds = back },
		{ at = Vector(0, 22, 0), wounds = front },
		{ at = Vector(0, 66, 0), wounds = back },
	})
	if not bots then return end
	Dress(bots[1], "models/humans/male/group01/sweater")
	Dress(bots[2], "models/humans/male/group01/sweater")
	Dress(bots[3], "models/humans/male/group01/formal")
	Dress(bots[4], "models/humans/male/group01/formal")
	Wait(24)
	local K = ABL.Config.Film
	local deep = K.palette.wetDeep
	local function Round(tag, cam, stats)
		Client("cvar", { name = "abl_film_layers", value = "1" })
		Client("filmlook", { name = "the highlight alone", k = { liquidPasses = 1 }, palette = { wetDeep = deep } })
		Wait(0.3)
		Client("filmcam", cam)
		Wait(1.8)
		Shot(tag .. "_1_shine")
		if stats then FStats(tag .. "_1_shine") end
		Client("filmlook", { name = "colour and highlight, a pass each", k = { liquidPasses = 2 } })
		Wait(1.8)
		Shot(tag .. "_2_body")
		if stats then FStats(tag .. "_2_body") end
		Client("filmlook", { name = "colour and highlight in one pass", k = { liquidPasses = 3 } })
		Wait(1.8)
		Shot(tag .. "_3_lit")
		Client("cvar", { name = "abl_film_layers", value = "0" })
		Wait(2.0)
		Shot(tag .. "_4_old")
		Client("cvar", { name = "abl_film_layers", value = "1" })
		Client("filmlook", { name = "the highlight alone, deepest colour 68", k = { liquidPasses = 1 }, palette = { wetDeep = { 68, 7, 8 } } })
		Wait(2.0)
		Shot(tag .. "_5_shine_deep68")
		Client("filmlook", { name = "the highlight alone, deepest colour 76", k = { liquidPasses = 1 }, palette = { wetDeep = { 76, 8, 9 } } })
		Wait(1.8)
		Shot(tag .. "_6_shine_deep76")
	end
	Round("liq_white_shade", { ent = e[1], dist = 15, side = 0.3, sun = "say" }, true)
	Round("liq_white_sun", { ent = e[2], dist = 15, side = 0.3, sun = "say" })
	Round("liq_black_shade", { ent = e[3], dist = 15, side = 0.3, sun = "say" })
	Round("liq_black_sun", { ent = e[4], dist = 15, side = 0.3, sun = "say" })
	Client("filmlook", { name = "as set", k = { liquidPasses = K.liquidPasses }, palette = { wetDeep = deep } })
	Wait(1.8)
	FStats("liq_end")
end)

-- What the relief a material is drawn with does to how bright the film is, in a body's own shade:
-- on white cloth and on black, the film as it is drawn, and then as one pass of the stain's kind
-- of material with the body's own relief, with a relief that is none, with the canvas's own and
-- with no relief at all, by the highlight's shader, and with the body's texture laid in.
ST.Add("film_bump", function()
	local p = FindSpot({ open = 240, outdoor = true })
	local SPINE = "ValveBiped.Bip01_Spine2"
	local bots, e = PairsStart("film_bump", p, {
		{ at = Vector(0, -30, 0), wounds = { { amount = 1.5 } } },
		{ at = Vector(0, 30, 0), wounds = { { amount = 1.5 } } },
	})
	if not bots then return end
	Dress(bots[1], "models/humans/male/group01/sweater")
	Dress(bots[2], "models/humans/male/group01/formal")
	Wait(22)
	for i, tag in ipairs({ "white", "black" }) do
		Client("filmcam", { ent = e[i], bone = SPINE, lift = -4, yaw = 0, dist = 24 })
		Wait(0.6)
		Shot("bump_" .. tag .. "_0_own")
		for n, preset in ipairs({ "stain_bump_nodetail", "stain_flat", "stain_b", "stain_nobump", "lit", "stain_bump" }) do
			Client("filmtry", { preset = preset })
			Wait(0.9)
			Shot(string.format("bump_%s_%d_%s", tag, n, preset))
		end
		Client("filmtry", {})
		Wait(0.9)
	end
	FStats("bump_end")
end)

-- The liquid's surface in time: a body that lies still on its side with a wound that runs across
-- its chest, and the camera standing still: a second and a half of frames with the waves on the
-- liquid, the same without them (what else changes from one frame to the next: the measure's own
-- floor), and the same blood as one layer.
ST.Add("film_wave", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	local rag = Fake(bot)
	Wait(1)
	if IsValid(rag) then ABL.DevPose(rag, "side", true) end
	Wait(1.5)
	Wound(bot, { amount = 1.5 })
	Hold(bot, 70)
	Wait(16)
	local ent = bot:EntIndex()
	local ripple = ABL.Config.Film.rippleTilt
	local function Frames(name)
		Client("filmcam", { ent = ent, dist = 14 })
		Wait(0.5)
		Shot(name)
		Client("poolburst", { name = name .. "_f", frames = 12, every = 8, x = 480, y = 180, w = 960, h = 720, quality = 93 })
		Wait(2.6)
	end
	Frames("w_waves")
	FStats("w_waves")
	Client("filmlook", { name = "no waves", k = { rippleTilt = 0 } })
	Wait(2)
	Frames("w_still")
	FStats("w_still")
	Client("filmlook", { name = "one layer, as before", k = { rippleTilt = ripple, material = 0 } })
	Wait(2)
	Frames("w_old")
	Client("filmlook", { name = "two layers", k = { material = 1 } })
	Wait(1.5)
	Client("filmcam", { ent = ent, dist = 14 })
	Wait(0.4)
	Shot("w_new_again")
	FStats("w_end")
end)

-- How wet the liquid looks: a standing body turned to where the sun falls on a wound that runs,
-- from the side and from where the sun is mirrored in the blood, with the highlight as it is set,
-- wider, stronger, with more and less of the sky's sheen, and with a steeper and a flatter body of
-- liquid.
ST.Add("film_wet", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 180)
	bot:SetEyeAngles(Angle(0, 180, 0))
	bot:SetAngles(Angle(0, 180, 0))
	View(p + Vector(-10, 60, 50), p + Vector(0, 0, 42))
	Wait(3.5)
	Wound(bot, { amount = 1.5 })
	Hold(bot, 90)
	Wait(20)
	local KF = ABL.Config.Film
	local e0, b0, rim, bead = KF.phongExp, KF.phongBoost, KF.rim, KF.bead
	local variants = {
		{ name = "1_as_set", phong = { e0, b0 } },
		{ name = "2_exp70", phong = { 70, b0 } },
		{ name = "3_exp40", phong = { 40, b0 * 0.7 } },
		{ name = "4_exp70_strong", phong = { 70, b0 * 1.8 } },
		{ name = "5_rim15", phong = { e0, b0 }, k = { rim = 1.5 } },
		{ name = "6_rim0", phong = { e0, b0 }, k = { rim = 0 } },
		{ name = "7_bead16", phong = { e0, b0 }, k = { bead = 1.6 } },
		{ name = "8_bead07", phong = { e0, b0 }, k = { bead = 0.7 } },
	}
	local ent = bot:EntIndex()
	for _, v in ipairs(variants) do
		v.k = v.k or {}
		if v.k.rim == nil then v.k.rim = rim end
		if v.k.bead == nil then v.k.bead = bead end
		Client("filmlook", v)
		Wait(1.5)
		Client("filmcam", { ent = ent, dist = 15, side = 0.3, sun = "say" })
		Wait(0.3)
		Shot("wet" .. v.name)
		Client("filmcam", { ent = ent, dist = 15, sun = true })
		Wait(0.3)
		Shot("wet" .. v.name .. "_sun")
	end
	Client("filmlook", { name = "back to what is set", phong = { e0, b0 }, k = { rim = rim, bead = bead } })
	Wait(0.8)
	FStats("wet")
end)
-- How a run of liquid is drawn: a standing body with a wound that runs, turned to the sun and away
-- from it; how much its surface is raised, how dark the liquid is against the cloth it soaked, and
-- with no highlight.
ST.Add("film_bead", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(bot, { amount = 1.5 })
	Hold(bot, 80)
	Wait(22)
	local KF = ABL.Config.Film
	local relief, reliefMax, deepRef = KF.relief, KF.reliefMax, KF.deepRef
	local variants = {
		{ name = "1_as_set", k = {} },
		{ name = "2_flat", k = { relief = 2.5, reliefMax = 0.32 } },
		{ name = "3_steep", k = { relief = 14, reliefMax = 0.7 } },
		{ name = "4_even_colour", k = { deepRef = 0.06 } },
		{ name = "5_dark_liquid", k = { deepRef = 0.018 } },
	}
	local ent = bot:EntIndex()
	local function Turned(name)
		for _, yaw in ipairs({ 90, 270 }) do
			bot:SetEyeAngles(Angle(0, yaw, 0))
			bot:SetAngles(Angle(0, yaw, 0))
			Wait(0.9)
			Client("filmcam", { ent = ent, dist = 15, side = 0.3 })
			Wait(0.3)
			Shot(string.format("b%s_yaw%03d", name, yaw))
		end
	end
	for _, v in ipairs(variants) do
		v.k.relief, v.k.reliefMax, v.k.deepRef = v.k.relief or relief, v.k.reliefMax or reliefMax, v.k.deepRef or deepRef
		Client("filmlook", v)
		Wait(1.2)
		Turned(v.name)
	end
	Client("filmlook", { name = "back to what is set", k = { relief = relief, reliefMax = reliefMax, deepRef = deepRef } })
	Wait(0.6)
	Client("cvar", { name = "abl_film_gloss", value = "0" })
	Wait(0.4)
	Turned("6_no_highlight")
	Client("cvar", { name = "abl_film_gloss", value = "1" })
	bot:SetEyeAngles(Angle(0, 0, 0))
	bot:SetAngles(Angle(0, 0, 0))
	Wait(0.3)
	FStats("b_bead")
end)

-- One wound on a character standing still: the film from the first seconds on.
ST.Add("film_single", function()
	Case("m01_single", { wounds = { { amount = 0.6 } }, hold = 70, figureAt = { [20] = true, [60] = true }, macroAt = { [10] = true, [40] = true }, floorAt = { [60] = true } },
		{ 1, 3, 6, 10, 20, 40, 60 })
end)

-- The same wound as streams of the flow core (left) and as a film (right), side by side.
ST.Add("film_compare", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local a, b = Bot(p + Vector(0, -15, 0), 0), Bot(p + Vector(0, 15, 0), 0)
	View(p + Vector(48, 0, 50), p + Vector(0, 0, 44))
	Client("filmmode", { ent = a:EntIndex(), film = false })
	Wait(3.5)
	Wound(a, { amount = 0.6 })
	Wound(b, { amount = 0.6 })
	Hold(a, 65)
	Hold(b, 65)
	local t0 = CurTime()
	for _, tt in ipairs({ 3, 8, 15, 30, 60 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		View(p + Vector(48, 0, 50), p + Vector(0, 0, 44))
		Wait(0.3)
		Shot(string.format("m00_compare_%02ds", tt))
		FStats(string.format("m00_compare_%02ds", tt))
	end
	View(p + Vector(86, 0, 44), p + Vector(0, 0, 34))
	Wait(0.4)
	Shot("m00_compare_figures")
	Client("filmmode", { ent = a:EntIndex(), film = true })
end)

-- What a wound gives decides what its film becomes: three characters, the same place, a small
-- wound, a deeper one and a heavy one.
ST.Add("film_ramp", function()
	local p = FindSpot({ open = 170, outdoor = true })
	local amounts = { 0.15, 0.8, 3.5 }
	local bots = {}
	for i = 1, 3 do bots[i] = Bot(p + Vector(0, (i - 2) * 34, 0), 0) end
	View(p + Vector(84, 0, 48), p + Vector(0, 0, 40))
	Wait(3.5)
	for i = 1, 3 do
		Wound(bots[i], { amount = amounts[i] })
		Hold(bots[i], 95)
	end
	local t0 = CurTime()
	for _, tt in ipairs({ 5, 15, 30, 60, 90 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		View(p + Vector(84, 0, 48), p + Vector(0, 0, 40))
		Wait(0.3)
		Shot(string.format("m02_ramp_%02ds", tt))
		if tt == 30 or tt == 90 then
			for i = 1, 3 do Photo(bots[i], string.format("m02_ramp_%02ds_%d", tt, i)) end
		end
		FStats(string.format("m02_ramp_%02ds", tt))
	end
	View(p + Vector(70, 0, 20), p + Vector(0, 0, 2))
	Wait(0.4)
	Shot("m02_ramp_floor")
end)

-- Two wounds, one above the other and a little to the side: the run of the upper one comes down
-- to the lower one's, and from there they go on as one.
ST.Add("film_merge", function()
	Case("m03_merge", { wounds = { { amount = 0.6, f1 = 0.74, f2 = 0.44 }, { amount = 0.5, f1 = 0.42, f2 = 0.5 } }, hold = 65, figureAt = { [60] = true } },
		{ 3, 8, 15, 30, 60 })
end)

-- Bare skin: a wound on the head.
ST.Add("film_skin", function()
	Case("m04_skin", { wounds = { { bone = "head", amount = 0.4, side = 4, f1 = 0.72, f2 = 0.5 } }, hold = 65, min = 10, macroAt = { [15] = true }, figureAt = { [60] = true } },
		{ 2, 5, 10, 15, 30, 60 })
end)

-- Standing, then laid on the back while the wound still bleeds: what is down for the film changes.
ST.Add("film_turn", function()
	Case("m05_turn", { wounds = { { amount = 1.0 } }, hold = 70, turnAt = 16, turnTo = "back", figureAt = { [14] = true, [25] = true, [60] = true }, floorAt = { [60] = true } },
		{ 5, 14, 16, 20, 25, 40, 60 })
end)

-- Lying on the back from the start: the film gathers on the chest, runs to the flanks and into the
-- pool under the body.
ST.Add("film_lying", function()
	Case("m06_lying", { wounds = { { amount = 1.2 } }, hold = 70, pose = "back", figureAt = { [15] = true, [60] = true }, floorAt = { [30] = true, [60] = true } },
		{ 3, 8, 15, 30, 60 })
end)

-- On the side.
ST.Add("film_side", function()
	Case("m07_side", { wounds = { { amount = 1.0 } }, hold = 60, pose = "side", figureAt = { [15] = true, [50] = true }, floorAt = { [50] = true } },
		{ 3, 8, 15, 30, 50 })
end)

-- A heavy wound on a standing character: the film covers the trunk, crosses onto the trousers, and
-- what leaves the body falls and gathers on the ground.
ST.Add("film_ground", function()
	Case("m08_ground", { wounds = { { bone = "upperchest", amount = 5, f1 = 0.5, f2 = 0.5 } }, hold = 100, max = 70,
		figureAt = { [15] = true, [45] = true, [90] = true }, floorAt = { [45] = true, [90] = true }, lowAt = { [30] = true, [90] = true } },
		{ 3, 8, 15, 30, 45, 60, 90 })
end)

-- The wound closes after twenty seconds: nothing more comes, what has run comes to rest and stays,
-- and dries (on a shortened clock from then on).
ST.Add("film_stop", function()
	Case("m09_stop", { wounds = { { amount = 1.0 } }, hold = 20, healAt = 20, dryAfter = { 30, 0.15 }, figureAt = { [20] = true, [90] = true }, macroAt = { [20] = true, [90] = true } },
		{ 5, 12, 20, 24, 30, 45, 60, 90 })
end)

-- Several wounds on one body, front and back.
ST.Add("film_multi", function()
	Case("m10_multi", { wounds = {
			{ bone = "chest", amount = 0.6, f1 = 0.6, f2 = 0.4 }, { bone = "belly", amount = 0.5, f1 = 0.5, f2 = 0.6 },
			{ bone = "lthigh", amount = 0.7, side = 4 }, { bone = "rforearm", amount = 0.4 }, { bone = "head", amount = 0.3, side = 4, f1 = 0.72, f2 = 0.5 },
			{ bone = "chest", amount = 0.7, side = 4, f1 = 0.5, f2 = 0.5 },
		}, hold = 65, max = 90, figureAt = { [10] = true, [30] = true, [60] = true }, backAt = { [30] = true, [60] = true }, floorAt = { [60] = true } },
		{ 4, 10, 20, 30, 60 })
end)

-- Half a minute of a small wound and a larger one, side by side and from close by: what a change to
-- the flow does is seen in a short run.
ST.Add("film_quick", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local a, b = Bot(p + Vector(0, -17, 0), 0), Bot(p + Vector(0, 17, 0), 0)
	View(p + Vector(56, 0, 50), p + Vector(0, 0, 42))
	Wait(3.5)
	Wound(a, { amount = 0.6 })
	Wound(b, { amount = 2.0 })
	Hold(a, 40)
	Hold(b, 40)
	local t0 = CurTime()
	for _, tt in ipairs({ 6, 14, 22, 32 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Client("filmcam", { ent = a:EntIndex(), dist = 17, side = 0.25 })
		Wait(0.3)
		Shot(string.format("q_small_%02ds", tt))
		Client("filmcam", { ent = b:EntIndex(), dist = 22, side = 0.25 })
		Wait(0.3)
		Shot(string.format("q_large_%02ds", tt))
		FStats(string.format("q_%02ds", tt))
	end
	View(p + Vector(70, 0, 44), p + Vector(0, 0, 34))
	Wait(0.4)
	Shot("q_figures")
end)

-- A wound that goes on bleeding on a standing body: the flow from the wound down the body, onto the
-- legs and off it, and what gathers on the ground under it.
ST.Add("film_run", function()
	Case("m15_run", { wounds = { { amount = 1.5 } }, hold = 100, max = 80,
		figureAt = { [8] = true, [20] = true, [40] = true, [90] = true }, floorAt = { [40] = true, [90] = true }, macroAt = { [20] = true } },
		{ 3, 8, 14, 20, 30, 40, 60, 90 })
end)

-- Blood that leaves the body: a wound on the forearm (it runs to the wrist and drops from there) and
-- one on the brow (down the face and off the chin). What has dropped lies on the ground under them.
ST.Add("film_drip", function()
	Case("m14_drip", { wounds = { { bone = "rforearm", amount = 0.8 }, { bone = "head", amount = 0.5, side = 4, f1 = 0.72, f2 = 0.5 } }, hold = 75, max = 90,
		figureAt = { [10] = true, [30] = true, [60] = true }, floorAt = { [30] = true, [60] = true }, lowAt = { [30] = true, [60] = true },
		aroundAt = { [20] = true, [45] = true, [60] = true } },
		{ 5, 10, 20, 30, 45, 60 })
end)

-- A character that walks while it bleeds: the film stays on the body and follows it; nothing is
-- drawn behind it but what falls off it.
ST.Add("film_move", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(40, -150, 70), p + Vector(40, 0, 30))
	Wait(3.5)
	Wound(bot, { bone = "chest", amount = 1.2 })
	Wound(bot, { bone = "rthigh", amount = 1.0, side = 3 })
	Hold(bot, 45)
	Wait(4)
	Photo(bot, "m11_move_00_before")
	bot:Freeze(false)
	ST.Drive(bot, function(_, cmd)
		local phase = math.floor(CurTime() / 2.4) % 2
		cmd:SetForwardMove(phase == 0 and 160 or -160)
	end)
	local ent = bot:EntIndex()
	for i = 1, 3 do
		Wait(6)
		View(p + Vector(40, -150, 70), p + Vector(40, 0, 30))
		Wait(0.3)
		Shot(string.format("m11_move_%02d_walking", i))
		-- (and from where its film faces, set down where the character is at that moment: it walks
		-- on through the picture)
		Client("filmcam", { ent = ent, dist = 45, side = 0.3 })
		Wait(0.1)
		Shot(string.format("m11_move_%02d_walking_near", i))
		if i == 2 then
			-- (a third of a second of frames of it walking past)
			Client("filmcam", { ent = ent, dist = 70, side = 0.3 })
			Wait(0.1)
			Client("poolburst", { name = "m11_walk", frames = 10, every = 2, x = 0, y = 90, w = 1920, h = 900, quality = 85 })
			Wait(1.2)
		end
	end
	ST.Drive(bot, nil)
	bot:Freeze(true)
	Wait(1.2)
	Photo(bot, "m11_move_04_after")
	FStats("m11_move_after")
	local bp = bot:GetPos()
	View(bp + Vector(64, -30, 44), bp + Vector(0, 0, 34))
	Wait(0.4)
	Shot("m11_move_05_figure")
	View(p + Vector(40, -90, 90), p + Vector(40, 0, 0))
	Wait(0.4)
	Shot("m11_move_06_ground")
	Client("stats", { name = "m11_move" })
	Wait(0.2)
end)

-- Many characters bleeding at once: what the films cost, and whether there are canvases for all.
ST.Add("film_crowd", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local models = { "models/zcity/m/male_06.mdl", "models/zcity/f/female_02.mdl", "models/zcity/m/male_01.mdl", "models/zcity/m/male_06.mdl", "models/zcity/f/female_02.mdl", "models/zcity/m/male_01.mdl" }
	local wounds = {
		{ { amount = 0.6 } }, { { amount = 1.5 }, { bone = "lthigh", amount = 0.6, side = 4 } }, { { bone = "head", amount = 0.4, side = 4, f1 = 0.72, f2 = 0.5 }, { bone = "belly", amount = 0.6 } },
		{ { bone = "upperchest", amount = 3 } }, { { bone = "rforearm", amount = 0.5 }, { amount = 0.4 } }, { { bone = "belly", amount = 1.0 }, { bone = "rthigh", amount = 0.8 } },
	}
	local bots = {}
	for i = 1, #models do
		local row, col = (i - 1) % 3, math.floor((i - 1) / 3)
		bots[i] = Bot(p + Vector(-col * 50, (row - 1) * 40, 0), 0, models[i])
		if not IsValid(bots[i]) then break end
	end
	View(p + Vector(120, 0, 62), p + Vector(-20, 0, 36))
	Wait(4)
	Client("profile", { name = "m12_crowd_before", reset = true })
	FStats("m12_crowd_before")
	for i, bot in ipairs(bots) do
		for _, w in ipairs(wounds[i]) do Wound(bot, w) end
		Hold(bot, 65)
	end
	local t0 = CurTime()
	for _, tt in ipairs({ 5, 15, 30, 60 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		View(p + Vector(120, 0, 62), p + Vector(-20, 0, 36))
		Wait(0.3)
		Shot(string.format("m12_crowd_%02ds", tt))
		FStats(string.format("m12_crowd_%02ds", tt))
		Client("profile", { name = string.format("m12_crowd_%02ds", tt), reset = true })
		Wait(0.1)
	end
	for i = 1, math.min(#bots, 3) do Photo(bots[i], "m12_crowd_60s_" .. i) end
	-- seen from far off: the films stay, and cost less
	View(p + Vector(700, 80, 120), p + Vector(0, 0, 36))
	Wait(3)
	Shot("m12_crowd_far")
	FStats("m12_crowd_far")
	Client("profile", { name = "m12_crowd_far", reset = true })
	Wait(0.2)
	View(p + Vector(120, 0, 62), p + Vector(-20, 0, 36))
	Wait(2)
	Shot("m12_crowd_near_again")
	FStats("m12_crowd_near_again")
	Client("stats", { name = "m12_crowd" })
	Wait(0.2)
end)

-- Death: the film goes over to the corpse with everything on it, and the corpse goes on bleeding
-- into it for a while.
ST.Add("film_death", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(bot, { amount = 1.2 })
	Hold(bot, 12)
	Wait(12)
	Photo(bot, "m13_death_00_alive")
	FStats("m13_death_alive")
	timer.Remove("ABL_FilmHold" .. bot:EntIndex())
	bot:Kill()
	Wait(3)
	local rag = ABL.DevRagdollOf(bot)
	if not IsValid(rag) then
		local best = 1e9
		for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do
			local d = r:GetPos():DistToSqr(p)
			if d < best then rag, best = r, d end
		end
	end
	local c = IsValid(rag) and rag:WorldSpaceCenter() or p
	Log("  film_death: corpse %s", tostring(rag))
	for i, tt in ipairs({ 3, 12, 30 }) do
		if i > 1 then Wait(tt - 3 - (i == 3 and 9 or 0)) end
		c = IsValid(rag) and rag:WorldSpaceCenter() or c
		View(c + Vector(40, -26, 50), c)
		Wait(0.4)
		Shot(string.format("m13_death_%02ds", tt))
		FStats(string.format("m13_death_%02ds", tt))
	end
	-- the player comes back: nothing of the old body's blood is on the new one
	bot:Spawn()
	Place(bot, p + Vector(0, 60, 0), 0)
	Wait(2.5)
	View(p + Vector(70, 10, 50), p + Vector(0, 30, 36))
	Wait(0.5)
	Shot("m13_death_respawned")
	FStats("m13_death_respawned")
	-- the new body bleeds, then its player leaves the game: its film goes with it
	Wound(bot, { amount = 1.0 })
	Hold(bot, 8)
	Wait(8)
	Photo(bot, "m13_death_second_body")
	FStats("m13_death_second_body")
	bot:Kick("ABL film test")
	Wait(3)
	FStats("m13_death_after_kick")
	-- and the map is cleaned up: nothing of any film is left
	game.CleanUpMap()
	Wait(2.5)
	FStats("m13_death_after_cleanup")
end)