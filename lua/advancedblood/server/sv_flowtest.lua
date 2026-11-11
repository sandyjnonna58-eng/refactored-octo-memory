-- Flow benchmarks (developer tool; only with the test harness, see sv_selftest.lua). One isolated
-- case per scene, each with a close camera on the wound, a camera that follows the front of the
-- stream, developer views of the flow state, and the flow's own measurements in the log. They run
-- only when asked for by name.

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, NewBot, Place, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.NewBot, ST.Place, ST.View, ST.Shot, ST.FindSpot

local function Stats(name)
	Client("flowstats", { name = name })
	Wait(0.1)
end

-- the same frame again in a developer view of the flow
local function ViewShot(name, view)
	Client("flowview", { view = view })
	Wait(0.3)
	Shot(name)
	Client("flowview", { view = 0 })
	Wait(0.1)
end

-- Z-City closes a small wound within seconds. A benchmark of a wound that goes on bleeding keeps
-- the wound values where they were set (the venous wounds of the character).
local function Hold(bot, seconds)
	local org = bot.organism
	if not istable(org) or not istable(org.wounds) or not org.wounds[1] then return end
	local values = {}
	for i, w in ipairs(org.wounds) do values[i] = w[1] end
	local name = "ABL_FlowHold" .. bot:EntIndex()
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

-- A standing, frozen character with one wound, watched from close by. times: seconds after the wound
-- at which the wound and the front of the stream are photographed.
--   o.amount, o.arterial, o.bone, o.side, o.f1, o.f2: the wound (ABL.DevAddWound)
--   o.dist: camera distance; o.views: developer views photographed at o.viewAt seconds
--   o.crouch: the character crouches; o.at[seconds] = function(bot): done at that time, before the photo
--   o.macro[seconds]: also from very near, the wound and the front of the stream
--   o.drying: abl_drying_scale for the case (clotting and drying on a shortened clock)
local function Case(name, o, times)
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	-- (light clothes, where the engine lets them be chosen: blood reads best on them)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	if o.model then bot:SetModel(o.model) end
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	-- (the surface model of its body is built over the first frames it is in view)
	Wait(3)
	Log("  %s: model %s", name, tostring(bot:GetModel()))
	-- (lying, or hung head down: posed before it is wounded)
	local rag
	if o.pose then
		rag = Fake(bot)
		Wait(1)
		if IsValid(rag) then ABL.DevPose(rag, o.pose, o.freeze) end
		Wait(1.2)
	end
	if o.crouch then
		bot:Freeze(false)
		ST.Drive(bot, function(_, cmd) cmd:SetButtons(IN_DUCK) end)
		Wait(1.5)
		Log("  %s: crouching %s", name, tostring(bot:Crouching()))
	end
	if o.drying then RunConsoleCommand("abl_drying_scale", tostring(o.drying)) end
	local ok, err = ABL.DevAddWound(bot, o.bone or "chest", o.amount or 0.4, o.arterial or false, o.side or 3, o.f1 or 0.55, o.f2 or 0.5)
	Log("  %s: wound on %s, amount %.2f: %s %s", name, o.bone or "chest", o.amount or 0.4, tostring(ok), tostring(err or ""))
	-- (a second wound: two streams that may meet)
	if o.second then ABL.DevAddWound(bot, o.second.bone or o.bone or "chest", o.second.amount or o.amount or 0.4, false, o.second.side or o.side or 3, o.second.f1, o.second.f2) end
	if o.hold then Hold(bot, o.hold) end
	local t0 = CurTime()
	Wait(0.4)
	local ent = bot:EntIndex()
	local dist = o.dist or 17
	for _, tt in ipairs(times) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		-- (the body is turned over part way through: where does the blood go then)
		if o.turnAt == tt then
			rag = rag or Fake(bot)
			if IsValid(rag) then ABL.DevPose(rag, o.turnTo or "back") end
			Wait(1.5)
		end
		if o.at and o.at[tt] then o.at[tt](bot) end
		Client("flowcam", { ent = ent, dist = dist, drop = o.drop or 5 })
		Wait(0.25)
		Shot(string.format("%s_%03ds", name, tt))
		if o.viewAt and o.viewAt[tt] then
			for _, v in ipairs(o.views or { 1, 2 }) do ViewShot(string.format("%s_%03ds_v%d", name, tt, v), v) end
		end
		if o.macro and o.macro[tt] then
			Client("flowcam", { ent = ent, dist = 6.5, drop = 1.5, up = 0.5 })
			Wait(0.25)
			Shot(string.format("%s_%03ds_macro", name, tt))
			Client("flowcam", { ent = ent, dist = 6.5, follow = true, drop = 1, up = 0.5 })
			Wait(0.25)
			Shot(string.format("%s_%03ds_macrofront", name, tt))
		end
		if tt >= (o.followFrom or 8) then
			Client("flowcam", { ent = ent, dist = dist + 6, follow = true, drop = 3 })
			Wait(0.25)
			Shot(string.format("%s_%03ds_front", name, tt))
		end
		Stats(string.format("%s_%03ds", name, tt))
	end
	-- the whole figure and the floor under it
	View(p + Vector(62, -34, 46), p + Vector(0, 0, 34))
	Wait(0.4)
	Shot(name .. "_figure")
	View(p + Vector(34, -20, 22), p + Vector(4, 0, 1))
	Wait(0.4)
	Shot(name .. "_floor")
	Client("stats", { name = name })
	Wait(0.2)
	if o.crouch then
		ST.Drive(bot, nil)
		bot:Freeze(true)
	end
	if o.drying then RunConsoleCommand("abl_drying_scale", "1") end
	return bot, p
end

-- The main benchmark: a small wound on a character standing still.
ST.Add("flow_cut", function()
	Case("f01_cut", { amount = 0.15, hold = 75, model = "models/zcity/m/male_06.mdl", viewAt = { [8] = true, [30] = true },
		macro = { [2] = true, [4] = true, [8] = true, [15] = true, [60] = true } }, { 1, 2, 4, 8, 15, 30, 60, 120 })
end)

ST.Add("flow_tiny", function()
	Case("f02_tiny", { amount = 0.05, hold = 40, viewAt = { [15] = true } }, { 2, 5, 15, 40, 90 })
end)

-- Bare skin: a wound on the head, the stream runs down the face and the neck.
ST.Add("flow_skin", function()
	Case("f03_skin", { bone = "head", amount = 0.15, hold = 40, side = 3, f1 = 0.6, f2 = 0.5, dist = 14, drop = 3, viewAt = { [8] = true } }, { 1, 3, 8, 15, 30, 60 })
end)

ST.Add("flow_venous", function()
	Case("f04_venous", { amount = 1.5, hold = 40, model = "models/zcity/m/male_06.mdl", viewAt = { [8] = true }, dist = 22, drop = 7 }, { 1, 3, 8, 15, 30, 60 })
end)

ST.Add("flow_arterial", function()
	Case("f05_arterial", { bone = "neck", amount = 6, arterial = true, model = "models/zcity/m/male_06.mdl", dist = 24, drop = 6 }, { 1, 3, 8, 15, 30 })
end)

ST.Add("flow_arm", function()
	Case("f06_arm", { bone = "lforearm", amount = 0.3, hold = 40, dist = 15, drop = 3 }, { 2, 5, 10, 20, 40, 60 })
end)

ST.Add("flow_leg", function()
	Case("f07_leg", { bone = "lthigh", amount = 0.4, hold = 40, side = 4, dist = 18, drop = 6 }, { 2, 5, 10, 20, 40, 60 })
end)

-- Two wounds side by side: their streams meet and run on as one.
ST.Add("flow_two", function()
	Case("f08_two", { amount = 0.3, hold = 40, f1 = 0.6, f2 = 0.4, second = { f1 = 0.62, f2 = 0.62 }, model = "models/zcity/m/male_06.mdl", viewAt = { [15] = true }, views = { 8, 9 } }, { 2, 5, 10, 15, 30, 60 })
end)

-- Lying on the back; and standing, then laid down while the wound still bleeds.
ST.Add("flow_lying", function()
	Case("f09_lying", { amount = 0.6, hold = 40, pose = "back", model = "models/zcity/m/male_06.mdl", dist = 20, drop = 0, viewAt = { [20] = true } }, { 2, 5, 10, 20, 40, 60 })
end)

ST.Add("flow_turn", function()
	Case("f10_turn", { amount = 0.6, hold = 50, turnAt = 15, turnTo = "back", model = "models/zcity/m/male_06.mdl", dist = 20, drop = 2, viewAt = { [20] = true }, views = { 1, 5, 8 } }, { 2, 5, 10, 15, 20, 30, 45 })
end)

ST.Add("flow_upside", function()
	Case("f11_upside", { bone = "lthigh", amount = 0.6, hold = 40, pose = "upside", freeze = true, dist = 22, drop = 2 }, { 2, 5, 10, 20, 40 })
end)

-- Clotting: a small wound on bare skin that stops after a quarter of a minute, on a clock four times
-- as fast (blood sets in 15 s). What has come to rest on the skin by then sets as a clot.
ST.Add("flow_clot", function()
	Case("f18_clot", { bone = "head", amount = 0.12, hold = 15, side = 3, f1 = 0.6, f2 = 0.5, dist = 14, drop = 3, drying = 0.25,
		viewAt = { [25] = true, [45] = true }, views = { 4 } }, { 5, 15, 25, 35, 45, 60 })
end)

-- A deeper cut: the same place as flow_cut, four times the flow.
ST.Add("flow_deep", function()
	Case("f12_deep", { amount = 0.6, hold = 45, model = "models/zcity/m/male_06.mdl", viewAt = { [8] = true }, dist = 19, drop = 6 }, { 1, 3, 8, 15, 30, 60 })
end)

-- A heavy wound high on the chest (the wound of the standard scene high_wound): how many streams
-- one wound makes, and where they come from.
ST.Add("flow_heavy", function()
	Case("f17_heavy", { bone = "upperchest", amount = 14, f1 = 0.5, f2 = 0.5, dist = 30, drop = 14, viewAt = { [15] = true }, views = { 8 } }, { 3, 8, 15, 25 })
end)

-- Crouching: the trunk leans, the thighs are level.
ST.Add("flow_crouch", function()
	Case("f13_crouch", { amount = 0.5, hold = 40, crouch = true, model = "models/zcity/m/male_06.mdl", dist = 19, drop = 5, viewAt = { [15] = true } }, { 2, 5, 10, 15, 30, 45 })
end)

-- A body that is thrown about while it bleeds: the blood has to stay on it, and to run to what is
-- lower each time the body has come to rest another way up.
ST.Add("flow_moving", function()
	local rag
	local function Spin(bot)
		rag = rag or Fake(bot)
		if IsValid(rag) then ABL.DevPose(rag, "spin") end
		Wait(0.45)
	end
	Case("f14_moving", { amount = 0.6, hold = 40, model = "models/zcity/m/male_06.mdl", dist = 26, drop = 2,
		at = { [6] = Spin, [12] = Spin, [20] = Spin }, viewAt = { [30] = true }, views = { 2, 8 } }, { 2, 5, 6, 8, 12, 14, 20, 22, 30, 40 })
end)

-- Several minutes of one wound: what the flow costs, how many nodes it keeps, and whether the
-- books still close after it.
ST.Add("flow_long", function()
	Case("f15_long", { amount = 0.3, hold = 290, model = "models/zcity/m/male_06.mdl", dist = 19, drop = 6, viewAt = { [300] = true }, views = { 1, 3, 4 } }, { 10, 60, 120, 180, 240, 300 })
end)

-- Fresh blood over a dried track: a wound bleeds, is closed and dries (on a shortened clock), then
-- bleeds again from the same place.
ST.Add("flow_rewet", function()
	local p = FindSpot({ open = 120, outdoor = true })
	local bot = NewBot()
	Place(bot, p, 0)
	bot:SetPlayerColor(Vector(0.82, 0.8, 0.74))
	bot:SetModel("models/zcity/m/male_06.mdl")
	View(p + Vector(60, -30, 50), p + Vector(0, 0, 40))
	Wait(3)
	local ent = bot:EntIndex()
	local function Photo(name, views)
		Client("flowcam", { ent = ent, dist = 19, drop = 6 })
		Wait(0.25)
		Shot(name)
		for _, v in ipairs(views or {}) do ViewShot(name .. "_v" .. v, v) end
		Stats(name)
	end
	ABL.DevAddWound(bot, "chest", 0.4, false, 3, 0.55, 0.5)
	Hold(bot, 18)
	Wait(18)
	Photo("f16_rewet_1_wet", { 3 })
	timer.Remove("ABL_FlowHold" .. ent)
	ABL.DevHeal(bot)
	RunConsoleCommand("abl_drying_scale", "0.1")
	Wait(16)
	Photo("f16_rewet_2_dried", { 3, 4 })
	RunConsoleCommand("abl_drying_scale", "1")
	Wait(0.5)
	ABL.DevAddWound(bot, "chest", 0.4, false, 3, 0.55, 0.5)
	Hold(bot, 22)
	local t0 = CurTime()
	for _, tt in ipairs({ 2, 5, 10, 20 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Photo(string.format("f16_rewet_3_fresh_%02ds", tt), tt == 5 and { 3, 4 } or nil)
	end
	Client("stats", { name = "f16_rewet" })
	Wait(0.2)
end)

-- The same pour on three tilted panels: glass, metal, wood (the surface profile decides how the
-- stream sticks, runs, soaks in and dries).
ST.Add("flow_surfaces", function()
	local p = FindSpot({ open = 260, outdoor = true })
	local kinds = {
		{ "glass", "models/props_phx/construct/glass/glass_plate2x2.mdl" },
		{ "metal", "models/props_phx/construct/metal_plate2x2.mdl" },
		{ "wood", "models/props_phx/construct/wood/wood_panel2x2.mdl" },
	}
	local props = {}
	for i, k in ipairs(kinds) do
		local e = ents.Create("prop_physics")
		e:SetModel(k[2])
		e:SetPos(p + Vector(0, (i - 2) * 120, 50))
		e:SetAngles(Angle(40, 0, 0))
		e:Spawn()
		local po = e:GetPhysicsObject()
		if IsValid(po) then po:EnableMotion(false) end
		props[i] = e
	end
	Wait(0.8)
	for i, k in ipairs(kinds) do
		local e = props[i]
		local c = e:WorldSpaceCenter()
		-- (where a drop falling on the upper part of the panel lands, and how the panel lies there)
		local top = c + Vector(-22, 0, 0)
		local tr = util.TraceLine({ start = top + Vector(0, 0, 90), endpos = top - Vector(0, 0, 90), filter = function(x) return x == e end })
		if tr.Hit then
			local nrm = tr.HitNormal
			Log("  flow_surfaces %s: lands at %s, normal %.2f %.2f %.2f, surface %s", k[1], tostring(tr.HitPos), nrm.x, nrm.y, nrm.z, tostring(util.GetSurfacePropName(tr.SurfaceProps)))
			local down = Vector(nrm.x, nrm.y, 0)
			if down:LengthSqr() < 0.01 then down = Vector(1, 0, 0) end
			down:Normalize()
			local look = tr.HitPos + down * 18 - Vector(0, 0, 14)
			View(look + nrm * 62 + Vector(0, 22, 6), look)
			Wait(0.6)
			for n = 1, 32 do
				Client("spray", { pos = tr.HitPos + Vector(0, 0, 26), dir = Vector(0, 0, -1), speed = 30, count = 3, vol = 0.1, cone = 0.02 })
				Wait(0.25)
				if n == 12 then Shot("f22_" .. k[1] .. "_03s") Stats("f22_" .. k[1] .. "_03s") end
			end
			Shot("f22_" .. k[1] .. "_08s")
			ViewShot("f22_" .. k[1] .. "_08s_v2", 2)
			Stats("f22_" .. k[1] .. "_08s")
			Wait(10)
			Shot("f22_" .. k[1] .. "_18s")
			Stats("f22_" .. k[1] .. "_18s")
		else
			Log("  flow_surfaces %s: the panel was not found under the pour (model missing?)", k[1])
		end
	end
	Client("stats", { name = "f22_surfaces" })
	Wait(0.5)
	for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
end)

-- Blood on the world: a steady pour against a wall (it runs down, reaches the floor and feeds a pool
-- there), then on a tilted plate.
ST.Add("flow_wall", function()
	local p, wallDir, wallDist = FindSpot({ open = 110, wall = true, outdoor = true })
	if not p then Log("flow_wall: no wall spot") return end
	local wallPoint = p + Vector(0, 0, 46) + wallDir * wallDist
	local side = wallDir:Cross(Vector(0, 0, 1))
	View(wallPoint - wallDir * 46 + side * 14 + Vector(0, 0, -14), wallPoint - Vector(0, 0, 22))
	Wait(1)
	local t0 = CurTime()
	local shots = { [8] = "02s", [20] = "05s", [40] = "10s" }
	-- about 1.2 ml/s for 12 s onto one spot of the wall
	for i = 1, 48 do
		Client("spray", { pos = wallPoint - wallDir * 10, dir = wallDir, speed = 60, count = 3, vol = 0.1, cone = 0.03 })
		Wait(0.25)
		if shots[i] then
			Shot("f20_wall_" .. shots[i])
			Stats("f20_wall_" .. shots[i])
		end
	end
	Shot("f20_wall_12s")
	for _, v in ipairs({ 1, 2, 8 }) do ViewShot("f20_wall_12s_v" .. v, v) end
	Stats("f20_wall_12s")
	Wait(8) Shot("f20_wall_20s") Stats("f20_wall_20s")
	Wait(20) Shot("f20_wall_40s") Stats("f20_wall_40s")
	-- the floor under it
	View(wallPoint - wallDir * 40 + Vector(0, 0, -20), p + wallDir * (wallDist - 6))
	Wait(0.5) Shot("f20_wall_floor")
	Client("stats", { name = "f20_wall" })
	Wait(0.2)
	Log("  flow_wall took %.0f s", CurTime() - t0)
end)

ST.Add("flow_slope", function()
	local p = FindSpot({ open = 160, outdoor = true })
	local plate = ents.Create("prop_physics")
	plate:SetModel("models/hunter/plates/plate2x4.mdl")
	plate:SetPos(p + Vector(0, 0, 22))
	plate:SetAngles(Angle(18, 0, 0))
	plate:Spawn()
	local po = plate:GetPhysicsObject()
	if IsValid(po) then po:EnableMotion(false) end
	Wait(0.5)
	View(p + Vector(-10, 60, 50), p + Vector(0, 0, 22))
	for i = 1, 40 do
		Client("spray", { pos = p + Vector(-12, 0, 44), dir = Vector(0, 0, -1), speed = 30, count = 3, vol = 0.1, cone = 0.02 })
		Wait(0.25)
		if i == 12 then Shot("f21_slope_03s") Stats("f21_slope_03s") end
	end
	Shot("f21_slope_10s")
	for _, v in ipairs({ 1, 2 }) do ViewShot("f21_slope_10s_v" .. v, v) end
	Stats("f21_slope_10s")
	Wait(12) Shot("f21_slope_22s") Stats("f21_slope_22s")
	Client("stats", { name = "f21_slope" })
	Wait(1)
	plate:Remove()
end)

-- The older model as a whole: every scene named between these two in a plan runs with
-- abl_flow_core 0 (beads and streaks on bodies, head-and-trail rivulets on walls).
ST.Add("flow_core_off", function() Client("flowcore", { on = false }) Wait(0.5) end)
ST.Add("flow_core_on", function() Client("flowcore", { on = true }) Wait(0.5) end)

-- The same wound on two characters side by side: the older bead model and the flow core.
ST.Add("flow_compare", function()
	local p = FindSpot({ open = 140, outdoor = true })
	local a, b = NewBot(), NewBot()
	Place(a, p + Vector(0, -14, 0), 0)
	Place(b, p + Vector(0, 14, 0), 0)
	View(p + Vector(46, 0, 48), p + Vector(0, 0, 42))
	Client("flowmode", { ent = a:EntIndex(), legacy = true })
	Wait(3)
	ABL.DevAddWound(a, "chest", 2, false, 3, 0.55, 0.5)
	ABL.DevAddWound(b, "chest", 2, false, 3, 0.55, 0.5)
	local t0 = CurTime()
	for _, tt in ipairs({ 3, 8, 20, 45 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Shot(string.format("f00_compare_%02ds", tt))
		Stats(string.format("f00_compare_%02ds", tt))
	end
	Client("stats", { name = "f00_compare" })
	Wait(0.2)
	Client("flowmode", { ent = a:EntIndex(), legacy = false })
end)
