-- Scenes of phase 21 (2026-10-20; developer tool, only with the test harness, see sv_selftest.lua;
-- client half cl_p21test.lua): ground pools that grow from the blood that reaches them. They run only
-- when asked for by name. Each scene takes its pictures from one camera that does not move, at fixed
-- times, so that the same pool can be laid side by side over time; the pools' figures go to the log
-- every few seconds; checks log PASS or FAILED. A scene named ..._was runs with phase 21 switched off
-- (abl_pool_p21 0: the pools as phase 20 left them), at another place of the map.
--
--   p21_drip    a standing body bleeds from the chest; its drops land at its feet (tests 1, 2, 3, 7, 8)
--   p21_feed    blood arrives at one place at 1 ml/s for 30 s, then stops (1, 2, 8)
--   p21_slope   the same onto a plate tilted 5 and then 12 degrees (4, 5)
--   p21_merge   two places 9 units apart, 2.5 ml/s each (6)
--   p21_rain    drops falling into a pool and beside it (7)
--   p21_age     a pool drying, at ten times the speed (9)
--   p21_multi   two standing bodies bleeding 14 units apart (12, with bots)
--   p21_lying   a body on its back bleeds, is turned on its side and gets up (11)
--   p21_look    one pool from above, at 45 degrees, at a glancing angle and close, in the sun (7, the look)
--   p21_long    three inflows and falling drops for 150 s (10)
--   p21_mirror  the pools' mirror: sky, developer views (its picture, where it is laid, its alignment)
--   p21_mpwait  waits for a second client (harness.ps1 -Peer) before the scenes after it (12)

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

local MODEL = "models/zcity/m/male_06.mdl"
local WHITE = "models/humans/male/group01/sweater"

-- Phase 21 on (was false) or off (was true) on the client; the pools of before are cleared.
local function Mode(was)
	Client("cvar", { name = "abl_pool_p21", value = was and "0" or "1" })
	Wait(0.3)
	Client("clear", {})
	Wait(0.4)
	Log("  mode: %s", was and "phase 21 off (the pools as they were)" or "phase 21 on")
end

local function At(t0, tt)
	local w = t0 + tt - CurTime()
	if w > 0 then Wait(w) end
end

local function Hold(bot, seconds)
	local name = "ABL_P21Hold" .. bot:EntIndex()
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
end
local function Release(bot) timer.Remove("ABL_P21Hold" .. bot:EntIndex()) end

local function Bot(p, yaw)
	local bot = NewBot()
	Place(bot, p, yaw or 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel(MODEL)
	Wait(0.3)
	bot:SetNetVar("Accessories", {})
	for i, m in ipairs(bot:GetMaterials() or {}) do
		if string.find(string.lower(m), "players_sheet", 1, true) then
			bot:SetSubMaterial(i - 1, WHITE)
			break
		end
	end
	return bot
end

local function Wound(bot, amount, bone, side)
	local ok, err = ABL.DevAddWound(bot, bone or "chest", amount or 10, false, side or 3, 0.55, 0.5)
	Log("  wound on %s of %s, amount %.1f: %s %s", bone or "chest", bot:Nick(), amount or 10, tostring(ok), tostring(err or ""))
end

local function Plate(p, model, ang, lift)
	local plate = ents.Create("prop_physics")
	plate:SetModel(model or "models/hunter/plates/plate2x4.mdl")
	plate:SetPos(p + Vector(0, 0, lift or 22))
	plate:SetAngles(ang or Angle(0, 0, 0))
	plate:Spawn()
	local po = plate:GetPhysicsObject()
	if IsValid(po) then po:EnableMotion(false) end
	Wait(0.5)
	return plate
end

-- A fixed camera: placed once (the host parked near it), named, and used again by name.
local function Cam(name, pos, look, fov)
	View(pos, look)
	Client("p21cam", { name = name, pos = pos, look = look, fov = fov or 60 })
	Wait(0.3)
end
local function Use(name) Client("p21cam", { use = name }) Wait(0.3) end

local function Snap(name, near, r) Client("p21snap", { name = name, near = near, r = r or 60 }) Wait(0.1) end
local function Check(t) Client("p21check", t) Wait(0.05) end

------------------------------------------------------------------------------------------
-- p21_drip: a standing body's drops at its feet
------------------------------------------------------------------------------------------
local function Drip(tag, was)
	Mode(was)
	local p = FindSpot({ open = 200, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(70, -40, 50), p + Vector(0, 0, 36))
	Wait(3.5)
	bot:Freeze(true)
	local feet = p + Vector(6, 0, 0)
	-- (the floor in front of the feet, where the blood that runs down the front falls)
	Cam(tag .. "_feet", p + Vector(46, -26, 30), feet + Vector(2, 0, 0), 60)
	Client("p21impacts", { on = true, reset = true })
	Shot(tag .. "_000_dry")
	Snap(tag .. "_000", feet, 40)
	Wound(bot, 12)
	Hold(bot, 75)
	local t0 = CurTime()
	At(t0, 1) Snap(tag .. "_001", feet, 40)
	Check({ kind = "none", at = tag .. "_001" })
	Client("p21watch", { name = tag .. "_w", every = 5, secs = 110, near = feet, r = 40 })
	local first
	for _, tt in ipairs({ 3, 5, 7, 9, 12, 15, 20, 25, 30, 40, 50, 60, 70 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), feet, 40)
	end
	-- (the body from close by, once, where its blood runs and leaves it)
	Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
	Wait(0.4) Shot(tag .. "_070s_body")
	Use(tag .. "_feet")
	Check({ kind = "grow", from = tag .. "_020", to = tag .. "_040", k = 0.15, minArea = 1 })
	Check({ kind = "grow", from = tag .. "_040", to = tag .. "_070", k = 0.1, minArea = 1 })
	Check({ kind = "double", at = tag .. "_070", most = 0 })
	Check({ kind = "books", at = tag .. "_070", most = 0.02 })
	Release(bot)
	ABL.DevHeal(bot)
	Log("  %s: the wound closed", tag)
	local t1 = CurTime()
	for _, tt in ipairs({ 10, 20, 35 }) do
		At(t1, tt)
		Shot(string.format("%s_%03ds_closed", tag, 70 + tt))
		Snap(string.format("%s_c%03d", tag, tt), feet, 40)
	end
	Check({ kind = "still", from = tag .. "_c020", to = tag .. "_c035", most = 0.2, k = 0.05 })
	Check({ kind = "persist", from = tag .. "_070", to = tag .. "_c035", k = 0.8 })
	Check({ kind = "landing" })
	Client("p21impacts", { on = false })
	Client("stats", { name = tag })
	Wait(0.3)
end
ST.Add("p21_drip", function() Drip("pd", false) end)
ST.Add("p21_drip_was", function() Drip("pdw", true) end)

------------------------------------------------------------------------------------------
-- p21_feed: 1 ml/s onto one place for 30 s, then nothing
------------------------------------------------------------------------------------------
local function Feed(tag, was)
	Mode(was)
	local p = FindSpot({ open = 160, outdoor = true })
	Cam(tag .. "_cam", p + Vector(-24, -30, 26), p + Vector(1, 1, 0), 60)
	Shot(tag .. "_000_dry")
	Snap(tag .. "_000", p, 30)
	Client("poolfeed", { pos = p, rate = 1, secs = 30, kind = "drip", jitter = 0.25 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 3, secs = 90, near = p, r = 30 })
	for _, tt in ipairs({ 1, 2, 3, 5, 8, 12, 18, 24, 30, 40, 60, 90 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), p, 30)
	end
	Check({ kind = "small", at = tag .. "_003", most = 3.5, area = 8 })
	Check({ kind = "grow", from = tag .. "_005", to = tag .. "_012", k = 0.3, minArea = 1 })
	Check({ kind = "grow", from = tag .. "_012", to = tag .. "_030", k = 0.3, minArea = 2 })
	Check({ kind = "still", from = tag .. "_060", to = tag .. "_090", most = 0.05, k = 0.05 })
	Check({ kind = "persist", from = tag .. "_030", to = tag .. "_090", k = 0.9 })
	Check({ kind = "conserve", at = tag .. "_090", most = 0.05 })
	Check({ kind = "books", at = tag .. "_090", most = 0.02 })
	-- (close and low, once)
	View(p + Vector(-8, -14, 9), p + Vector(0, 1, 0))
	Wait(0.6) Shot(tag .. "_090s_low")
	Client("stats", { name = tag })
	Wait(0.2)
end
ST.Add("p21_feed", function() Feed("pf", false) end)
ST.Add("p21_feed_was", function() Feed("pfw", true) end)

------------------------------------------------------------------------------------------
-- p21_slope: onto a plate tilted 5 and 12 degrees
------------------------------------------------------------------------------------------
-- look0: the streams drawn as before phase 21's streamLiquid (C.P21.streamLiquid 0); head0: the streams
-- run as before its streamHead (C.P21.streamHead 0). For pairs of runs at the same spots (each as the
-- first scene of its plan: FindSpot gives the same spots)
local function Slope(tag, was, look0, head0)
	Mode(was)
	if look0 then Client("p21set", { name = "streamLiquid", value = 0 }) end
	if head0 then Client("p21set", { name = "streamHead", value = 0 }) end
	Client("p21captest", { name = tag })
	Wait(0.3)
	-- (the spots are looked for from the map's first player start, not from where the host was put:
	-- Z-City spawns it at one of several, and two runs of this scene stood at different places,
	-- runs p21s_look0 and p21s_after)
	local start = ents.FindByClass("info_player_start")[1]
	for _, deg in ipairs({ 5, 12 }) do
		local p = FindSpot({ open = 170, outdoor = true, base = IsValid(start) and start:GetPos() or nil })
		Client("clear", {})
		Wait(0.3)
		local plate = Plate(p, "models/hunter/plates/plate2x4.mdl", Angle(deg, 0, 0))
		-- (the plate falls toward +x; blood arrives on its upper half)
		local inlet = p + Vector(-16, 0, 40)
		local name = string.format("%s%02d", tag, deg)
		Cam(name .. "_cam", p + Vector(4, 52, 52), p + Vector(-2, 0, 22), 60)
		Client("poolfeed", { pos = inlet, rate = 1.5, secs = 24, kind = "drip", jitter = 0.2 })
		local t0 = CurTime()
		Client("p21watch", { name = name .. "_w", every = 3, secs = 42, near = p + Vector(0, 0, 22), r = 50 })
		-- (the heads of its streams and its channels, every frame: H.p21heads)
		Client("p21heads", { on = true, name = name })
		for _, tt in ipairs({ 3, 6, 10, 16, 24, 36 }) do
			At(t0, tt)
			Shot(string.format("%s_%03ds", name, tt))
			Snap(string.format("%s_%03d", name, tt), p + Vector(0, 0, 22), 50)
			if tt == 16 then
				-- (the streams while the inflow still runs: cl_p21test.lua, H.p21streams; and one colour per
				-- channel, from the same camera)
				Client("p21streams", { name = name .. "_016" })
				Wait(0.3)
				Client("cvar", { name = "abl_flow_view", value = "8" })
				Wait(0.3)
				Shot(string.format("%s_%03ds_view8", name, tt))
				Client("cvar", { name = "abl_flow_view", value = "0" })
			end
		end
		Client("p21heads", { name = name })
		Check({ kind = "conserve", at = name .. "_036", most = 0.1 })
		Check({ kind = "books", at = name .. "_036", most = 0.02 })
		Client("stats", { name = name })
		Wait(0.2)
		-- (after the scene's own window of frames: the streams' figures and the sections they were
		-- drawn through, and the streams closer, as they are and in two developer views: one colour
		-- per channel, and the thickness)
		Client("p21streams", { name = name .. "_036" })
		Wait(0.3)
		Cam(name .. "_close", p + Vector(20, 18, 42), p + Vector(20, 0, 19), 60)
		Shot(name .. "_036s_close")
		for _, v in ipairs({ 8, 1 }) do
			Client("cvar", { name = "abl_flow_view", value = tostring(v) })
			Wait(0.3)
			Shot(string.format("%s_036s_close_view%d", name, v))
			Use(name .. "_cam")
			Shot(string.format("%s_036s_view%d", name, v))
			Use(name .. "_close")
		end
		Client("cvar", { name = "abl_flow_view", value = "0" })
		Wait(0.2)
		plate:Remove()
		Wait(0.5)
	end
	if look0 then Client("p21set", { name = "streamLiquid", restore = true }) end
	if head0 then Client("p21set", { name = "streamHead", restore = true }) end
end
ST.Add("p21_slope", function() Slope("ps", false) end)
ST.Add("p21_slope_was", function() Slope("psw", true) end)
ST.Add("p21_slope_look0", function() Slope("ps", false, true) end)
ST.Add("p21_slope_head0", function() Slope("ps", false, false, true) end)

------------------------------------------------------------------------------------------
-- p21_wall: blood against a wall (C.P21.streamHead): a burst of about 3 ml onto one spot, a heavy
-- bead that may split fingers off; then, the wall cleared, a steady pour of about 1.2 ml/s for 12 s onto
-- one spot (one rivulet). The heads and channels of each part: H.p21heads. head0: with streamHead 0.
-- Its spot is looked for from the map's first player start.
------------------------------------------------------------------------------------------
local function Wall(tag, head0)
	Mode(false)
	if head0 then Client("p21set", { name = "streamHead", value = 0 }) end
	local start = ents.FindByClass("info_player_start")[1]
	local p, wallDir, wallDist = FindSpot({ open = 110, wall = true, outdoor = true, base = IsValid(start) and start:GetPos() or nil })
	if not p then
		Log("  %s: no wall spot", tag)
	else
		local wallPoint = p + Vector(0, 0, 46) + wallDir * wallDist
		local side = wallDir:Cross(Vector(0, 0, 1))
		Cam(tag .. "_cam", wallPoint - wallDir * 46 + side * 14 + Vector(0, 0, -14), wallPoint - Vector(0, 0, 22), 60)
		local function View8(name)
			Client("cvar", { name = "abl_flow_view", value = "8" })
			Wait(0.3)
			Shot(name .. "_view8")
			Client("cvar", { name = "abl_flow_view", value = "0" })
			Wait(0.2)
		end
		-- the burst: 30 drops of 0.1 ml in half a second
		Client("p21heads", { on = true, name = tag .. "_burst" })
		for _ = 1, 5 do
			Client("spray", { pos = wallPoint - wallDir * 10, dir = wallDir, speed = 60, count = 6, vol = 0.1, cone = 0.03 })
			Wait(0.1)
		end
		Wait(2) Shot(tag .. "_burst_02s")
		Wait(6) Shot(tag .. "_burst_08s")
		View8(tag .. "_burst_08s")
		Client("p21heads", { name = tag .. "_burst" })
		Client("p21streams", { name = tag .. "_burst" })
		Wait(0.5)
		Client("clear", {})
		Wait(0.5)
		-- the pour: 3 drops of 0.1 ml every quarter of a second for 12 s
		Client("p21heads", { on = true, name = tag .. "_pour" })
		for _ = 1, 48 do
			Client("spray", { pos = wallPoint - wallDir * 10, dir = wallDir, speed = 60, count = 3, vol = 0.1, cone = 0.03 })
			Wait(0.25)
		end
		Shot(tag .. "_pour_12s")
		View8(tag .. "_pour_12s")
		Wait(6)
		Shot(tag .. "_pour_18s")
		Client("p21heads", { name = tag .. "_pour" })
		Client("p21streams", { name = tag .. "_pour" })
		Wait(0.5)
		Client("stats", { name = tag })
		Wait(0.2)
	end
	if head0 then Client("p21set", { name = "streamHead", restore = true }) end
end
ST.Add("p21_wall", function() Wall("pwl", false) end)
ST.Add("p21_wall_head0", function() Wall("pwl", true) end)

------------------------------------------------------------------------------------------
-- p21_merge: two places 9 units apart
------------------------------------------------------------------------------------------
local function Merge(tag, was, gap)
	Mode(was)
	local p = FindSpot({ open = 170, outdoor = true })
	-- (9 units apart: two pools of 75 ml each on concrete come within a unit or two of each other, and
	-- whether they meet is the floor's to say, run p21_after2; gap 6: they meet)
	local h = (gap or 9) * 0.5
	local a, b = p + Vector(-h, 0, 0), p + Vector(h, 0.5, 0)
	Cam(tag .. "_cam", p + Vector(-6, -34, 36), p + Vector(0, 1, 0), 60)
	Client("poolfeed", { pos = a, rate = 2.5, secs = 30, kind = "drip", jitter = 0.2 })
	Client("poolfeed", { pos = b, rate = 2.5, secs = 30, kind = "drip", jitter = 0.2 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 3, secs = 60, near = p, r = 40 })
	for _, tt in ipairs({ 4, 8, 12, 16, 20, 25, 30, 45, 60 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), p, 40)
	end
	Check({ kind = "one", at = tag .. "_060" })
	Check({ kind = "conserve", at = tag .. "_060", most = 0.1 })
	Check({ kind = "books", at = tag .. "_060", most = 0.02 })
	Client("stats", { name = tag })
	Wait(0.2)
end
ST.Add("p21_merge", function() Merge("pm", false) end)
ST.Add("p21_merge_was", function() Merge("pmw", true) end)
ST.Add("p21_merge6", function() Merge("pm6", false, 6) end)

------------------------------------------------------------------------------------------
-- p21_rain: drops from 40 units into a pool and beside it
------------------------------------------------------------------------------------------
local function Rain(tag, was)
	Mode(was)
	local p = FindSpot({ open = 170, outdoor = true })
	Cam(tag .. "_cam", p + Vector(-8, -30, 30), p + Vector(2, 1, 0), 60)
	Client("poolfeed", { pos = p, rate = 3, secs = 8, kind = "drip", jitter = 0.2 })
	Wait(12)
	Shot(tag .. "_pool")
	Snap(tag .. "_before", p, 30)
	Client("p21impacts", { on = true, reset = true })
	local t0 = CurTime()
	-- (into its middle, and 5 units beside it)
	for i = 1, 40 do
		Client("spray", { pos = p + Vector(0, 0, 40), dir = Vector(0, 0, -1), speed = 5, count = 2, vol = 0.05, cone = 0.02, seed = 1000 + i })
		Client("spray", { pos = p + Vector(5, 2, 40), dir = Vector(0, 0, -1), speed = 5, count = 2, vol = 0.05, cone = 0.02, seed = 2000 + i })
		Wait(0.25)
		if i == 8 then Shot(tag .. "_02s") end
		if i == 24 then Shot(tag .. "_06s") end
	end
	Wait(4)
	Shot(tag .. "_14s")
	Snap(tag .. "_after", p, 30)
	Check({ kind = "landing" })
	Check({ kind = "books", at = tag .. "_after", most = 0.02 })
	Check({ kind = "double", at = tag .. "_after", most = 0 })
	Client("p21impacts", { on = false })
	Client("stats", { name = tag })
	Wait(0.2)
end
ST.Add("p21_rain", function() Rain("pr", false) end)
ST.Add("p21_rain_was", function() Rain("prw", true) end)

------------------------------------------------------------------------------------------
-- p21_age: a pool drying at ten times the speed
------------------------------------------------------------------------------------------
local function Age(tag, was)
	Mode(was)
	local p = FindSpot({ open = 170, outdoor = true })
	Cam(tag .. "_cam", p + Vector(-14, -24, 24), p + Vector(1, 1, 0), 60)
	Client("poolfeed", { pos = p, rate = 3, secs = 10, kind = "drip", jitter = 0.2 })
	Wait(14)
	Shot(tag .. "_000s_wet")
	Snap(tag .. "_000", p, 30)
	RunConsoleCommand("abl_drying_scale", "0.1")
	local t0 = CurTime()
	for _, tt in ipairs({ 6, 12, 20, 30, 45, 60 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), p, 30)
	end
	Check({ kind = "persist", from = tag .. "_000", to = tag .. "_060", k = 0.9 })
	Check({ kind = "conserve", at = tag .. "_060", most = 0.05 })
	Check({ kind = "books", at = tag .. "_060", most = 0.02 })
	RunConsoleCommand("abl_drying_scale", "1")
	Wait(0.3)
	Client("stats", { name = tag })
	Wait(0.2)
end
ST.Add("p21_age", function() Age("pa", false) end)
ST.Add("p21_age_was", function() Age("paw", true) end)

------------------------------------------------------------------------------------------
-- p21_multi: two standing bodies bleeding 14 units apart
------------------------------------------------------------------------------------------
local function Multi(tag, was)
	Mode(was)
	local p = FindSpot({ open = 220, outdoor = true })
	local a = Bot(p + Vector(0, -7, 0), 0)
	local b = Bot(p + Vector(0, 7, 0), 0)
	View(p + Vector(90, 0, 70), p + Vector(0, 0, 30))
	Wait(3.5)
	a:Freeze(true)
	b:Freeze(true)
	local mid = p + Vector(7, 0, 0)
	Cam(tag .. "_cam", p + Vector(62, -10, 64), mid, 60)
	Client("p21impacts", { on = true, reset = true })
	Wound(a, 12)
	Wound(b, 12)
	Hold(a, 70)
	Hold(b, 70)
	local t0 = CurTime()
	for _, tt in ipairs({ 10, 20, 30, 45, 60, 70 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), mid, 50)
		Client("poolreport", { name = string.format("%s_%03d", tag, tt) })
		Wait(0.1)
	end
	Check({ kind = "landing" })
	Check({ kind = "books", at = tag .. "_070", most = 0.03 })
	Check({ kind = "double", at = tag .. "_070", most = 0 })
	for _, bot in ipairs({ a, b }) do
		Release(bot)
		ABL.DevHeal(bot)
	end
	Client("p21impacts", { on = false })
	Client("stats", { name = tag })
	Wait(0.3)
end
ST.Add("p21_multi", function() Multi("pu", false) end)
ST.Add("p21_multi_was", function() Multi("puw", true) end)

------------------------------------------------------------------------------------------
-- p21_lying: on its back, then its side, then up again, bleeding all the while
------------------------------------------------------------------------------------------
local function Lying(tag, was)
	Mode(was)
	local p = FindSpot({ open = 220, outdoor = true })
	local bot = Bot(p, 0)
	View(p + Vector(90, 0, 60), p + Vector(0, 0, 30))
	Wait(3.5)
	if hg and hg.Fake then hg.Fake(bot) end
	Wait(0.5)
	local rag = ABL.DevRagdollOf(bot)
	Wait(0.8)
	if IsValid(rag) then ABL.DevPose(rag, "back", false) end
	Wait(2.5)
	local chest = p + Vector(0, 0, 6)
	if IsValid(rag) then
		local b = rag:LookupBone("ValveBiped.Bip01_Spine2")
		if b then chest = rag:GetBonePosition(b) or chest end
	end
	local ov = chest + Vector(30, -28, 70)
	Cam(tag .. "_ov", ov, chest + Vector(0, 0, -5), 70)
	Client("p21impacts", { on = true, reset = true })
	Wound(bot, 12)
	Hold(bot, 120)
	local t0 = CurTime()
	for _, tt in ipairs({ 5, 15, 30, 45 }) do
		At(t0, tt)
		Shot(string.format("%s_%03ds", tag, tt))
		Snap(string.format("%s_%03d", tag, tt), chest, 60)
	end
	Client("acccam", { ent = bot:EntIndex(), name = tag .. "_near", dist = 52, elev = 34, fov = 60 })
	Wait(0.4) Shot(tag .. "_045s_near")
	if IsValid(rag) then ABL.DevPose(rag, "side", false) end
	At(t0, 55)
	Use(tag .. "_ov") Shot(tag .. "_055s_side")
	Snap(tag .. "_055", chest, 60)
	if hg and hg.FakeUp then hg.FakeUp(bot, true, true) end
	Wait(1.5)
	bot:Freeze(true)
	At(t0, 70)
	Use(tag .. "_ov") Shot(tag .. "_070s_up")
	Snap(tag .. "_070", chest, 60)
	Client("filmcam", { ent = bot:EntIndex(), min = 34, max = 80, pad = 10 })
	Wait(0.4) Shot(tag .. "_070s_body")
	Check({ kind = "persist", from = tag .. "_045", to = tag .. "_070", k = 0.8 })
	Check({ kind = "landing" })
	Check({ kind = "books", at = tag .. "_070", most = 0.03 })
	Release(bot)
	ABL.DevHeal(bot)
	Client("p21impacts", { on = false })
	Client("stats", { name = tag })
	Wait(0.3)
end
ST.Add("p21_lying", function() Lying("pl", false) end)
ST.Add("p21_lying_was", function() Lying("plw", true) end)

------------------------------------------------------------------------------------------
-- p21_look: one pool of about 60 ml, from above, at 45 degrees, at a glancing angle and close
------------------------------------------------------------------------------------------
local function Look(tag, was)
	Mode(was)
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(-20, -30, 30), p)
	Client("poolfeed", { pos = p, rate = 3, secs = 20, kind = "drip", jitter = 0.3 })
	Wait(24)
	local views = {
		{ "top", p + Vector(-4, -6, 70), p },
		{ "45", p + Vector(-10, -38, 40), p + Vector(0, 1, 0) },
		{ "low", p + Vector(-6, -46, 9), p + Vector(0, 1, 0) },
		{ "grazing", p + Vector(-2, -70, 5), p + Vector(0, 2, 0) },
		{ "close", p + Vector(-3, -10, 9), p + Vector(0, 1, 0) },
		{ "play", p + Vector(-60, -90, 64), p },
		-- (from the other side: the sun the other way round)
		{ "back", p + Vector(10, 40, 30), p + Vector(0, 1, 0) },
	}
	for _, v in ipairs(views) do
		View(v[2], v[3])
		Wait(0.7)
		Shot(string.format("%s_%s", tag, v[1]))
	end
	Snap(tag .. "_end", p, 30)
	Client("stats", { name = tag })
	Wait(0.2)
end
ST.Add("p21_look", function() Look("pk", false) end)
ST.Add("p21_look_was", function() Look("pkw", true) end)

------------------------------------------------------------------------------------------
-- p21_mirror: the pools' mirror, its developer views, and its cut at the floor three ways
------------------------------------------------------------------------------------------
ST.Add("p21_mirror", function()
	Mode(false)
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(-6, -46, 9), p + Vector(0, 1, 0))
	Client("poolfeed", { pos = p, rate = 4, secs = 15, kind = "drip", jitter = 0.3 })
	Wait(18)
	-- (sky laid in, and not; the developer views: 1 the picture, 2 where it is laid and the part of the
	-- screen covered, 3 the picture at half over the whole screen, for its alignment)
	for _, s in ipairs({ { 1, 0 }, { 1, 1 }, { 1, 2 }, { 1, 3 }, { 0, 0 }, { 0, 1 } }) do
		Client("cvar", { name = "abl_pool_mirror_sky", value = tostring(s[1]) })
		Client("p21mirror", { name = string.format("sky%d_dbg%d", s[1], s[2]), debug = s[2] })
		Wait(0.6)
		Shot(string.format("pmi_low_sky%d_dbg%d", s[1], s[2]))
	end
	Client("cvar", { name = "abl_pool_mirror_sky", value = "1" })
	Client("p21mirror", { name = "end", debug = 0 })
	local views = {
		{ "45", p + Vector(-10, -38, 40), p + Vector(0, 1, 0) },
		{ "grazing", p + Vector(-2, -70, 5), p + Vector(0, 2, 0) },
		{ "close", p + Vector(-3, -10, 9), p + Vector(0, 1, 0) },
	}
	for _, v in ipairs(views) do
		View(v[2], v[3])
		Wait(0.6) Shot("pmi_" .. v[1])
		Client("p21mirror", { name = v[1] .. "_dbg3", debug = 3 })
		Wait(0.5) Shot("pmi_" .. v[1] .. "_dbg3")
		Client("p21mirror", { name = v[1] .. "_dbg2", debug = 2 })
		Wait(0.5) Shot("pmi_" .. v[1] .. "_dbg2")
		Client("p21mirror", { name = v[1] .. "_end", debug = 0 })
	end
	-- (as in play: Z-City's own camera and its RenderScene hook, which the harness takes away while it
	-- runs. The host stands beside the pool and looks down at it; when Z-City's hook answers for the
	-- scene, the mirror's view is drawn from inside it, cl_poolmirror.lua M.Begin)
	local host = ST.Host()
	if IsValid(host) then
		local was = host:GetPos()
		host:SetPos(p + Vector(-30, -42, 0))
		Wait(0.3)
		host:SetEyeAngles((p - host:EyePos()):Angle())
		Client("zview", { on = true })
		Wait(2)
		Shot("pmi_zview")
		Client("p21mirror", { name = "zview", debug = 1 })
		Wait(0.6) Shot("pmi_zview_dbg1")
		Client("p21mirror", { name = "zview_end", debug = 0 })
		Client("zview", { on = false })
		host:SetPos(was)
		Wait(0.5)
	end
	Client("p21mirror", { name = "off", debug = 0 })
	Client("stats", { name = "p21_mirror" })
	Wait(0.2)
end)

------------------------------------------------------------------------------------------
-- p21_mirroroff / p21_mirroron: the pools' mirror off for the scenes after it (what it costs there,
-- against a run of the same plan without it), and on again. abl_pool_mirror is kept in the client's
-- config: a plan with p21_mirroroff ends with p21_mirroron.
------------------------------------------------------------------------------------------
ST.Add("p21_mirroroff", function()
	Client("cvar", { name = "abl_pool_mirror", value = "0" })
	Log("  the pools' mirror off for the scenes after this one")
	Wait(0.5)
end)
ST.Add("p21_mirroron", function()
	Client("cvar", { name = "abl_pool_mirror", value = "1" })
	Log("  the pools' mirror on")
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- p21_mpwait: before the scenes of a run with a second client (tools/harness/harness.ps1 -Peer): waits
-- until a second human client is in the game (300 s at the most: a second game on this machine takes
-- minutes to load Z-City and the map), and 15 s more for it to settle
------------------------------------------------------------------------------------------
ST.Add("p21_mpwait", function()
	local t0 = CurTime()
	while #player.GetHumans() < 2 and CurTime() - t0 < 300 do Wait(1) end
	local n = #player.GetHumans()
	Log("  p21_mpwait: %d human client(s) in the game after %.0f s%s", n, CurTime() - t0, n < 2 and " (FAILED p21 mp: no second client)" or "")
	Wait(15)
end)

------------------------------------------------------------------------------------------
-- p21_long: three inflows and drops for 150 s
------------------------------------------------------------------------------------------
ST.Add("p21_long", function()
	Mode(false)
	local p = FindSpot({ open = 220, outdoor = true })
	Cam("pg_cam", p + Vector(-10, -80, 80), p + Vector(8, 0, 0), 60)
	Client("p21impacts", { on = true, reset = true })
	Client("poolfeed", { pos = p, rate = 1.5, secs = 120, kind = "drip", jitter = 0.25 })
	Client("poolfeed", { pos = p + Vector(30, 6, 0), rate = 0.6, secs = 90, kind = "drip", jitter = 0.25 })
	Client("poolfeed", { pos = p + Vector(-18, 20, 0), rate = 0.4, secs = 150, kind = "seep", jitter = 0.4 })
	timer.Create("ABL_P21LongRain", 0.5, 280, function()
		Client("spray", { pos = p + Vector(12, -14, 50), dir = Vector(0, 0, -1), speed = 5, count = 1, vol = 0.05, cone = 0.15 })
	end)
	local t0 = CurTime()
	for tt = 15, 150, 15 do
		At(t0, tt)
		Snap(string.format("pg_%03d", tt), p, 80)
		Client("profile", { name = string.format("pg_%03d", tt), reset = true })
		Wait(0.1)
		if tt % 30 == 0 then Shot(string.format("pg_%03ds", tt)) end
	end
	timer.Remove("ABL_P21LongRain")
	Check({ kind = "landing" })
	Check({ kind = "books", at = "pg_150", most = 0.05 })
	Check({ kind = "conserve", at = "pg_150", most = 0.2 })
	Client("p21impacts", { on = false })
	Client("stats", { name = "p21_long" })
	Wait(0.3)
end)
