-- Pool mirror (phase 21, C.P21.mirror). The wet surface of a pool is a liquid's: level and smooth, a
-- mirror of what stands over it, as much as Fresnel says for the angle it is seen at (2 % from straight
-- above and still at 45 degrees, 5 % at 30 degrees over the floor, two fifths at ten), over the blood's own colour,
-- which shows through by the rest. What it mirrors is the scene itself: the view mirrored in the
-- floor's plane, drawn into a target of part of the screen's size (C.P21.mirrorScale) and cut at that
-- plane (what lies under the floor would stand in front of what it mirrors), and then laid over the
-- pools' wet parts on screen through the stencil, every place with its own Fresnel by the way the eye
-- looks there. (Until phase 21 the wet part mirrored the map's cubemap of the place, a blur of its
-- surroundings, at most 14 %: no sky, no wall could be seen in a pool.)
-- One plane a frame: the nearest wet pool in view within C.P21.mirrorDist sets it, and every pool that
-- lies in that plane is mirrored; the others keep the cubemap (cl_pools.lua, P.Draw).
--
-- When: the mirrored view is drawn before the scene (RenderScene, from the eye the scene is drawn
-- from), of the plane the pools chose in the frame before (M.Begin, from P.Draw); the pools of this
-- frame lay it over themselves when it is of their plane (M.Mark, M.Composite). Drawn inside the
-- scene, as it was first, the view cost the scene's own state, counted twice in the profiler, and with
-- every character drawn again it held a frame at 50 to 60 ms on the machine it was made on (run
-- p21_after1, 2026-10-20). What it may cost now: entities are left out (C.P21.mirrorEntities), it is
-- drawn every second to fourth frame while views or frames are slow, and stops while the game's frame
-- is slow or the load governor has scaled the addon down (Load).
--
-- Engine facts it rests on (Garry's Mod wiki and this addon's own runs): render.RenderView draws a view
-- into the target that is pushed and clears it first; render.PushCustomClipPlane (with
-- render.EnableClipping) cuts away what lies behind a plane; the stencil buffer is the screen's and is
-- tested per pixel (render.SetStencil*); a view from inside solid (the mirrored eye is under the
-- floor) draws the world but neither the sky nor the 3D skybox. The view drawn into the target is not
-- the screen's size, and cl_lod.lua's L.CaptureView turns it away while M.rendering: no blood is drawn
-- into the mirror's own view (and nothing recurses).

ABL.NoJIT()
ABL.PoolMirror = ABL.PoolMirror or {}
local M = ABL.PoolMirror
local C = ABL.Config
local KP = C.P21
local sqrt, min, max, abs, floor = math.sqrt, math.min, math.max, math.abs, math.floor

M.stats = M.stats or { frames = 0, ms = 0, marked = 0, skipped = 0 }
M.rendering = false

local rt, matRT, matMask, matWhite
local W, H = 0, 0
local skyPath            -- the cubemap of the place of this frame's plane (Choose)
local planeNx, planeNy, planeNz, planeD
local frameDone = -1
local marked = 0
local viewOK = false

-- The target and its materials, for the screen's size now (made once a size: render targets are never
-- freed).
local function Setup()
	local sc = math.Clamp(KP.mirrorScale or 0.5, 0.25, 1)
	local w, h = floor(ScrW() * sc), floor(ScrH() * sc)
	if rt and w == W and h == H then return true end
	-- (one size short of the screen's at the most: a view as large as the screen would count as the
	-- player's own view, L.CaptureView, and draw blood into the mirror)
	if w >= ScrW() then w = ScrW() - 2 end
	if h >= ScrH() then h = ScrH() - 2 end
	rt = GetRenderTargetEx("abl_poolmirror_" .. w .. "x" .. h, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGB888)
	if not rt then return false end
	-- (its alpha is not read: the engine leaves the depth of the scene there, not a cover. The mirror is
	-- laid as dst x (1 - F) + picture x F in two passes that go by colour alone: M.Composite)
	matRT = CreateMaterial("abl_poolmirror_" .. w .. "x" .. h, "UnlitGeneric", {
		["$basetexture"] = rt:GetName(), ["$vertexcolor"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1,
	})
	matWhite = matWhite or CreateMaterial("abl_poolmirror_white", "UnlitGeneric", {
		["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$ignorez"] = 1, ["$nocull"] = 1,
	})
	W, H = w, h
	return true
end

-- The material that marks a pool's wet part in the stencil: the pool's mesh with page B (what is still
-- wet, cl_poolcanvas.lua) as an alpha test. Nothing of its colour is written.
local function Mask()
	if matMask then return matMask end
	local PCV = ABL.PoolCanvas
	if not PCV or not PCV.page then return nil end
	matMask = CreateMaterial("abl_poolmirror_mask_" .. PCV.page, "UnlitGeneric", {
		["$basetexture"] = "abl_poolwet_" .. PCV.page / 2, ["$alphatest"] = 1, ["$alphatestreference"] = 0.35,
		["$vertexalpha"] = 1, ["$nocull"] = 1,
	})
	return matMask
end

------------------------------------------------------------------------------------------
-- The plane, the eye, and what the mirror may cost
------------------------------------------------------------------------------------------
local view = { x = 0, y = 0, drawhud = false, drawviewmodel = false, drawmonitors = false, dopostprocess = false, bloomtone = false }
local vEye, vN, vFwd, vUp = Vector(), Vector(), Vector(), Vector()

-- Whether the mirror is drawn at all: abl_pool_mirror, and the quality it asks for (C.P21.mirrorQuality):
-- a view of the scene more a frame is not for every machine.
M.cv = CreateClientConVar("abl_pool_mirror", "1", true, false, "Wet pools mirror what stands over them, drawn as a second view of the scene (1; at abl_quality " .. tostring(KP.mirrorQuality or 3) .. " and above, and while the game's frame is quick enough), or the map's cubemap as before (0).", 0, 1)

-- The nearest wet pool in view within the reach, and large enough on screen for what it mirrors to be
-- seen (C.P21.mirrorPx pixels across), sets the plane of this frame's mirror (pools: the list of
-- cl_pools.lua). Returns whether there is one.
local function Choose(pools)
	local L = ABL.LOD
	local reach = KP.mirrorDist or 700
	local minPx = KP.mirrorPx or 30
	local best, bd
	for i = 1, #pools do
		local p = pools[i]
		if p.sim and p.slot and p.painted and p.pcanvas and p.fade > 0.5 and p.look.wetMode ~= "dry" and p.wet > 0 then
			local d2, vis = L.View(p.cx, p.cy, p.cz, p.rad)
			-- (how wide it is on screen: what it covers, as a disc, at its distance)
			local g = p.sim
			local wide = g and 2 * sqrt(g.wetN * g.a * g.a / math.pi) or 0
			local px = wide * (L.pxK or 1000) / max(sqrt(d2), 1)
			if vis and px >= minPx and d2 < reach * reach and (not bd or d2 < bd) then
				-- (seen from above it, not from under the floor)
				local ex, ey, ez = L.eyeX - p.x, L.eyeY - p.y, L.eyeZ - p.z
				if ex * p.nx + ey * p.ny + ez * p.nz > 0.5 then best, bd = p, d2 end
			end
		end
	end
	if not best then return false end
	planeNx, planeNy, planeNz = best.nx, best.ny, best.nz
	-- (the cubemap of the place, for the sky: Dome)
	if best.envPath == nil then best.envPath = ABL.Render.Cubemap(best.cx, best.cy, best.cz + 8) or false end
	skyPath = best.envPath or nil
	-- (the plane through the pool's surface: its origin lies on the floor, the layer a little above)
	planeD = best.x * best.nx + best.y * best.ny + best.z * best.nz
	return true
end

-- Is pool p in this frame's plane (within half a unit, facing the same way)?
function M.OnPlane(p)
	if not viewOK or not planeD then return false end
	if p.nx * planeNx + p.ny * planeNy + p.nz * planeNz < 0.996 then return false end
	return abs(p.x * planeNx + p.y * planeNy + p.z * planeNz - planeD) < 0.5
end

-- The eye of this frame's scene: where it is, its forward, right and up, and the tangents of half its
-- field of view across and up (Basis, from the view the scene is drawn with). M.Mark and M.Composite
-- work with these numbers and make nothing.
local eX, eY, eZ = 0, 0, 0
local fX, fY, fZ, rX, rY, rZ, uX, uY, uZ = 1, 0, 0, 0, -1, 0, 0, 0, 1
local tanX, tanY, aspect = 1, 0.5625, 16 / 9
local curVs
local function Basis(vs)
	local e, a = vs.origin, vs.angles
	local f, r, u = a:Forward(), a:Right(), a:Up()
	eX, eY, eZ = e.x, e.y, e.z
	fX, fY, fZ, rX, rY, rZ, uX, uY, uZ = f.x, f.y, f.z, r.x, r.y, r.z, u.x, u.y, u.z
	aspect = (vs.aspect and vs.aspect > 0) and vs.aspect or ScrW() / ScrH()
	tanX = math.tan(math.rad(math.Clamp(vs.fov or 75, 1, 170)) * 0.5)
	tanY = tanX / aspect
end

-- What the GPU spends on the view shows in the game's frame time and nowhere in Lua (the view is
-- handed over and drawn while Lua goes on). While the frame is slower than C.P21.mirrorFrameOff
-- (smoothed), or the load governor has scaled the addon's work under a half (cl_lod.lua), for a
-- second, the mirror stops and the pools mirror the map's cubemap as before; it comes back once frames
-- have been quicker than mirrorFrameOn for a second and its wait is over: 4 s, twice that each time it
-- had to stop again within 30 s of coming back, 64 at the most. Returns whether it may be drawn.
local ftEma, overT, okT, lastT = 1 / 60, 0, 0, 0
local cut, cutUntil, cutWait, onSince = false, 0, 4, -100
local function Load(now)
	local ft = RealFrameTime()
	if ft > 0 and ft < 0.5 then ftEma = ftEma + (ft - ftEma) * 0.05 end
	local dt = now - lastT
	lastT = now
	if dt > 0.5 or dt < 0 then dt, overT, okT = 0, 0, 0 end
	local scale = ABL.LOD.scale or 1
	if not cut then
		if ftEma > (KP.mirrorFrameOff or 1 / 40) or scale < 0.5 then overT = overT + dt else overT = 0 end
		if overT > 1 then
			cut, overT, okT = true, 0, 0
			cutWait = (now - onSince < 30) and min(cutWait * 2, 64) or 4
			cutUntil = now + cutWait
			M.stats.cuts = (M.stats.cuts or 0) + 1
		end
	else
		if ftEma < (KP.mirrorFrameOn or 1 / 52) and scale >= 0.75 then okT = okT + dt else okT = 0 end
		if now >= cutUntil and okT > 1 then cut, onSince, okT = false, now, 0 end
	end
	return not cut
end

-- The plane the next view is to mirror (M.Begin, for the view before the next scene: M.Render) and
-- the plane of the picture there is (drawn in frame picFrame).
local want, wantFrame = false, -100
local wNx, wNy, wNz, wD, wSky = 0, 0, 1, 0, nil
local picFrame, picOK = -100, false
local pNx, pNy, pNz, pD = 0, 0, 1, 0
local every = 1
local sceneFrame = -100          -- the last frame RenderScene reached this addon in
local function SamePlane(ax, ay, az, ad, bx, by, bz, bd)
	return ax * bx + ay * by + az * bz >= 0.996 and abs(ad - bd) < 0.5
end

-- (the part of the screen the pools marked this frame cover, as fractions across and down: M.Mark)
local rx0, ry0, rx1, ry1 = 1, 1, 0, 0

-- This frame's mirror (from P.Draw, before any pool is drawn): chooses the plane of the next view, and
-- says whether there is a picture of this frame's plane to lay over its pools. Once a frame.
function M.Begin(pools)
	local fn = FrameNumber()
	if frameDone == fn then return viewOK end
	frameDone = fn
	viewOK, marked, want = false, 0, false
	if not M.cv:GetBool() or C.cl.quality:GetInt() < (KP.mirrorQuality or 3) then return false end
	if not Load(RealTime()) then return false end
	if not Choose(pools) then return false end
	local vs = render.GetViewSetup()
	if not vs or not vs.origin or not vs.angles then return false end
	curVs = vs
	Basis(vs)
	want, wantFrame = true, fn
	wNx, wNy, wNz, wD, wSky = planeNx, planeNy, planeNz, planeD, skyPath
	-- (a scene drawn without RenderScene reaching this addon, the frame before: another addon's hook
	-- there that answers for the scene stops the hooks after it. Z-City has one, "jopa", which the test
	-- harness takes away while it runs. Then the view is drawn here, inside the scene, before any pool)
	if fn - sceneFrame > 1 then
		M.stats.inScene = (M.stats.inScene or 0) + 1
		M.Render(vs.origin, vs.angles)
	end
	-- (a picture of this plane, drawn before this scene or up to three frames before)
	if not picOK or fn - picFrame > 3 or not SamePlane(pNx, pNy, pNz, pD, planeNx, planeNy, planeNz, planeD) then return false end
	viewOK = true
	rx0, ry0, rx1, ry1 = 1, 1, 0, 0
	-- (the stencil: nothing marked yet this frame)
	render.ClearStencil()
	return true
end

------------------------------------------------------------------------------------------
-- The mirrored view, before the scene
------------------------------------------------------------------------------------------
-- The sky round the mirrored eye: a dome of the directions over the floor (and a little under its
-- horizon), each place showing the map's cubemap of the place the way one looks there. A material's
-- cubemap is read along the eye's ray mirrored about the surface's normal, so each corner of the
-- dome is given a normal across its own direction (then the mirrored ray is the ray itself). Such
-- normals cannot be laid on a whole dome without a place where they turn round (a hairy ball): here
-- that is at the horizon to either side of the way the eye looks, which no ray that the eye sees
-- mirrored in a floor ever reaches. Built once in a frame of its own (x forward along the floor, y to
-- the left, z up out of it), turned into the world's by the model matrix.
local dome
local GA, GE = 32, 10           -- corners round, and up from 12 degrees under the horizon to the top
local function BuildDome()
	local function Corner(ia, ie)
		local az = ia / GA * math.pi * 2
		local el = math.rad(-12 + (90 + 12) * ie / GE)
		local ce = math.cos(el)
		local x, y, z = ce * math.cos(az), ce * math.sin(az), math.sin(el)
		-- (a tangent across the direction: d/dx of the dome's height over the floor's plane)
		local tx, tz = z, -x
		local tl = sqrt(tx * tx + tz * tz)
		if tl < 1e-4 then tx, tz, tl = 1, 0, 1 end
		return x, y, z, tx / tl, 0, tz / tl
	end
	dome = Mesh()
	mesh.Begin(dome, MATERIAL_QUADS, GA * GE)
	local v, nv = Vector(), Vector()
	for ie = 0, GE - 1 do
		for ia = 0, GA - 1 do
			for c = 1, 4 do
				local a, e = ia + ((c == 2 or c == 3) and 1 or 0), ie + ((c >= 3) and 1 or 0)
				local x, y, z, nx, ny, nz = Corner(a, e)
				v:SetUnpacked(x, y, z)
				nv:SetUnpacked(nx, ny, nz)
				mesh.Position(v)
				mesh.Normal(nv)
				mesh.TexCoord(0, 0, 0)
				mesh.Color(255, 255, 255, 255)
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()
end

-- (one material a cubemap: the cubemap alone, base black)
local skyMats, skyN = {}, 0
local function SkyMat(path)
	local key = path or "env_cubemap"
	local m = skyMats[key]
	if m then return m end
	skyN = skyN + 1
	m = CreateMaterial("abl_poolmirror_sky" .. skyN, "UnlitGeneric", {
		["$basetexture"] = "vgui/white", ["$color"] = "[0 0 0]", ["$envmap"] = key, ["$envmaptint"] = "[1 1 1]", ["$nocull"] = 1,
	})
	skyMats[key] = m
	return m
end

local domeM, domeT = Matrix(), Vector()
local function Dome(eye, ang, fov, znear, zf, nx, ny, nz, sky)
	if not dome then BuildDome() end
	-- (the dome's frame: x the eye's way along the floor, z out of the floor)
	local f = ang:Forward()
	local fx, fy, fz = f.x, f.y, f.z
	local fd = fx * nx + fy * ny + fz * nz
	fx, fy, fz = fx - fd * nx, fy - fd * ny, fz - fd * nz
	local fl = sqrt(fx * fx + fy * fy + fz * fz)
	if fl < 1e-3 then
		local u = ang:Up()
		local ud = u.x * nx + u.y * ny + u.z * nz
		fx, fy, fz = u.x - ud * nx, u.y - ud * ny, u.z - ud * nz
		fl = sqrt(fx * fx + fy * fy + fz * fz)
		if fl < 1e-3 then fx, fy, fz, fl = 1, 0, 0, 1 end
	end
	fx, fy, fz = fx / fl, fy / fl, fz / fl
	local lx, ly, lz = ny * fz - nz * fy, nz * fx - nx * fz, nx * fy - ny * fx
	local R = min(zf * 0.5, 16000)
	domeM:Identity()
	domeM:SetField(1, 1, fx * R) domeM:SetField(1, 2, lx * R) domeM:SetField(1, 3, nx * R)
	domeM:SetField(2, 1, fy * R) domeM:SetField(2, 2, ly * R) domeM:SetField(2, 3, ny * R)
	domeM:SetField(3, 1, fz * R) domeM:SetField(3, 2, lz * R) domeM:SetField(3, 3, nz * R)
	domeT:SetUnpacked(eye.x, eye.y, eye.z)
	domeM:SetTranslation(domeT)
	cam.Start3D(eye, ang, fov, 0, 0, W, H, znear, zf)
	-- (behind everything the view drew: tested against its depth, writing none)
	render.OverrideDepthEnable(true, false)
	cam.PushModelMatrix(domeM)
	render.SetMaterial(SkyMat(sky))
	dome:Draw()
	cam.PopModelMatrix()
	render.OverrideDepthEnable(false)
	cam.End3D()
end

-- What the mirror's view leaves out: every entity (characters, ragdolls, props), unless
-- C.P21.mirrorEntities. A character drawn again is Z-City's whole renderer again (its body, clothes,
-- worn things): with five bots standing about the mirror cost 3.9 ms a frame on average, 45 at the
-- worst, against about 0.6 ms for the world and the sky alone (run p21_after1, 2026-10-20). The
-- world's brushes and the sky stay in it (the map's static props go with the entities: the hook leaves
-- out all opaque renderables at once).
local function SkipEnts()
	if M.rendering and not KP.mirrorEntities then return true end
end
hook.Add("PreDrawOpaqueRenderables", "ABL_PoolMirrorSkip", SkipEnts)
hook.Add("PreDrawTranslucentRenderables", "ABL_PoolMirrorSkip", SkipEnts)
hook.Add("PrePlayerDraw", "ABL_PoolMirrorSkip", SkipEnts)
hook.Add("PreDrawHalos", "ABL_PoolMirrorSkip", SkipEnts)

-- The mirrored view of the plane the pools chose in the frame before, from the eye the scene is about
-- to be drawn from (origin, angles: RenderScene), into the target. Drawn every frame while it costs
-- little; every second, third or fourth (the picture of the frames before is laid meanwhile) while a
-- view costs more than C.P21.mirrorMs, while the game's frame is slow, or while the load governor has
-- scaled the addon's work down. A view of another plane is drawn at once.
function M.Render(origin, angles)
	local fn = FrameNumber()
	if not want or fn - wantFrame > 1 or not curVs then return end
	local same = picOK and SamePlane(pNx, pNy, pNz, pD, wNx, wNy, wNz, wD)
	every = math.ceil(M.stats.ms / (KP.mirrorMs or 0.8))
	if ftEma > 1 / 55 then every = max(every, 2) end
	if ftEma > 1 / 45 or (ABL.LOD.scale or 1) < 0.75 then every = max(every, 3) end
	every = math.Clamp(every, 1, 4)
	if same and fn - picFrame < every then
		M.stats.reused = (M.stats.reused or 0) + 1
		return
	end
	if not Setup() then return end
	local vs = curVs
	local t0 = SysTime()
	local nx, ny, nz, d = wNx, wNy, wNz, wD
	-- the eye mirrored in the plane
	local e, a = origin, angles
	local s = e.x * nx + e.y * ny + e.z * nz - d
	vEye:SetUnpacked(e.x - 2 * s * nx, e.y - 2 * s * ny, e.z - 2 * s * nz)
	-- the way it looks, mirrored; its up mirrored and turned over (a camera cannot be mirrored: this
	-- one sees the mirror's picture upside down, and the picture is read so: M.Composite)
	local f, u = a:Forward(), a:Up()
	local fd, ud = f.x * nx + f.y * ny + f.z * nz, u.x * nx + u.y * ny + u.z * nz
	vFwd:SetUnpacked(f.x - 2 * fd * nx, f.y - 2 * fd * ny, f.z - 2 * fd * nz)
	vUp:SetUnpacked(-(u.x - 2 * ud * nx), -(u.y - 2 * ud * ny), -(u.z - 2 * ud * nz))
	local ang = vFwd:AngleEx(vUp)
	local fov, znear, zfar = vs.fov or 75, vs.znear or 3, vs.zfar or 30000
	view.origin, view.angles = vEye, ang
	view.w, view.h = W, H
	view.fov = fov
	view.aspect = aspect
	view.znear, view.zfar = znear, zfar
	-- (cut at the plane: only what is over the floor is mirrored; a tenth of a unit over it, so that the
	-- floor itself is not)
	vN:SetUnpacked(nx, ny, nz)
	M.rendering = true
	local clip = M.clipMode and M.clipMode:GetInt() or 1
	local skyMode = M.skyMode and M.skyMode:GetInt() or 1
	local ok, err = pcall(function()
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 255, true, true)
		local was
		if clip ~= 0 then
			was = render.EnableClipping(true)
			if clip > 0 then
				render.PushCustomClipPlane(vN, d + 0.1)
			else
				render.PushCustomClipPlane(-vN, -(d + 0.1))
			end
		end
		render.RenderView(view)
		if clip ~= 0 then
			render.PopCustomClipPlane()
			render.EnableClipping(was)
		end
		-- The sky. The mirrored eye lies under the floor, inside the ground, and from there the engine
		-- draws the world but neither the sky nor the map's 3D skybox (a view from inside solid sees no
		-- sky; a second view from the eye itself, drawn first, is cleared by the next and costs as much
		-- again). So the sky is laid in afterwards where the view found nothing: a dome round the
		-- mirrored eye, depth-tested against what the view drew, showing the map's own cubemap of the
		-- place each way one looks (Dome).
		if skyMode >= 1 then Dome(vEye, ang, fov, znear, zfar, nx, ny, nz, wSky) end
		render.PopRenderTarget()
	end)
	M.rendering = false
	if not ok then
		ABL.Print("pool mirror: the mirrored view failed: %s", tostring(err))
		M.failed = (M.failed or 0) + 1
		picOK = false
		return
	end
	picFrame, picOK = fn, true
	pNx, pNy, pNz, pD = nx, ny, nz, d
	local ms = (SysTime() - t0) * 1000
	M.stats.frames = M.stats.frames + 1
	M.stats.ms = M.stats.ms * 0.9 + ms * 0.1
	ABL.Prof.Add("draw.poolmirror", ms * 0.001)
end

-- (before the scene: the classic place for a view into a target, from the scene's own eye. Whether
-- it was reached is kept: M.Begin draws the view itself in a frame that came without it)
hook.Add("RenderScene", "ABL_PoolMirror", function(origin, angles)
	sceneFrame = FrameNumber()
	if want and ABL.Enabled() and M.cv:GetBool() then M.Render(origin, angles) end
end)

------------------------------------------------------------------------------------------
-- The pools that lay it over themselves
------------------------------------------------------------------------------------------
-- Pool p's wet part, where it is seen (the depth test), into the stencil: value 1. And the part of the
-- screen it can cover (its bounding sphere, by the tangents from the eye: exact for a sphere), for the
-- composite to cover no more than that.
function M.Mark(p)
	local mat = Mask()
	if not mat or not p.mesh then return end
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCIL_ALWAYS)
	render.SetStencilPassOperation(STENCIL_REPLACE)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, false)
	render.SetMaterial(mat)
	p.mesh:Draw()
	render.OverrideDepthEnable(false)
	render.OverrideAlphaWriteEnable(false, true)
	render.OverrideColorWriteEnable(false, true)
	render.SetStencilEnable(false)
	marked = marked + 1
	local dx, dy, dz = p.cx - eX, p.cy - eY, p.cz - eZ
	local Z = dx * fX + dy * fY + dz * fZ
	local R = p.rad or 64
	if Z - R < 4 then
		-- (the eye within it, or nearly: all of the screen)
		rx0, ry0, rx1, ry1 = 0, 0, 1, 1
		return
	end
	local X = dx * rX + dy * rY + dz * rZ
	local Y = dx * uX + dy * uY + dz * uZ
	local den = Z * Z - R * R
	local sx, sy = R * sqrt(X * X + den), R * sqrt(Y * Y + den)
	local a0, a1 = 0.5 + 0.5 * (X * Z - sx) / den / tanX, 0.5 + 0.5 * (X * Z + sx) / den / tanX
	local b0, b1 = 0.5 - 0.5 * (Y * Z + sy) / den / tanY, 0.5 - 0.5 * (Y * Z - sy) / den / tanY
	if a0 < rx0 then rx0 = a0 end
	if a1 > rx1 then rx1 = a1 end
	if b0 < ry0 then ry0 = b0 end
	if b1 > ry1 then ry1 = b1 end
end

-- The mirror laid over what is marked: a grid over the part of the screen the marked pools cover,
-- each corner with the reflectance of a liquid at the angle the eye looks through it onto the plane
-- (Schlick, n ~ 1.35) and with the place of the picture that mirrors it (upside down: M.Render). At
-- most GXM x GYM cells (a cell about a sixteenth of the screen across: Fresnel changes slowly over
-- that), fewer for a pool small on screen. Drawn where the stencil says a pool's wet part is.
local GXM, GYM = 16, 9
local pv = Vector()
local gx, gy, gu, gv, k1, k2 = {}, {}, {}, {}, {}, {}
function M.Composite()
	if not viewOK or marked == 0 then return end
	local sw, sh = ScrW(), ScrH()
	local dbg = M.debug and M.debug:GetInt() or 0
	local x0, y0 = max(rx0 - 0.01, 0), max(ry0 - 0.01, 0)
	local x1, y1 = min(rx1 + 0.01, 1), min(ry1 + 0.01, 1)
	-- (developer, abl_pool_mirror_debug 3: half of it over all of the screen, no stencil: where the floor
	-- meets a wall, and the horizon, the picture must meet what it mirrors)
	if dbg >= 3 then x0, y0, x1, y1 = 0, 0, 1, 1 end
	if x1 <= x0 or y1 <= y0 then return end
	local GX = math.Clamp(math.ceil(GXM * (x1 - x0)), 2, GXM)
	local GY = math.Clamp(math.ceil(GYM * (y1 - y0)), 2, GYM)
	local cap = KP.mirrorMax or 0.85
	-- (phase 22, C.P22.mirrorK: the share of Fresnel's reflectance laid over the pools)
	local share = (C.P22On ~= nil and C.P22On("mirrorK")) and (C.P22.mirrorK or 1) or 1
	local nx, ny, nz = planeNx, planeNy, planeNz
	-- (the ray through a place of the screen: forward + right x its across + up x its up, in tangents of
	-- the view's angles; what the plane's normal makes of the forward, right and up part is taken once)
	local fn_, rn, un = fX * nx + fY * ny + fZ * nz, rX * nx + rY * ny + rZ * nz, uX * nx + uY * ny + uZ * nz
	for j = 0, GY do
		local y = y0 + (y1 - y0) * j / GY
		local sy = (1 - 2 * y) * tanY
		for i = 0, GX do
			local x = x0 + (x1 - x0) * i / GX
			local sx = (2 * x - 1) * tanX
			local c = abs(fn_ + rn * sx + un * sy) / sqrt(1 + sx * sx + sy * sy)
			local k = 1 - c
			local F = (0.022 + 0.978 * k * k * k * k * k) * share
			if F > cap then F = cap end
			if dbg >= 3 then F = 0.5 end
			local q = j * (GX + 1) + i + 1
			-- dst x (1 - F), then + picture x F. Vertex colours are display values and the blend is done
			-- in linear light: each is the power 1/2.2 of what it stands for
			gx[q], gy[q], gu[q], gv[q] = x * sw, y * sh, x, 1 - y
			k1[q], k2[q] = (1 - F) ^ 0.4545 * 255, F ^ 0.4545 * 255
		end
	end
	render.SetStencilEnable(dbg < 3)
	render.SetStencilTestMask(255)
	render.SetStencilWriteMask(0)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)
	cam.Start2D()
	-- (developer, abl_pool_mirror_debug 2: where the stencil lets it through within the part covered, in
	-- magenta: a pool cut straight would be a part the cover missed)
	if dbg == 2 then
		surface.SetDrawColor(255, 0, 255, 160)
		surface.DrawRect(x0 * sw, y0 * sh, (x1 - x0) * sw, (y1 - y0) * sh)
	end
	-- (by colour alone: the target's alpha holds what the engine leaves there, the depth of the scene,
	-- not a cover)
	for pass = 1, 2 do
		local kk
		if pass == 1 then
			kk = k1
			render.SetMaterial(matWhite)
			render.OverrideBlend(true, BLEND_ZERO, BLEND_SRC_COLOR, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		else
			kk = k2
			render.SetMaterial(matRT)
			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		end
		mesh.Begin(MATERIAL_QUADS, GX * GY)
		for j = 0, GY - 1 do
			for i = 0, GX - 1 do
				local q0 = j * (GX + 1) + i + 1
				for c = 1, 4 do
					local q = q0 + ((c == 2 or c == 3) and 1 or 0) + (c >= 3 and GX + 1 or 0)
					pv:SetUnpacked(gx[q], gy[q], 0)
					mesh.Position(pv)
					mesh.TexCoord(0, gu[q], gv[q])
					local k = kk[q]
					mesh.Color(k, k, k, 255)
					mesh.AdvanceVertex()
				end
			end
		end
		mesh.End()
	end
	render.OverrideBlend(false)
	render.SetStencilEnable(false)
	-- (developer, abl_pool_mirror_debug 1 and 2: the picture itself in a corner, the right way up, and
	-- what the mirror did this frame; 2: the part of the screen covered, outlined)
	if dbg >= 1 then
		if dbg == 2 then
			surface.SetDrawColor(255, 255, 0, 255)
			surface.DrawOutlinedRect(x0 * sw, y0 * sh, (x1 - x0) * sw, (y1 - y0) * sh, 2)
		end
		local w = sw * 0.3
		local h = w * H / W
		render.SetMaterial(matRT)
		mesh.Begin(MATERIAL_QUADS, 1)
		for c = 1, 4 do
			local ii, jj = (c == 2 or c == 3) and 1 or 0, (c >= 3) and 1 or 0
			pv:SetUnpacked(10 + w * ii, 10 + h * jj, 0)
			mesh.Position(pv)
			mesh.TexCoord(0, ii, 1 - jj)
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end
		mesh.End()
		draw.SimpleText(M.Info(), "DermaDefault", 10, h + 14, Color(255, 255, 0))
	end
	cam.End2D()
	M.stats.marked = M.stats.marked + marked
	M.stats.cells = (M.stats.cells or 0) + GX * GY
end

-- (developer) What the mirror has done.
function M.Info()
	return string.format("mirror: %d views drawn (%d frames without RenderScene: from inside the scene), %d laid again, %.2f ms a view on average (last ones), every %d, %d pools marked, %d grid cells laid, target %dx%d, frame %.1f ms (smoothed), %d stops%s%s | this frame: view %s, %d marked, plane %s",
		M.stats.frames, M.stats.inScene or 0, M.stats.reused or 0, M.stats.ms, every, M.stats.marked, M.stats.cells or 0, W, H, ftEma * 1000, M.stats.cuts or 0,
		cut and string.format(", stopped for %.0f s more", max(cutUntil - RealTime(), 0)) or "",
		M.failed and string.format(", %d failed", M.failed) or "",
		tostring(viewOK), marked, planeD and string.format("(%.2f %.2f %.2f) %.1f", planeNx, planeNy, planeNz, planeD) or "none")
end

-- (developer) abl_pool_mirror_debug 1: the mirror's picture in a corner of the screen, as drawn (the
-- right way up: it is drawn upside down, M.Render), and what the mirror did this frame; 2: besides,
-- where the stencil lets the mirror through within the part of the screen covered is laid over in
-- magenta, and that part outlined; 3: the picture at one half over all of the screen (alignment).
M.debug = CreateClientConVar("abl_pool_mirror_debug", "0", false, false, "Pool mirror developer view: 1 its picture in a corner, 2 also where it is laid (magenta) and the part of the screen covered, 3 the picture at half over the whole screen.", 0, 3)
-- (developer: the plane that cuts the mirror's view, as it is (1), the other way round (-1), none (0))
M.clipMode = CreateClientConVar("abl_pool_mirror_clip", "1", false, false, "Pool mirror developer switch: the cut at the floor's plane as it is (1), turned round (-1), none (0).", -1, 1)
-- (developer: the sky laid in where the view found nothing, from the map's cubemap (1), or none (0))
M.skyMode = CreateClientConVar("abl_pool_mirror_sky", "1", false, false, "Pool mirror developer switch: the sky laid in from the map's cubemap (1), or none (0).", 0, 1)
