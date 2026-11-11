-- Scenes of phase 23 (2026-10-20; developer tool, only with the test harness, see sv_selftest.lua;
-- the client handlers are cl_p21test.lua's, cl_p22test.lua's and cl_p23test.lua's): the quality lock.
-- They run only when asked for by name.
--
--   p23_rimab  one pool of 60 ml in the sun from four places (close, 45 degrees, low, the far side), each
--              with the outline's soft edge and the meniscus's light set several ways in turn: what each
--              part adds, side by side from the same camera
--   p23_toneab the same pool with the colour by fullness three ways (phase 22's stops, phase 23's, and
--              those lifted), from 45 degrees, close and as a player stands; seen low, the floor's filter
--              at the thin edge three ways (by the view's angle, at full, none), as PNG
--   p23_surfaces  30 ml onto each of five surfaces side by side (the concrete floor, a metal plate, a
--              wooden panel, a glass plate, a plastic plate), from one camera over all of them and close
--              to each; each pool's figures (H.p23pools)
--   p23_far    a pool of 60 ml as a player sees it, eye 64 units over the floor, 60 to 400 units off; a
--              burst of frames (PNG) while it grows and two at rest, for how steady its outline and
--              highlights are (tools/harness/steady.ps1)
--   p23_indoor a pool of 45 ml under a roof, from three places
--   p23_grow   90 ml dripped onto one place over 36 s, watched to 80 s from two fixed cameras (as the
--              reference is seen, and as a player stands); phase 23 off, then on, at the same place

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.View, ST.Shot, ST.FindSpot

local function Set(name, value) Client("p23set", { name = name, value = value }) end
local function Restore(name) Client("p23set", { name = name, restore = true }) end

-- Phases 21 and 22 on, 23 on (or off: off23); the pools of before are cleared.
local function Mode(off23)
	Client("cvar", { name = "abl_pool_p21", value = "1" })
	Client("cvar", { name = "abl_pool_p22", value = "1" })
	Client("cvar", { name = "abl_pool_p23", value = off23 and "0" or "1" })
	Wait(0.3)
	Client("clear", {})
	Wait(0.6)
	Log("  mode: phase 23 %s", off23 and "off (the pools as phase 22 left them)" or "on")
end

local function At(t0, tt)
	local w = t0 + tt - CurTime()
	if w > 0 then Wait(w) end
end

-- A fixed camera, placed once and used again by name (cl_p21test.lua, H.p21cam).
local function Cam(name, pos, look, fov)
	View(pos, look)
	Client("p21cam", { name = name, pos = pos, look = look, fov = fov or 60 })
	Wait(0.3)
end
local function Use(name) Client("p21cam", { use = name }) Wait(0.25) end
local function Snap(name, near, r) Client("p21snap", { name = name, near = near, r = r or 60 }) Wait(0.1) end
local function Check(t) Client("p21check", t) Wait(0.05) end

------------------------------------------------------------------------------------------
-- p23_grow: one place, 2.5 ml/s dripped onto it for 36 s, then 44 s more; phase 23 off (the pools as
-- phase 22 left them), then on, at the same place and from the same two cameras: about 30 degrees over
-- the floor as the user's reference is seen, and as a player stands (64 units up, 120 off). Pictures
-- before the blood comes, at the first deposit, while it accumulates, when it has spread, after it
-- stops; the pools' figures and checks beside them (cl_p21test.lua)
------------------------------------------------------------------------------------------
local function Grow(p, tag)
	Cam(tag .. "_ref", p + Vector(-10, -38, 23), p + Vector(0, 2, 0), 60)
	Cam(tag .. "_play", p + Vector(-40, -110, 64), p, 60)
	Use(tag .. "_ref")
	Shot(tag .. "_000_before")
	Snap(tag .. "_000", p, 40)
	Client("poolfeed", { pos = p, rate = 2.5, secs = 36, kind = "drip", jitter = 0.6 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 4, secs = 80, near = p, r = 40 })
	for _, tt in ipairs({ 2, 4, 8, 14, 22, 30, 36, 45, 60, 80 }) do
		At(t0, tt)
		Use(tag .. "_ref")
		Shot(string.format("%s_%03ds", tag, tt))
		if tt == 8 or tt == 22 or tt == 36 or tt == 80 then
			Use(tag .. "_play")
			Shot(string.format("%s_%03ds_play", tag, tt))
		end
		Snap(string.format("%s_%03d", tag, tt), p, 40)
	end
	Use(tag .. "_ref")
	Check({ kind = "grow", from = tag .. "_008", to = tag .. "_022", k = 0.15, minArea = 1 })
	Check({ kind = "grow", from = tag .. "_022", to = tag .. "_036", k = 0.1, minArea = 1 })
	Check({ kind = "still", from = tag .. "_060", to = tag .. "_080", most = 0.05, k = 0.05 })
	Check({ kind = "persist", from = tag .. "_036", to = tag .. "_080", k = 0.9 })
	Check({ kind = "one", at = tag .. "_080" })
	Check({ kind = "books", at = tag .. "_080", most = 0.02 })
	Check({ kind = "conserve", at = tag .. "_080", most = 0.1 })
	Client("p23pools", { name = tag .. "_080", pos = p })
	Client("stats", { name = tag })
	Wait(0.2)
end

------------------------------------------------------------------------------------------
-- p23_mergedbg: two places 9 units apart, 2.5 ml/s each for 30 s (as p21_merge), seen from above and
-- at 45 degrees after they have met, as blood and in the developer views (abl_pool_view 1 depth, 3
-- state, 4 age, 5 pinning, 6 cells and the moving window): where the line across a merged pool comes from
------------------------------------------------------------------------------------------
-- (two places gap units apart, 2.5 ml/s each for 30 s as p21_merge feeds them; at 8 units the second's
-- blood joined the first pool where it landed, one lattice from the start, runs p23_mergedbg3 and 4: two
-- pools that meet, cl_pools.lua SimMerge, are what is looked at)
local function MergeDbg(p, gap, tag)
	Client("clear", {})
	Wait(0.6)
	local a, b = p + Vector(-gap * 0.5, 0, 0), p + Vector(gap * 0.5, 0.5, 0)
	Cam(tag .. "_45", p + Vector(-6, -34, 36), p + Vector(0, 1, 0), 60)
	Client("poolfeed", { pos = a, rate = 2.5, secs = 30, kind = "drip", jitter = 0.2 })
	Client("poolfeed", { pos = b, rate = 2.5, secs = 30, kind = "drip", jitter = 0.2 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 2, secs = 60, near = p, r = 40 })
	for _, tt in ipairs({ 10, 14, 18, 22, 26, 30, 45, 60 }) do
		At(t0, tt)
		Use(tag .. "_45")
		Shot(string.format("%s_45_%03ds", tag, tt))
		if tt == 30 or tt == 60 then
			Client("cvar", { name = "abl_pool_view", value = "1" })
			Wait(0.6)
			Shot(string.format("%s_45_%03ds_view1", tag, tt))
			Client("cvar", { name = "abl_pool_view", value = "0" })
			Wait(0.4)
		end
		Client("p23pools", { name = string.format("%s_%03d", tag, tt), pos = p })
		Client("p23row", { name = string.format("%s_%03d", tag, tt), a = a + Vector(-6, 0, 0), b = b + Vector(6, 0, 0) })
		Wait(0.2)
	end
end

ST.Add("p23_mergedbg", function()
	Mode()
	local p = FindSpot({ open = 170, outdoor = true })
	-- (at the same place: without the bridge over a dry strip one cell wide, C.P23.bridge, then with it)
	Set("P23.bridge", 0)
	MergeDbg(p, 10, "md10off")
	Set("P23.bridge", 1)
	MergeDbg(p, 10, "md10on")
	Restore("P23.bridge")
	Client("stats", { name = "p23_mergedbg" })
	Wait(0.3)
end)

ST.Add("p23_grow", function()
	local p = FindSpot({ open = 200, outdoor = true })
	Mode(true)
	Grow(p, "g22")
	Mode(false)
	Grow(p, "g23")
end)

------------------------------------------------------------------------------------------
-- p23_rimab
------------------------------------------------------------------------------------------
local RIM_KEYS = { "P23.edgeAA", "P22.sunRim", "P22.sunRimK", "P22.sunRimBreak", "Pool.sim.rimGlow" }
local RIM_SETS = {
	-- (as phase 22 left them)
	{ "a_was", { 0, 1, 0.55, 0.44, 0.3 } },
	-- (the soft edge set for the near and far edges)
	{ "b_aa", { 1, 1, 0.55, 0.44, 0.3 } },
	-- (the sun in the meniscus dimmer and not broken by the noise)
	{ "c_sun20", { 1, 1, 0.2, 0, 0.3 } },
	-- (no sun in the meniscus)
	{ "d_nosun", { 1, 0, 0.55, 0.44, 0.3 } },
	-- (and the far slope's light at half, and none)
	{ "e_glow15", { 1, 0, 0.55, 0.44, 0.15 } },
	{ "f_noglow", { 1, 0, 0.55, 0.44, 0 } },
}

ST.Add("p23_rimab", function()
	Mode()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(-20, -30, 30), p)
	Client("poolfeed", { pos = p, rate = 3, secs = 20, kind = "drip", jitter = 0.3 })
	Wait(24)
	local views = {
		{ "close", p + Vector(-3, -10, 9), p + Vector(0, 1, 0) },
		{ "45", p + Vector(-10, -38, 40), p + Vector(0, 1, 0) },
		{ "low", p + Vector(-6, -46, 9), p + Vector(0, 1, 0) },
		{ "back", p + Vector(10, 40, 30), p + Vector(0, 1, 0) },
	}
	for _, v in ipairs(views) do
		View(v[2], v[3])
		Wait(0.8)
		for _, s in ipairs(RIM_SETS) do
			for i, key in ipairs(RIM_KEYS) do Set(key, s[2][i]) end
			Wait(0.9)
			Shot(string.format("rim_%s_%s", v[1], s[1]))
		end
	end
	for _, key in ipairs(RIM_KEYS) do Restore(key) end
	Client("p22sun", { name = "rimab", pos = p })
	Client("stats", { name = "p23_rimab" })
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- p23_toneab
------------------------------------------------------------------------------------------
-- (a single frame as PNG, w x h about the middle of the screen: no JPEG blocks along a red edge)
local function Png(name, w, h)
	Client("poolburst", { name = name, frames = 1, png = true, x = 960 - w / 2, y = 540 - h / 2, w = w, h = h })
	Wait(0.4)
end

ST.Add("p23_toneab", function()
	Mode()
	local p = FindSpot({ open = 200, outdoor = true })
	View(p + Vector(-20, -30, 30), p)
	Client("poolfeed", { pos = p, rate = 3, secs = 20, kind = "drip", jitter = 0.3 })
	Wait(24)
	local tones = { { "t0_p22", 0, 1 }, { "t1_p23", 1, 1 }, { "t2_lift", 1, 1.12 } }
	local views = {
		{ "45", p + Vector(-10, -38, 40), p + Vector(0, 1, 0) },
		{ "close", p + Vector(-3, -10, 9), p + Vector(0, 1, 0) },
		{ "play", p + Vector(-60, -90, 64), p },
	}
	for _, v in ipairs(views) do
		View(v[2], v[3])
		Wait(0.8)
		for _, s in ipairs(tones) do
			Set("P23.tone", s[2])
			Set("P23.lift", s[3])
			Wait(0.9)
			Shot(string.format("tone_%s_%s", v[1], s[1]))
		end
	end
	Restore("P23.tone")
	Restore("P23.lift")
	-- (low: the floor's filter at the thin edge)
	View(p + Vector(-6, -46, 9), p + Vector(0, 1, 0))
	Wait(0.8)
	Set("P23.filterView", 1)
	Wait(0.6)
	Png("edge_low_f1_view", 480, 200)
	Shot("edge_low_f1_view")
	Set("P23.filterView", 0)
	Wait(0.6)
	Png("edge_low_f0_full", 480, 200)
	Shot("edge_low_f0_full")
	Client("cvar", { name = "abl_pool_debug", value = "2" })
	Wait(0.6)
	Png("edge_low_f2_none", 480, 200)
	Shot("edge_low_f2_none")
	Client("cvar", { name = "abl_pool_debug", value = "0" })
	Restore("P23.filterView")
	Wait(0.3)
	Client("stats", { name = "p23_toneab" })
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- p23_surfaces
------------------------------------------------------------------------------------------
local function Frozen(model, pos, ang)
	local e = ents.Create("prop_physics")
	e:SetModel(model)
	e:SetPos(pos)
	e:SetAngles(ang or Angle(0, 0, 0))
	e:Spawn()
	local po = e:GetPhysicsObject()
	if IsValid(po) then po:EnableMotion(false) end
	return e
end

local SURF_PLATES = {
	{ "metal", "models/props_phx/construct/metal_plate2x2.mdl" },
	{ "wood", "models/props_phx/construct/wood/wood_panel2x2.mdl" },
	{ "glass", "models/props_phx/construct/glass/glass_plate2x2.mdl" },
	{ "plastic", "models/hunter/plates/plate2x2.mdl" },
}

ST.Add("p23_surfaces", function()
	Mode()
	local p = FindSpot({ open = 260, outdoor = true })
	-- (the host away from the plates first: the camera over them all parks it 330 units off; FindSpot
	-- looks from where the host stands, and in run p23_val it stood where the glass plate went)
	local camPos, camLook = p + Vector(0, -330, 260), p + Vector(0, -20, 0)
	View(camPos, camLook)
	Wait(0.5)
	local spots, props = {}, {}
	-- (the floor itself, in front of the plates)
	local tr0 = util.TraceLine({ start = p + Vector(0, -110, 30), endpos = p + Vector(0, -110, -30), filter = player.GetAll() })
	spots[1] = { name = "floor", pos = tr0.HitPos }
	Log("  floor: the trace hits %s (MAT %s)", tostring(util.GetSurfacePropName(tr0.SurfaceProps)), tostring(tr0.MatType))
	for i, s in ipairs(SURF_PLATES) do
		if util.IsValidModel(s[2]) then
			-- (120 units apart: the PHX plates "2x2" are 95 units a side, and 64 apart they lay over each
			-- other, run p23_val: the metal plate's blood lay on the wooden panel)
			local at = p + Vector(-180 + (i - 1) * 120, 0, 0)
			local e = Frozen(s[2], at)
			Wait(0.2)
			local mn, mx = e:OBBMins(), e:OBBMaxs()
			Log("  %s: %.1f x %.1f x %.1f units", s[1], mx.x - mn.x, mx.y - mn.y, mx.z - mn.z)
			-- (on the floor: its bottom at the floor's height)
			e:SetPos(at + Vector(0, 0, -mn.z + 0.1))
			Wait(0.2)
			local mid = e:LocalToWorld(Vector((mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, mx.z))
			-- (players and bots left out: in run p23_val the trace over the glass plate met the host)
			local tr = util.TraceLine({ start = mid + Vector(0, 0, 20), endpos = mid - Vector(0, 0, 5), filter = player.GetAll() })
			Log("  %s: %s, its top at %.1f over the floor, the trace hits %s (MAT %s)", s[1], s[2], tr.HitPos.z - p.z,
				tostring(util.GetSurfacePropName(tr.SurfaceProps)), tostring(tr.MatType))
			spots[#spots + 1] = { name = s[1], pos = tr.HitPos }
			props[#props + 1] = e
		else
			Log("  %s: no model %s", s[1], s[2])
		end
	end
	View(camPos, camLook)
	Client("p21cam", { name = "su_all", pos = camPos, look = camLook, fov = 65 })
	Wait(0.5)
	Shot("su_000_before")
	for _, s in ipairs(spots) do
		Client("poolfeed", { pos = s.pos + Vector(0, 0, 6), rate = 2, secs = 15, kind = "drip", jitter = 0.3 })
	end
	local t0 = CurTime()
	for _, tt in ipairs({ 5, 15, 30, 60 }) do
		local w = t0 + tt - CurTime()
		if w > 0 then Wait(w) end
		Client("p21cam", { use = "su_all" })
		Wait(0.3)
		Shot(string.format("su_%03ds", tt))
		if tt == 30 or tt == 60 then
			for _, s in ipairs(spots) do Client("p23pools", { name = string.format("%s_%03d", s.name, tt), pos = s.pos, r = 30 }) end
			Wait(0.2)
		end
	end
	for _, s in ipairs(spots) do
		View(s.pos + Vector(-8, -34, 26), s.pos + Vector(0, 2, 0))
		Wait(0.8)
		Shot(string.format("su_%s_060s", s.name))
	end
	Client("stats", { name = "p23_surfaces" })
	Wait(0.2)
	for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
	Wait(0.5)
end)

------------------------------------------------------------------------------------------
-- p23_far
------------------------------------------------------------------------------------------
-- (a burst of frames as PNG, w x h about the middle of the screen)
local function Burst(name, frames, every, w, h)
	Client("poolburst", { name = name, frames = frames, every = every, png = true, x = 960 - w / 2, y = 540 - h / 2, w = w, h = h })
end

ST.Add("p23_far", function()
	Mode()
	local p = FindSpot({ open = 260, outdoor = true })
	-- (as a player stands, 64 units over the floor, about 120 units off, while the pool grows)
	View(p + Vector(-40, -110, 64), p)
	Wait(1)
	Client("poolfeed", { pos = p, rate = 3, secs = 20, kind = "drip", jitter = 0.3 })
	Wait(6)
	Burst("far_grow", 40, 3, 400, 240)
	Wait(20)
	for _, dist in ipairs({ 60, 120, 240, 400 }) do
		View(p + Vector(-0.34 * dist, -0.94 * dist, 64), p)
		Wait(0.9)
		Shot(string.format("far_%03d", dist))
	end
	-- (at rest: 30 frames, every second one, at 120 and at 240 units)
	View(p + Vector(-0.34 * 120, -0.94 * 120, 64), p)
	Wait(1)
	Burst("far_rest120", 30, 2, 400, 240)
	Wait(3)
	View(p + Vector(-0.34 * 240, -0.94 * 240, 64), p)
	Wait(1)
	Burst("far_rest240", 30, 2, 300, 180)
	Wait(3)
	-- (and close, 45 degrees, at rest)
	View(p + Vector(-10, -38, 40), p + Vector(0, 1, 0))
	Wait(1)
	Burst("far_rest45", 30, 2, 480, 320)
	Wait(3)
	Client("p23pools", { name = "far", pos = p })
	Client("stats", { name = "p23_far" })
	Wait(0.3)
end)

------------------------------------------------------------------------------------------
-- p23_indoor
------------------------------------------------------------------------------------------
ST.Add("p23_indoor", function()
	Mode()
	local q = FindSpot({ open = 90, indoor = true })
	if not q then
		Log("  p23_indoor: no spot under a roof")
		return
	end
	View(q + Vector(-20, -30, 30), q)
	Wait(1)
	Client("poolfeed", { pos = q, rate = 3, secs = 15, kind = "drip", jitter = 0.3 })
	Wait(20)
	local views = {
		{ "45", q + Vector(-10, -38, 40), q + Vector(0, 1, 0) },
		{ "close", q + Vector(-3, -10, 9), q + Vector(0, 1, 0) },
		{ "play", q + Vector(-28, -60, 64), q },
	}
	for _, v in ipairs(views) do
		View(v[2], v[3])
		Wait(0.9)
		Shot("in_" .. v[1])
	end
	Client("p23pools", { name = "indoor", pos = q })
	Client("stats", { name = "p23_indoor" })
	Wait(0.3)
end)
