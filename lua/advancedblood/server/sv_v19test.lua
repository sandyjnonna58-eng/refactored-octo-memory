-- Phase 19's scenes (developer tool; only with the test harness, see sv_selftest.lua; client half
-- cl_v19test.lua). They run only when asked for by name. Each sets the blood as phase 19 draws it
-- against the blood as it was drawn before (the client's abl_liquid_v19 1 and 0), on the same blood
-- from one camera:
--   v19_look     five subjects, each from one fixed camera as A, B, A (1, 0, 1), the game's time
--                slowed nearly to a stop round the switches so that A and B show the same blood: a
--                white sweater standing in the sun, a black suit lying in its own shade, a wound in
--                the face, a body lying in its pool seen from the pool's side, a sleeve that drips,
--                from close by. Pictures v19l_<subject>_<1..3>_<on|off>.png. Then what is read back
--                from the picture and the canvases (cl_v19test.lua, v19probe): PASS or FAILED where
--                it can be judged (the liquid against the stain in the sweater's run, the blood in
--                the opening, B2, the canvases' copies, no canvas left in its first painting), the
--                rest beside the pictures (the pool where it meets the film, the hanging drop).
--   v19_steady   a chest run on a standing body from a camera that stands still: every frame of the
--                middle of the picture as PNG, phase 19 on, off and on again (v19s_*; measured by
--                tools/harness/steady.ps1), with the outlines' counters; and what painting costs with
--                three bleeding bodies within 150 units (PASS at 1.2 ms a frame at most).
--   v19_dolly    a body that lies still, the camera drawn back from 120 to 700 units over 12 s and in
--                again, phase 19 on and off: which passes its film is drawn with, where they change,
--                and how much its liquid's brightness steps there (PASS under 3 %); bursts v19d_*.
--   v19_pendant  a sleeve that drips, from close by: A/B/A stills, the drop that hangs read back
--                against the film beside it, and bursts of every frame on, off and on (v19p_*).
-- What a scene changes (the game's time scale, the client's convars, C.V19) is put back however the
-- scene ends, a failure too.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.FindSpot

local MODEL = "models/zcity/m/male_06.mdl"
local WHITE, BLACK = "models/humans/male/group01/sweater", "models/humans/male/group01/formal"
local P9 = "9x19mmparabellum"

-- The game's time scale while A and B are taken: the blood's simulation (game time) all but stops,
-- the painting of the canvases (real time) does not, so A and B show the same blood. sv_selftest.lua's
-- Wait counts game time (CurTime): RWait waits real seconds whatever the scale.
local SLOW = 0.05
local scale = 1
local function Scale(k)
	scale = k
	game.SetTimeScale(k)
end
local function RWait(t) Wait(t * scale) end
local function Shot(name, png) Client("shot", { name = name, png = png }) RWait(0.45) end
local function V19(on) Client("cvar", { name = "abl_liquid_v19", value = on and "1" or "0" }) end
local function FStats(name) Client("filmstats", { name = name }) RWait(0.15) end

-- Z-City closes a wound within seconds: one that goes on bleeding keeps its values, read the first
-- time they are looked at (a wound made by a bullet is there a moment after the shot).
local holds = {}
local function Hold(bot, seconds)
	if not IsValid(bot) then return end
	local name = "ABL_V19Hold" .. bot:EntIndex()
	local untilT = CurTime() + seconds
	local values = {}
	timer.Create(name, 0.3, 0, function()
		if not IsValid(bot) or not istable(bot.organism) or CurTime() > untilT then timer.Remove(name) return end
		local w = bot.organism.wounds
		if not istable(w) then return end
		for i, e in ipairs(w) do
			if not values[i] then values[i] = e[1] end
			e[1] = values[i]
		end
		bot.organism.owner:SetNetVar("wounds", w)
	end)
	holds[#holds + 1] = name
end
local function Release()
	for _, name in ipairs(holds) do timer.Remove(name) end
	holds = {}
end

local function Bot(p, yaw, dress)
	local bot = NewBot()
	if not IsValid(bot) then return nil end
	Place(bot, p, yaw or 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel(MODEL)
	Wait(0.3)
	-- (nothing worn over its clothes: what is worn hides the blood; and the clothes by name, since
	-- Z-City dresses its characters by chance)
	if bot.SetNetVar then bot:SetNetVar("Accessories", {}) end
	for i, m in ipairs(bot:GetMaterials() or {}) do
		if string.find(string.lower(m), "players_sheet", 1, true) then
			bot:SetSubMaterial(i - 1, dress or WHITE)
			break
		end
	end
	return bot
end

local function Wound(bot, w)
	if not IsValid(bot) then return end
	local ok, err = ABL.DevAddWound(bot, w.bone or "chest", w.amount or 1.5, false, w.side or 3, w.f1 or 0.55, w.f2 or 0.5)
	Log("  wound on %s of %s, amount %.2f: %s %s", w.bone or "chest", bot:Nick(), w.amount or 1.5, tostring(ok), tostring(err or ""))
end

-- The bot laid down in its ragdoll and posed (sv_dev.lua's ABL.DevPose); freeze: it stays exactly so.
local function Lay(bot, pose, freeze)
	if not IsValid(bot) then return nil end
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(bot)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, pose, freeze) else Log("  %s: no ragdoll to lay down", bot:Nick()) end
	Wait(2.0)
	return rag
end

-- A scene of this file: run as sv_selftest.lua runs any, and whatever happens in it, the time scale,
-- the wounds held, the client's convars and C.V19 are put back after it (a failure is passed on to
-- the harness after that).
local function Scene(name, fn)
	ST.Add(name, function()
		Scale(1)
		Client("v19begin", { name = name })
		local ok, err = pcall(fn)
		Scale(1)
		Release()
		Client("v19end", { name = name })
		if not ok then error(err, 0) end
	end)
end

-- A, B, A of one subject from the camera that cam() sets: abl_liquid_v19 1, 0, 1, the game's time
-- slowed nearly to a stop from before the first picture to after the last. after[i]: what is done in
-- that state once its picture is taken (the probes).
local function ABA(tag, cam, after)
	cam()
	RWait(0.8)
	Scale(SLOW)
	RWait(0.3)
	for i, on in ipairs({ true, false, true }) do
		V19(on)
		-- (a switch makes the canvases' materials anew and paints every film again: cl_filmdraw.lua)
		RWait(i == 1 and 1.0 or 2.6)
		local name = string.format("v19l_%s_%d_%s", tag, i, on and "on" or "off")
		Shot(name, true)
		Client("v19stats", { name = name })
		RWait(0.15)
		if after and after[i] then after[i]() end
	end
	Scale(1)
end

local function Probe(t, secs)
	Client("v19probe", t)
	RWait(secs or 0.8)
end

------------------------------------------------------------------------------------------
-- v19_look
------------------------------------------------------------------------------------------
Scene("v19_look", function()
	local host = ST.Host()
	local p = FindSpot({ open = 240, outdoor = true })
	if not p then Log("v19_look: no place") return end
	local sweater = Bot(p + Vector(0, -45, 0), 0, WHITE)
	local suit = Bot(p + Vector(-60, 45, 0), 0, BLACK)
	local face = Bot(p + Vector(55, 40, 0), 0, WHITE)
	local drip = Bot(p + Vector(10, 85, 0), 0, WHITE)
	local pooled = Bot(p + Vector(-95, -50, 0), 0, WHITE)
	if not (IsValid(sweater) and IsValid(suit) and IsValid(face) and IsValid(drip) and IsValid(pooled)) then Log("v19_look: too few bots") return end
	-- (from off to one side of them, above: the host is parked further out on that side, out of the
	-- close views and of the face shot's line, and every body is near enough to the eye for its blood
	-- to go onto its film)
	View(p + Vector(150, -150, 80), p + Vector(-20, 10, 20))
	-- (the bodies' surface models and their films' charts are built over the first frames they are in view)
	Wait(3.5)
	-- the black suit on its side, its front (and the wound on it) in its own shade as it stood; the
	-- other on its back, to bleed into a pool
	Lay(suit, "side", false)
	Lay(pooled, "back", false)
	-- the white sweater: a wound on its back, where the sun falls on bodies put down so (scene film_pairs)
	Wound(sweater, { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 })
	Wound(suit, { amount = 1.5 })
	Wound(pooled, { amount = 12 })
	Wound(drip, { bone = "rforearm", amount = 0.9 })
	for _, b in ipairs({ sweater, suit, pooled, drip }) do Hold(b, 400) end
	-- the face: one 9 mm round into the head of the standing bot (it falls, and lives)
	local body = ABL.ZC.GetBody(face)
	local head = IsValid(body) and ABL.DevHitboxCenter(body, "head")
	if head then
		local fwd, right = face:GetForward(), face:GetRight()
		ABL.DevShootAt(host, head + Vector(0, 0, 1.5), (fwd + right * 0.3):GetNormalized(), nil, 60, P9)
		Wait(0.6)
		Hold(face, 400)
	else
		Log("v19_look: no head to shoot")
	end
	-- (time for the runs to run, the pool to gather and the sleeve to drip)
	Wait(34)
	local e = { sweater = sweater:EntIndex(), suit = suit:EntIndex(), face = face:EntIndex(), pooled = pooled:EntIndex(), drip = drip:EntIndex() }
	-- (the sweater and the sleeve from their wounds' openings, looking a little below them at the runs:
	-- the film's own camera framed the jeans in run p19a; the film's camera if there is no opening)
	ABA("sweater", function() Client("v19mark", { ent = e.sweater, dist = 24, tilt = 18, fov = 52, below = 5,
		fallback = { ent = e.sweater, dist = 15, side = 0.3, sun = "say" } }) end, {
		[2] = function() Probe({ kind = "ratio", ent = e.sweater, tag = "sweater_off", judge = false }) end,
		[3] = function()
			Probe({ kind = "ratio", ent = e.sweater, tag = "sweater", judge = true })
			Probe({ kind = "b2", judge = true })
			Probe({ kind = "b2pair", judge = true })
			Probe({ kind = "copy", judge = true })
		end,
	})
	ABA("suit", function() Client("filmcam", { ent = e.suit, dist = 16, side = 0.3, sun = "say" }) end, {
		[2] = function() Probe({ kind = "ratio", ent = e.suit, tag = "suit_off", judge = false }) end,
		[3] = function() Probe({ kind = "ratio", ent = e.suit, tag = "suit", judge = false }) end,
	})
	ABA("face", function() Client("v19mark", { ent = e.face, dist = 11, tilt = 28, fov = 34 }) end, {
		[2] = function() Probe({ kind = "opening", ent = e.face, tag = "face_off", judge = false }) end,
		[3] = function() Probe({ kind = "opening", ent = e.face, tag = "face", judge = true }) end,
	})
	ABA("pool", function() Client("acccam", { ent = e.pooled, name = "v19_pool", dist = 46, elev = 30, fov = 60 }) end, {
		[2] = function() Probe({ kind = "pool", ent = e.pooled, tag = "pool_off" }) end,
		[3] = function() Probe({ kind = "pool", ent = e.pooled, tag = "pool" }) end,
	})
	ABA("drip", function() Client("v19mark", { ent = e.drip, dist = 18, tilt = 20, fov = 55, below = 4,
		fallback = { ent = e.drip, low = true, drop = 0, dist = 13, turn = 90, pitch = 6 } }) end, {
		[3] = function() Probe({ kind = "pendant", ent = e.drip, tag = "drip" }, 1.5) end,
	})
	FStats("v19_look")
end)

------------------------------------------------------------------------------------------
-- v19_steady
------------------------------------------------------------------------------------------
Scene("v19_steady", function()
	local p = FindSpot({ open = 220, outdoor = true })
	if not p then Log("v19_steady: no place") return end
	local a = Bot(p, 0, WHITE)
	local b = Bot(p + Vector(0, 55, 0), 0, WHITE)
	local c = Bot(p + Vector(0, -55, 0), 0, BLACK)
	if not (IsValid(a) and IsValid(b) and IsValid(c)) then Log("v19_steady: too few bots") return end
	-- (on from the start: steady_on, below, is judged as phase 19's cost, and the client may have
	-- started with abl_liquid_v19 0. The bleeding that follows settles what the switch repaints.)
	V19(true)
	View(p + Vector(70, -20, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(a, { amount = 2.0 })
	Wound(b, { amount = 1.5 })
	Wound(c, { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 })
	for _, bot in ipairs({ a, b, c }) do Hold(bot, 240) end
	-- (a run down the chest, still running)
	Wait(18)
	local e = a:EntIndex()
	Client("filmcam", { ent = e, dist = 15, side = 0.3, sun = "say" })
	Wait(0.6)
	-- what painting costs with the three of them bleeding within 150 units of the eye
	Client("v19paint", { name = "steady_on", secs = 4, limit = 1.2, near = 150, bodies = 3 })
	Wait(4.5)
	for i, on in ipairs({ true, false, true }) do
		V19(on)
		Wait(i == 1 and 0.5 or 2.6)
		local name = string.format("v19s_%d_%s", i, on and "on" or "off")
		-- (the counters from here, for what the burst shows)
		Client("v19stats", { name = name .. "_before" })
		Client("v19burst", { name = name, frames = 60, every = 1, w = 400, h = 400 })
		Wait(5)
		Client("v19stats", { name = name })
		if i == 2 then
			Client("v19paint", { name = "steady_off", secs = 4, near = 150 })
			Wait(4.5)
		end
		Wait(0.2)
	end
	FStats("v19_steady")
end)

------------------------------------------------------------------------------------------
-- v19_stripe and v19_stripe_old: the user's picture of 2026-10-17 again (a standing body in the white
-- sweater, a wound high on the chest, seen from the front in the sun), from one fixed camera on the
-- torso set before the wound is made, so that what develops can be followed: stills at 1, 3, 6, 10, 15,
-- 20, 30 and 40 s (v19x_<on|old>_<t>.png), the game's own video of it as a time lapse (videos/
-- abl_stripe_<on|old>.webm, a frame every 0.2 s of game time), a burst of every frame at 40 s for what
-- moves, then 10 s of real-time video. v19_stripe draws it as phase 19 does, v19_stripe_old with
-- abl_liquid_v19 0 from the start (the look before), so the two can be set side by side.
------------------------------------------------------------------------------------------
local function Stripe(tag, on)
	local p = FindSpot({ open = 220, outdoor = true })
	if not p then Log("v19_stripe: no place") return end
	local a = Bot(p, 0, WHITE)
	if not IsValid(a) then Log("v19_stripe: no bot") return end
	V19(on)
	-- (the torso from the front, chest to hem: the bot faces +x at yaw 0)
	local cam, look = p + Vector(30, 4, 46), p + Vector(0, 0, 45)
	View(cam, look)
	Client("view", { pos = cam, ang = (look - cam):Angle(), fov = 54, znear = 1 })
	Wait(3.5)
	Client("record", { name = "abl_stripe_" .. tag, secs = 42, lapse = 0.2, w = 1280, h = 720, fps = 25 })
	Wound(a, { amount = 2.0 })
	Hold(a, 300)
	local t0 = CurTime()
	for _, t in ipairs({ 1, 3, 6, 10, 15, 20, 30, 40 }) do
		local left = t0 + t - CurTime()
		if left > 0 then Wait(left) end
		Shot(string.format("v19x_%s_%03d", tag, t), true)
	end
	Client("v19stats", { name = "v19x_" .. tag })
	Client("v19burst", { name = "v19x_" .. tag .. "_burst", frames = 60, every = 1, w = 560, h = 560 })
	Wait(4)
	Wait(2.5)
	Client("record", { name = "abl_stripe_" .. tag .. "_live", secs = 10, w = 1280, h = 720, fps = 30 })
	Wait(11)
	FStats("v19_stripe_" .. tag)
end
Scene("v19_stripe", function() Stripe("on", true) end)
Scene("v19_stripe_old", function() Stripe("old", false) end)

------------------------------------------------------------------------------------------
-- v19_stripeset: the same picture in several looks one after another, on the same body (so on the
-- same folds and cloth: they are seeded by the body's number), with the same wound, from the same
-- camera as v19_stripe. Before each look the wound is healed and the blood on the client cleared,
-- then the look's values are set (cl_v19test.lua, v19look) and the wound is made again: stills at 3,
-- 10, 20 and 40 s (v19y_<look>_<t>.png) and a time lapse of each (videos/abl_stripeset_<look>.webm).
-- The looks are what the stripe's correction of 2026-10-17 weighs (run p19f weighed steer, soak and
-- warp: cloth that drew blood in faster and further only made the band wider): the film as
-- configured; blood as a dye in the cloth (dye); with that, fronts that go the way the floor falls
-- (steer) on folds that wander as they hang (warp); and with the liquid showing the cloth as the
-- stain does (dyeL).
------------------------------------------------------------------------------------------
local LOOKS = {
	{ name = "now", v19 = {}, film = {} },
	{ name = "dye", v19 = { dye = 1 }, film = {} },
	{ name = "dyewarp", v19 = { dye = 1, steer = 1, foldWarp = 5 }, film = {} },
	{ name = "dyeL", v19 = { dye = 1, dyeLiquid = 1.0, steer = 1, foldWarp = 5 }, film = {} },
}
Scene("v19_stripeset", function()
	local p = FindSpot({ open = 220, outdoor = true })
	if not p then Log("v19_stripeset: no place") return end
	local a = Bot(p, 0, WHITE)
	if not IsValid(a) then Log("v19_stripeset: no bot") return end
	V19(true)
	local cam, look = p + Vector(30, 4, 46), p + Vector(0, 0, 45)
	View(cam, look)
	Client("view", { pos = cam, ang = (look - cam):Angle(), fov = 54, znear = 1 })
	for _, L in ipairs(LOOKS) do
		Release()
		ABL.DevHeal(a)
		Wait(1.0)
		Client("clear")
		Wait(1.0)
		Client("v19look", { name = L.name, v19 = L.v19, film = L.film })
		Wait(1.5)
		Client("record", { name = "abl_stripeset_" .. L.name, secs = 42, lapse = 0.2, w = 1280, h = 720, fps = 25 })
		Wound(a, { amount = 2.0 })
		Hold(a, 300)
		local t0 = CurTime()
		for _, t in ipairs({ 3, 10, 20, 40 }) do
			local left = t0 + t - CurTime()
			if left > 0 then Wait(left) end
			Shot(string.format("v19y_%s_%03d", L.name, t), true)
		end
		FStats("v19_stripeset_" .. L.name)
		Wait(2.5)
	end
	Release()
	ABL.DevHeal(a)
end)

------------------------------------------------------------------------------------------
-- v19_wet: how the wet surface reads, on the same blood: a standing body in the white sweater with
-- a chest wound bled for 25 s, then the game's time slowed nearly to a stop and four looks of the
-- liquid's highlight (and of how soaked cloth shines) in turn, each from the front (as v19_stripe) and
-- from 50 degrees to the side and a little above (where a surface turned from the eye shows its sheen).
-- v19w_<look>_<front|side>.png. (The highlight's numbers were set in earlier phases while the stain of
-- this sweater was lit through the engine's error texture, twice too bright; they are judged again here.)
------------------------------------------------------------------------------------------
local WET = {
	{ name = "w0_now", v19 = {}, film = {} },
	{ name = "w1_soft", v19 = { phongExp = 60, phongBoost = 1.0, flatShine = 0.12, rim = 0.3 }, film = {} },
	{ name = "w2_soaked", v19 = { phongExp = 60, phongBoost = 1.0, flatShine = 0.12, rim = 0.3 }, film = { soakShine = 0.25 } },
	{ name = "w3_satin", v19 = { phongExp = 30, phongBoost = 0.7, flatShine = 0.25, rim = 0.4 }, film = { soakShine = 0.25 } },
}
Scene("v19_wet", function()
	local p = FindSpot({ open = 220, outdoor = true })
	if not p then Log("v19_wet: no place") return end
	local a = Bot(p, 0, WHITE)
	if not IsValid(a) then Log("v19_wet: no bot") return end
	V19(true)
	local front, look = p + Vector(30, 4, 46), p + Vector(0, 0, 45)
	local side = p + Vector(19, 23, 52)
	View(front, look)
	Client("view", { pos = front, ang = (look - front):Angle(), fov = 54, znear = 1 })
	Wait(3.5)
	Wound(a, { amount = 2.0 })
	Hold(a, 200)
	Wait(25)
	Scale(SLOW)
	RWait(0.3)
	for _, w in ipairs(WET) do
		Client("v19wet", { name = w.name, v19 = w.v19, film = w.film })
		RWait(2.6)
		Client("view", { pos = front, ang = (look - front):Angle(), fov = 54, znear = 1 })
		RWait(0.4)
		Shot("v19w_" .. w.name .. "_front", true)
		Client("view", { pos = side, ang = (look - side):Angle(), fov = 50, znear = 1 })
		RWait(0.4)
		Shot("v19w_" .. w.name .. "_side", true)
	end
	Scale(1)
	FStats("v19_wet")
end)

------------------------------------------------------------------------------------------
-- v19_cost: what each part of phase 19 costs the painting, with three bodies bleeding within 150
-- units of the eye (as v19_steady): the painting's time with everything on, then with each part off
-- in turn, then with phase 19 off, then everything on again (the blood goes on growing meanwhile:
-- the two "all" figures say by how much that alone moves the cost). Logged for comparison only.
------------------------------------------------------------------------------------------
Scene("v19_cost", function()
	local p = FindSpot({ open = 220, outdoor = true })
	if not p then Log("v19_cost: no place") return end
	local a = Bot(p, 0, WHITE)
	local b = Bot(p + Vector(0, 55, 0), 0, WHITE)
	local c = Bot(p + Vector(0, -55, 0), 0, BLACK)
	if not (IsValid(a) and IsValid(b) and IsValid(c)) then Log("v19_cost: too few bots") return end
	V19(true)
	View(p + Vector(70, -20, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(a, { amount = 2.0 })
	Wound(b, { amount = 1.5 })
	Wound(c, { amount = 1.5, side = 4, f1 = 0.6, f2 = 0.6 })
	for _, bot in ipairs({ a, b, c }) do Hold(bot, 300) end
	Wait(18)
	Client("filmcam", { ent = a:EntIndex(), dist = 15, side = 0.3, sun = "say" })
	Wait(0.6)
	local function Measure(name)
		-- (a switch of a part makes the canvases' materials anew and paints every film again)
		Wait(3)
		Client("v19paint", { name = name, secs = 4, near = 150 })
		Wait(4.5)
	end
	Measure("cost_all")
	for _, part in ipairs({ "ease", "split", "b2", "lerp", "touchByChange", "surface", "feather", "waves", "depthTone" }) do
		Client("v19set", { name = part, value = 0 })
		Measure("cost_no_" .. part)
		Client("v19set", { name = part, value = 1 })
	end
	V19(false)
	Measure("cost_v19_off")
	V19(true)
	Measure("cost_all_again")
	FStats("v19_cost")
end)

------------------------------------------------------------------------------------------
-- v19_dolly
------------------------------------------------------------------------------------------
local EL = 20
Scene("v19_dolly", function()
	local p = FindSpot({ open = 260, outdoor = true })
	if not p then Log("v19_dolly: no place") return end
	local bot = Bot(p, 0, WHITE)
	if not IsValid(bot) then Log("v19_dolly: no bot") return end
	View(p + Vector(80, 0, 60), p + Vector(0, 0, 30))
	Wait(3.5)
	local rag = Lay(bot, "back", true)
	local centre = (IsValid(rag) and ABL.DevHitboxCenter(rag, "chest")) or (p + Vector(0, 0, 8))
	Wound(bot, { amount = 1.5 })
	Hold(bot, 240)
	-- (the camera goes out the way that is clear the furthest, at EL degrees above the floor)
	local best, dir = -1, Vector(1, 0, 0)
	local ce, se = math.cos(math.rad(EL)), math.sin(math.rad(EL))
	for i = 0, 15 do
		local a = i * math.pi / 8
		local d = Vector(math.cos(a), math.sin(a), 0)
		local tr = util.TraceLine({ start = centre + Vector(0, 0, 10), endpos = centre + d * (720 * ce) + Vector(0, 0, 720 * se), mask = MASK_SOLID_BRUSHONLY })
		if tr.Fraction > best then best, dir = tr.Fraction, d end
	end
	Log("  v19_dolly: the camera goes out along %s, clear for %.0f of 720 units", tostring(dir), best * 720)
	Wait(16)
	-- (the host is parked by the body, off to its side, so that the body is sent to the client and the
	-- host is not between it and the camera: only the camera goes)
	local side = Vector(-dir.y, dir.x, 0)
	View(centre + side * (120 * ce) + Vector(0, 0, 120 * se), centre)
	Wait(0.5)
	local e = bot:EntIndex()
	for _, on in ipairs({ true, false }) do
		V19(on)
		Wait(2.6)
		for leg, dd in ipairs({ { 120, 700 }, { 700, 120 } }) do
			local name = string.format("v19d_%s_%s", on and "on" or "off", leg == 1 and "out" or "in")
			Client("v19dolly", { ent = e, center = centre, dir = dir, d0 = dd[1], d1 = dd[2], secs = 12, el = EL, fov = 60, name = name, judge = on })
			Client("v19burst", { name = name, frames = 60, every = 5, w = 480, h = 480 })
			Wait(13)
		end
	end
	V19(true)
	Wait(1)
	FStats("v19_dolly")
end)

------------------------------------------------------------------------------------------
-- v19_pendant
------------------------------------------------------------------------------------------
Scene("v19_pendant", function()
	local p = FindSpot({ open = 160, outdoor = true })
	if not p then Log("v19_pendant: no place") return end
	local bot = Bot(p, 0, WHITE)
	if not IsValid(bot) then Log("v19_pendant: no bot") return end
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3.5)
	Wound(bot, { bone = "rforearm", amount = 0.9 })
	Hold(bot, 200)
	-- (the blood runs to the cuff and drips from there)
	Wait(22)
	local e = bot:EntIndex()
	-- (on the place where the most blood waits to drop, from the side its skin faces: run p19b's film
	-- camera framed the side of the sleeve away from its run)
	local cam = { ent = e, dist = 9, fov = 40, fallback = { ent = e, dist = 18, tilt = 20, fov = 55, below = 4 } }
	ABA("pendant", function() Client("v19pendcam", cam) end, {
		[3] = function() Probe({ kind = "pendant", ent = e, tag = "pendant" }, 1.5) end,
	})
	-- every frame of it, phase 19 on, off and on, the blood running
	for i, on in ipairs({ true, false, true }) do
		V19(on)
		Wait(i == 1 and 0.5 or 2.6)
		local name = string.format("v19p_%d_%s", i, on and "on" or "off")
		Client("v19stats", { name = name .. "_before" })
		Client("v19burst", { name = name, frames = 90, every = 1, w = 400, h = 400 })
		Wait(5.5)
		Client("v19stats", { name = name })
		Wait(0.2)
	end
	FStats("v19_pendant")
end)
