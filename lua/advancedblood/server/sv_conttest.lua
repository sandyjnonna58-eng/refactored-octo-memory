-- Scenes of a wound's blood from the wound to where it leaves the body (developer tool; only with
-- the test harness, see sv_selftest.lua). They run only when asked for by name.
--
--   cont_stand    one standing body in plain light clothes, nothing worn over them, one wound in the
--                 chest that goes on bleeding: the first seconds frame by frame, then at set times the
--                 whole of its blood from where it faces, the wound from close by, the lowest place
--                 the blood has reached from the front and from the side (what hangs there, what
--                 falls), the wound closed, the ground.
--   cont_repeat   one standing body wounded four times, a few seconds apart (twice in the chest, an
--                 arm, the head): what each new wound adds, and that none is there twice.
--   cont_long     a standing body and one on its back bleed for two and a half minutes: what the
--                 film holds, what it costs and what is on the ground every half minute.
--   cont_vest     the same wound as cont_stand on a body that wears a vest over its clothes (one of
--                 Z-City's worn models): where its blood is seen.
--   cont_move     a body with a wound in the chest and one in the thigh walks, stops, is laid down
--                 as a ragdoll, turned over and got up again: the blood through all of it, and the
--                 events of the blood module's trace in the client's log.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

local MODEL = "models/zcity/m/male_06.mdl"
local WHITE = "models/humans/male/group01/sweater"

local function FStats(name)
	Client("filmstats", { name = name })
	Wait(0.1)
end
local function Origin(name, bot)
	Client("bleedorigin", { name = name, ent = bot and bot:EntIndex() or nil })
	Wait(0.1)
end

-- (Z-City closes a small wound within seconds: a case of a wound that goes on bleeding keeps the
-- wound values where they were set, as sv_filmtest.lua does)
local function Hold(bot, seconds)
	local name = "ABL_ContHold" .. bot:EntIndex()
	local untilT = CurTime() + seconds
	local values = {}
	timer.Create(name, 0.3, 0, function()
		if not IsValid(bot) or not istable(bot.organism) or CurTime() > untilT then timer.Remove(name) return end
		local w = bot.organism.wounds
		if not istable(w) then return end
		for i, e in ipairs(w) do
			-- (a wound that came later is held at the value it came with)
			if not values[i] then values[i] = e[1] end
			e[1] = values[i]
		end
		bot.organism.owner:SetNetVar("wounds", w)
	end)
end
local function Release(bot)
	timer.Remove("ABL_ContHold" .. bot:EntIndex())
end

-- A bot in light clothes. o.worn: what it wears over them, by Z-City's names (none when left out).
local function Bot(p, yaw, o)
	o = o or {}
	local bot = NewBot()
	Place(bot, p, yaw or 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel(o.model or MODEL)
	-- (Z-City dresses a bot a tick after it spawns: what is set here has to come after that)
	Wait(0.3)
	bot:SetNetVar("Accessories", o.worn or {})
	if o.dress ~= false then
		for i, m in ipairs(bot:GetMaterials() or {}) do
			if string.find(string.lower(m), "players_sheet", 1, true) then
				bot:SetSubMaterial(i - 1, o.dress or WHITE)
				break
			end
		end
	end
	return bot
end

local function Wound(bot, w)
	local ok, err = ABL.DevAddWound(bot, w.bone or "chest", w.amount or 10, false, w.side or 3, w.f1 or 0.55, w.f2 or 0.5)
	Log("  wound on %s of %s, amount %.1f: %s %s", w.bone or "chest", bot:Nick(), w.amount or 10, tostring(ok), tostring(err or ""))
end

-- The whole of a character's blood from where it faces; with o.near the wound from close by; with
-- o.low the lowest place blood has reached, from the front and from the side.
local function Look(bot, tag, o)
	o = o or {}
	local e = bot:EntIndex()
	Client("filmcam", { ent = e, min = o.min or 34, max = o.max or 80, pad = 10 })
	Wait(0.35)
	Shot(tag)
	if o.near then
		Client("filmcam", { ent = e, wound = true, dist = o.nearDist or 15, fov = 40 })
		Wait(0.35)
		Shot(tag .. "_wound")
	end
	if o.low then
		Client("filmcam", { ent = e, low = true, drop = 3, dist = 22, fov = 50 })
		Wait(0.35)
		Shot(tag .. "_low")
		Client("filmcam", { ent = e, low = true, drop = 6, dist = 34, turn = 90, pitch = 4, fov = 50 })
		Wait(0.35)
		Shot(tag .. "_side")
	end
	Origin(tag, bot)
end

local function At(t0, tt)
	local w = t0 + tt - CurTime()
	if w > 0 then Wait(w) end
end

------------------------------------------------------------------------------------------
ST.Add("cont_stand", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	-- (the surface model of its body and the film's chart are built over the first frames it is in view)
	Wait(3.5)
	bot:Freeze(true)
	Log("  cont_stand: model %s, worn %s", tostring(bot:GetModel()), util.TableToJSON(bot:GetNetVar("Accessories") or {}))
	Client("tracesink", { on = true })
	Wound(bot, { amount = 22 })
	Hold(bot, 60)
	local t0 = CurTime()
	-- the wound's first seconds, from close by
	Wait(0.45)
	Client("filmcam", { ent = bot:EntIndex(), wound = true, dist = 17, fov = 40 })
	Wait(0.15)
	Client("poolburst", { name = "cs_first", frames = 28, every = 5, x = 480, y = 90, w = 960, h = 900, quality = 90 })
	Wait(2.8)
	Client("wounds", { name = "cs" })
	for _, tt in ipairs({ 4, 7, 11, 16, 23, 31 }) do
		At(t0, tt)
		Look(bot, string.format("cs_%02ds", tt), { near = true, low = tt >= 11 })
		if tt == 16 then
			-- (two seconds of the whole from one place: how evenly what is seen of it changes)
			Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
			Wait(0.3)
			Client("poolburst", { name = "cs_flow", frames = 24, every = 5, x = 480, y = 60, w = 960, h = 960, quality = 90 })
			Wait(2.4)
		end
	end
	FStats("cs_bleeding")
	-- the wound closes: what is on the body stays, nothing more comes
	Release(bot)
	ABL.DevHeal(bot)
	Log("  cont_stand: wounds closed")
	local t1 = CurTime()
	for _, tt in ipairs({ 3, 10, 20 }) do
		At(t1, tt)
		Look(bot, string.format("cs_closed_%02ds", tt), { near = tt == 20, low = tt == 3 })
	end
	FStats("cs_closed")
	Client("wounds", { name = "cs_closed" })
	-- the ground under it: only what fell there
	View(p + Vector(46, -34, 40), p + Vector(0, 0, 1))
	Wait(0.5)
	Shot("cs_ground")
	Client("tracesink", { on = false })
	Client("stats", { name = "cont_stand" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
ST.Add("cont_repeat", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	bot:Freeze(true)
	Client("tracesink", { on = true })
	local list = {
		{ bone = "chest", amount = 8, f1 = 0.55, f2 = 0.5 },
		{ bone = "chest", amount = 8, f1 = 0.4, f2 = 0.66 },
		{ bone = "lupperarm", amount = 8, side = 3, f1 = 0.4, f2 = 0.5 },
		{ bone = "head", amount = 6, side = 3, f1 = 0.6, f2 = 0.35 },
	}
	Hold(bot, 60)
	for i, w in ipairs(list) do
		Wound(bot, w)
		Wait(1.2)
		Client("wounds", { name = "cr_" .. i })
		Wait(3.6)
		Look(bot, string.format("cr_%d", i), { max = 90 })
		FStats("cr_" .. i)
	end
	Wait(6)
	Look(bot, "cr_5_later", { max = 90, low = true })
	FStats("cr_later")
	Release(bot)
	ABL.DevHeal(bot)
	Wait(4)
	Look(bot, "cr_6_closed", { max = 90 })
	Client("wounds", { name = "cr_closed" })
	Client("tracesink", { on = false })
	Client("stats", { name = "cont_repeat" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
ST.Add("cont_long", function()
	local p = FindSpot({ open = 200, outdoor = true })
	local a = Bot(p + Vector(0, -45, 0), 0)
	local b = Bot(p + Vector(0, 45, 0), 0)
	View(p + Vector(90, 0, 60), p + Vector(0, 0, 30))
	Wait(3.5)
	a:Freeze(true)
	if hg and hg.Fake then hg.Fake(b) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(b)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	Wait(2.0)
	Wound(a, { amount = 7 })
	Wound(b, { amount = 7 })
	Hold(a, 170)
	Hold(b, 170)
	local t0 = CurTime()
	FStats("cl_000")
	for _, tt in ipairs({ 15, 30, 60, 90, 120, 150 }) do
		At(t0, tt)
		local tag = string.format("cl_%03ds", tt)
		Look(a, tag .. "_stand", { low = tt == 60 or tt == 150 })
		Look(b, tag .. "_lying", { min = 26, max = 60 })
		FStats(tag)
		if tt == 60 or tt == 150 then
			View(p + Vector(80, 0, 70), p + Vector(0, 0, 2))
			Wait(0.4)
			Shot(tag .. "_ground")
			Client("stats", { name = "cont_long " .. tt })
			Wait(0.2)
		end
	end
	Release(a)
	Release(b)
	ABL.DevHeal(a)
	ABL.DevHeal(b)
	Wait(8)
	Look(a, "cl_closed_stand")
	Look(b, "cl_closed_lying", { min = 26, max = 60 })
	FStats("cl_closed")
end)

------------------------------------------------------------------------------------------
ST.Add("cont_vest", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bot(p, 0, { worn = { "vest_normal" } })
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	-- (a bot the harness has just made is not drawn by Z-City's own renderer while it stands, and
	-- what it wears is drawn by that renderer alone: no vest was on it in run fl1_diag. One that
	-- has lain as a ragdoll and got up again is: scene bleed_stand.)
	if hg and hg.Fake and hg.FakeUp then
		hg.Fake(bot)
		Wait(1.6)
		hg.FakeUp(bot, true, true)
		Wait(1.6)
	end
	bot:Freeze(true)
	Log("  cont_vest: model %s, worn %s", tostring(bot:GetModel()), util.TableToJSON(bot:GetNetVar("Accessories") or {}))
	-- (the body before it is wounded, from its front: what it wears)
	View(p + bot:GetForward() * 60 + Vector(0, 14, 52), p + Vector(0, 0, 44))
	Wait(0.5)
	Shot("cv_before")
	Wound(bot, { amount = 22 })
	Hold(bot, 40)
	local t0 = CurTime()
	for _, tt in ipairs({ 3, 8, 15, 24 }) do
		At(t0, tt)
		Look(bot, string.format("cv_%02ds", tt), { near = true, low = tt == 24 })
	end
	FStats("cv")
	Client("wounds", { name = "cv" })
	Release(bot)
	ABL.DevHeal(bot)
	Client("stats", { name = "cont_vest" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- cont_look: the film's look as it is and as it was, from one place each: a body on its back in a
-- white sweater (its chest in the sun), one in a black suit, and one that stands (its front in its
-- own shade). For each, from close by and from further off: as it is now; with as little of the
-- cloth showing as before and no pass for the liquid's own colour (clothShow 0.2, deepPass 0); and
-- as it is again.
local BLACK = "models/humans/male/group01/formal"
local WAS = { clothShow = 0.2, deepPass = 0 }

ST.Add("cont_look", function()
	local p = FindSpot({ open = 200, outdoor = true })
	local now = { clothShow = ABL.Config.Film.clothShow, deepPass = ABL.Config.Film.deepPass }
	local a = Bot(p + Vector(0, -60, 0), 0)
	local b = Bot(p + Vector(0, 0, 0), 0)
	local c = Bot(p + Vector(0, 60, 0), 0, { dress = BLACK })
	View(p + Vector(110, 0, 70), p + Vector(0, 0, 30))
	Wait(3.5)
	b:Freeze(true)
	for _, bot in ipairs({ a, c }) do
		if hg and hg.Fake then hg.Fake(bot) end
		Wait(0.5)
		local rag = ABL.DevRagdollOf(bot)
		Wait(0.6)
		if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	end
	Wait(2.0)
	for _, bot in ipairs({ a, b, c }) do
		Wound(bot, { amount = 12 })
		Hold(bot, 120)
	end
	Wait(16)
	FStats("ck_begin")
	local function Set(k, name)
		Client("filmlook", { name = name, k = k })
		-- (every film is painted anew for it)
		Wait(1.8)
	end
	for _, e in ipairs({ { a, "white_sun" }, { b, "white_shade" }, { c, "black_sun" } }) do
		local bot, tag = e[1], e[2]
		for _, v in ipairs({ { "near", 13, 0.4 }, { "far", 34, 0.3 } }) do
			Client("filmcam", { ent = bot:EntIndex(), dist = v[2], side = v[3], fov = 44, sun = "say" })
			Wait(0.4)
			Shot(string.format("ck_%s_%s_1new", tag, v[1]))
			Set(WAS, "as before")
			Shot(string.format("ck_%s_%s_2was", tag, v[1]))
			Set(now, "as now")
			Shot(string.format("ck_%s_%s_3new", tag, v[1]))
		end
	end
	FStats("ck_end")
	for _, bot in ipairs({ a, b, c }) do
		Release(bot)
		ABL.DevHeal(bot)
	end
	Client("stats", { name = "cont_look" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- cont_away: a standing body that bleeds is looked at, the camera turns its back on it for seven
-- seconds and turns to it again: the frames from the first one it is in again, as a burst of
-- pictures (tools/harness/redflicker.ps1: how much red is in each). Once with a body that is not
-- drawn giving its canvases back after four seconds, as it did (idleLong 4), and once as it is.
ST.Add("cont_away", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	bot:Freeze(true)
	Wound(bot, { amount = 14 })
	Hold(bot, 90)
	Wait(16)
	local now = ABL.Config.Film.idleLong
	for i, long in ipairs({ 4, now }) do
		Client("filmlook", { name = "idleLong " .. long, k = { idleLong = long } })
		Wait(2.5)
		Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
		Wait(0.6)
		Shot(string.format("ca_%d_before", i))
		FStats(string.format("ca_%d_before", i))
		Client("awayview", { secs = 7, burst = string.format("ca_%d_back", i), frames = 16 })
		Wait(7 + 2.0)
		Shot(string.format("ca_%d_after", i))
		FStats(string.format("ca_%d_after", i))
	end
	Release(bot)
	ABL.DevHeal(bot)
	Client("stats", { name = "cont_away" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- (the walker: forward, turning now and then)
local walker
hook.Add("StartCommand", "ABL_ContTestWalk", function(ply, cmd)
	if ply ~= walker then return end
	local yaw = (CurTime() % 8) < 4 and 0 or 180
	cmd:SetForwardMove(160)
	cmd:SetButtons(IN_FORWARD)
	cmd:SetViewAngles(Angle(0, yaw, 0))
	ply:SetEyeAngles(Angle(0, yaw, 0))
end)

ST.Add("cont_move", function()
	local p = FindSpot({ open = 220, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	bot:Freeze(true)
	Client("tracesink", { on = true })
	Wound(bot, { amount = 14 })
	Wound(bot, { bone = "rthigh", amount = 10, side = 3, f1 = 0.4, f2 = 0.5 })
	Hold(bot, 80)
	local t0 = CurTime()
	At(t0, 6)
	Look(bot, "cm_1_stand")
	FStats("cm_stand")
	-- it walks
	bot:Freeze(false)
	walker = bot
	for i = 1, 4 do
		Wait(1.5)
		Client("filmcam", { ent = bot:EntIndex(), min = 40, max = 80, pad = 10 })
		Wait(0.3)
		Shot("cm_2_walk_" .. i)
	end
	Origin("cm_walk", bot)
	walker = nil
	bot:Freeze(true)
	Wait(1.0)
	Look(bot, "cm_3_stopped", { low = true })
	FStats("cm_walked")
	-- it is laid down, on its back and then on its side
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(bot)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	Wait(3.0)
	Look(bot, "cm_4_back", { min = 26, max = 70 })
	if IsValid(rag) then ABL.DevPose(rag, "side", false) end
	Wait(4.0)
	Look(bot, "cm_5_side", { min = 26, max = 70 })
	FStats("cm_lying")
	-- and got up again
	if hg and hg.FakeUp then hg.FakeUp(bot, true, true) end
	Wait(1.5)
	bot:Freeze(true)
	Look(bot, "cm_6_up_02s")
	Wait(5)
	Look(bot, "cm_6_up_07s", { low = true })
	FStats("cm_up")
	Client("wounds", { name = "cm" })
	Release(bot)
	ABL.DevHeal(bot)
	Wait(3)
	Look(bot, "cm_7_closed")
	View(p + Vector(70, -50, 70), p + Vector(0, 0, 2))
	Wait(0.5)
	Shot("cm_ground")
	Client("tracesink", { on = false })
	Client("stats", { name = "cont_move" })
	Wait(0.2)
end)
