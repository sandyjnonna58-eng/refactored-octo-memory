-- Scenes of phase 22 (2026-10-20; developer tool, only with the test harness, see sv_selftest.lua;
-- the client handlers are cl_p21test.lua's and cl_selftest.lua's): pools as the user's reference shows
-- them, made by the liquid itself. They run only when asked for by name.
--
--   p22_grow   one place, blood dripping onto it at 2.5 ml/s for 36 s, then 44 s more; phase 22 off,
--              then (the floor cleared) on, at the same place and from the same two cameras: one at about
--              30 degrees over the floor as the reference is seen, one from above. Pictures before the
--              blood comes, at the first deposit, while it accumulates, when it has spread, and after
--              it stops; the pools' figures beside them

local ST = ABL.SelfTest
if not ST then return end
local Log, Wait, Client, View, Shot, FindSpot = ST.Log, ST.Wait, ST.Client, ST.View, ST.Shot, ST.FindSpot

local function At(t0, tt)
	local w = t0 + tt - CurTime()
	if w > 0 then Wait(w) end
end

-- Phase 21 on, phase 22 on (on) or off; the pools of before are cleared. (Phase 23, drawn over phase 22,
-- goes with it: off with phase 22 off, so that the passes without it are phase 21's)
local function Mode(on)
	Client("cvar", { name = "abl_pool_p21", value = "1" })
	Client("cvar", { name = "abl_pool_p22", value = on and "1" or "0" })
	Client("cvar", { name = "abl_pool_p23", value = on and "1" or "0" })
	Wait(0.3)
	Client("clear", {})
	Wait(0.6)
	Log("  mode: phase 22 %s", on and "on" or "off (the pools as phase 21 left them)")
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
-- p22_grow
------------------------------------------------------------------------------------------
local function Grow(p, tag)
	-- (about 30 degrees over the floor, 44 units off, a little to the side: as the reference is seen)
	Cam(tag .. "_ref", p + Vector(-10, -38, 23), p + Vector(0, 2, 0), 60)
	Cam(tag .. "_top", p + Vector(-2, -5, 62), p, 60)
	Use(tag .. "_ref")
	Shot(tag .. "_000_before")
	Snap(tag .. "_000", p, 40)
	Client("poolfeed", { pos = p, rate = 2.5, secs = 36, kind = "drip", jitter = 0.6 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 4, secs = 80, near = p, r = 40 })
	for _, tt in ipairs({ 1.5, 4, 8, 14, 22, 30, 36, 45, 60, 80 }) do
		At(t0, tt)
		local s = string.format("%s_%03ds", tag, math.floor(tt + 0.5))
		Use(tag .. "_ref")
		Shot(s)
		if tt == 8 or tt == 22 or tt == 36 or tt == 80 then
			Use(tag .. "_top")
			Shot(s .. "_top")
		end
		Snap(string.format("%s_%03d", tag, math.floor(tt + 0.5)), p, 40)
	end
	Use(tag .. "_ref")
	Check({ kind = "grow", from = tag .. "_008", to = tag .. "_022", k = 0.15, minArea = 1 })
	Check({ kind = "grow", from = tag .. "_022", to = tag .. "_036", k = 0.1, minArea = 1 })
	Check({ kind = "still", from = tag .. "_060", to = tag .. "_080", most = 0.05, k = 0.05 })
	Check({ kind = "persist", from = tag .. "_036", to = tag .. "_080", k = 0.9 })
	Check({ kind = "one", at = tag .. "_080" })
	Check({ kind = "books", at = tag .. "_080", most = 0.02 })
	Check({ kind = "conserve", at = tag .. "_080", most = 0.1 })
	Client("stats", { name = tag })
	Wait(0.2)
end

ST.Add("p22_grow", function()
	local p = FindSpot({ open = 200, outdoor = true })
	Mode(false)
	Grow(p, "gr21")
	Mode(true)
	Grow(p, "gr22")
	-- (and phase 22 without the sun in the meniscus, C.P22.sunRim: what that line adds at the edge)
	Mode(true)
	Client("p22set", { name = "sunRim", value = 0 })
	Grow(p, "gr22n")
	Client("p22set", { name = "sunRim", restore = true })
	Client("cvar", { name = "abl_pool_p22", value = "1" })
	Client("cvar", { name = "abl_pool_p23", value = "1" })
end)

------------------------------------------------------------------------------------------
-- p22_ramp: a stream that runs down a ramp onto the level and gathers there. Two plates, one surface:
-- one tilted deg degrees, its lower edge on the near edge of a level one at the same height, the
-- level one on the floor. Blood comes onto the upper part of the ramp at 1.5 ml/s for 40 s; the
-- pictures show where the stream reaches the level and the pool it makes there, as it grows and after
-- the blood stops.
------------------------------------------------------------------------------------------
local function Frozen(model, pos, ang)
	local e = ents.Create("prop_physics")
	e:SetModel(model)
	e:SetPos(pos)
	e:SetAngles(ang)
	e:Spawn()
	local po = e:GetPhysicsObject()
	if IsValid(po) then po:EnableMotion(false) end
	return e
end

local function Ramp(p, deg, tag)
	local mdl = "models/hunter/plates/plate2x4.mdl"
	-- the level plate: on the floor, its long side along x
	local B = Frozen(mdl, p, Angle(0, 0, 0))
	local bmin, bmax = B:OBBMins(), B:OBBMaxs()
	local longX = (bmax.x - bmin.x) >= (bmax.y - bmin.y)
	if not longX then B:SetAngles(Angle(0, 90, 0)) end
	Wait(0.2)
	bmin, bmax = B:OBBMins(), B:OBBMaxs()
	-- (in the world now: its extent along x and its top)
	local c1, c2 = B:LocalToWorld(Vector(bmin.x, bmin.y, bmax.z)), B:LocalToWorld(Vector(bmax.x, bmax.y, bmax.z))
	local bx0 = math.min(c1.x, c2.x)
	B:SetPos(B:GetPos() + Vector(0, 0, p.z - B:LocalToWorld(Vector(0, 0, bmin.z)).z + 0.1))
	Wait(0.2)
	local btop = B:LocalToWorld(Vector(0, 0, bmax.z)).z
	-- the ramp: the same plate tilted down toward +x (about its own y: whichever of its sides lies along
	-- x), its lower edge's top on the level plate's near edge (overlapping it by half a unit)
	local A = Frozen(mdl, p + Vector(-60, 0, 30), Angle(deg, 0, 0))
	Wait(0.3)
	local amin, amax = A:OBBMins(), A:OBBMaxs()
	local low, lowZ = nil, math.huge
	for _, xx in ipairs({ amin.x, amax.x }) do
		for _, yy in ipairs({ amin.y, amax.y }) do
			local w = A:LocalToWorld(Vector(xx, yy, amax.z))
			if w.z < lowZ - 0.01 then low, lowZ = { w }, w.z elseif math.abs(w.z - lowZ) <= 0.01 then low[#low + 1] = w end
		end
	end
	local E = low[1]
	if low[2] then E = (low[1] + low[2]) * 0.5 end
	A:SetPos(A:GetPos() + Vector(bx0 + 0.5 - E.x, p.y - E.y, btop - E.z))
	Wait(0.3)
	-- (blood onto the ramp's upper end, 8 units below its top edge)
	local upper = A:LocalToWorld(Vector(amin.x + 8, 0, amax.z))
	local feed = upper + Vector(0, 0, 8)
	local join = Vector(bx0, p.y, btop)
	Log("  %s: ramp %d degrees, its lower edge at %.1f %.1f %.1f, the level plate's top %.1f, blood onto %.1f %.1f %.1f",
		tag, deg, join.x, join.y, join.z, btop, feed.x, feed.y, feed.z)
	-- (from the side, over the ramp and the level plate both, the join a little right of the middle;
	-- and from above)
	Cam(tag .. "_side", join + Vector(-10, -92, 58), join + Vector(-6, 0, -2), 60)
	Cam(tag .. "_top", join + Vector(-6, -10, 118), join + Vector(-6, 0, 0), 60)
	Use(tag .. "_side")
	Shot(tag .. "_000_before")
	Client("poolfeed", { pos = feed, rate = 1.5, secs = 40, kind = "drip", jitter = 0.2 })
	local t0 = CurTime()
	Client("p21watch", { name = tag .. "_w", every = 4, secs = 80, near = join + Vector(14, 0, 0), r = 40 })
	for _, tt in ipairs({ 4, 8, 14, 20, 30, 40, 50, 60, 75 }) do
		At(t0, tt)
		local s = string.format("%s_%03ds", tag, tt)
		Use(tag .. "_side")
		Shot(s)
		if tt == 14 or tt == 40 or tt == 75 then
			Use(tag .. "_top")
			Shot(s .. "_top")
		end
		Snap(string.format("%s_%03d", tag, tt), join + Vector(14, 0, 0), 40)
	end
	Use(tag .. "_side")
	Check({ kind = "books", at = tag .. "_075", most = 0.03 })
	Client("stats", { name = tag })
	Wait(0.2)
	A:Remove()
	B:Remove()
	Wait(0.5)
end

------------------------------------------------------------------------------------------
-- p22_sun: the sun in the meniscus (C.P22.sunRim). A pool of 60 ml; the camera on the sun's side, so
-- high that the half-way direction between the sun and the eye leans 25 degrees from upright (the
-- edge facing the sun then mirrors it), and at 15 and 40 degrees; each with the rim's light as it is
-- (broken along the edge, C.P22.sunRimBreak), as one unbroken line, and without
------------------------------------------------------------------------------------------
ST.Add("p22_sun", function()
	local p = FindSpot({ open = 200, outdoor = true })
	Mode(true)
	View(p + Vector(-10, -38, 23), p)
	Client("poolfeed", { pos = p, rate = 3, secs = 20, kind = "drip", jitter = 0.5 })
	Wait(26)
	for _, tilt in ipairs({ 25, 15, 40 }) do
		Client("p22suncam", { pos = p, tilt = tilt, dist = 50 })
		Wait(1.2)
		Client("p22sun", { name = "tilt" .. tilt, pos = p })
		Shot(string.format("sun_%02d_rim", tilt))
		Client("p22set", { name = "sunRimBreak", value = 0 })
		Wait(1.2)
		Shot(string.format("sun_%02d_line", tilt))
		Client("p22set", { name = "sunRimBreak", restore = true })
		Client("p22set", { name = "sunRim", value = 0 })
		Wait(1.2)
		Shot(string.format("sun_%02d_none", tilt))
		Client("p22set", { name = "sunRim", restore = true })
		Wait(0.3)
	end
	Client("stats", { name = "p22_sun" })
	Wait(0.2)
end)

ST.Add("p22_ramp", function()
	local p = FindSpot({ open = 220, outdoor = true })
	Mode(true)
	-- (15 degrees: on these plates a stream runs from about 13, phase 21's exitRun; at 10 the pool only
	-- crept down as a film, run p22_b)
	Ramp(p, 15, "rp22")
end)
