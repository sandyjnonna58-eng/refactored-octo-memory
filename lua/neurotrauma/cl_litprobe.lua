-- Client: a probe of what the engine does with a mesh made in Lua under a lit material (developer
-- tool, scene neuro_litprobe). Inert unless garrysmod/data/abl_selftest.txt exists on this machine.
--
-- A grid of spheres: every row one way of giving a mesh its light, every column one material or
-- transform. What comes out lit, with a highlight, with relief, tinted, is read off the picture and
-- off the brightness the probe measures at three points of every sphere. The developer's brain
-- (cl_brain3d.lua) is drawn the way this probe found to work.

NeuroTrauma.NoJIT()
if not NeuroTrauma.testRun then return end
local NT = NeuroTrauma
NT.LitProbe = NT.LitProbe or {}
local LP = NT.LitProbe
local OUT = "abl_test/client_neuro.txt"
local sin, cos, pi, floor = math.sin, math.cos, math.pi, math.floor

local function Log(s)
	file.CreateDir("abl_test")
	file.Append(OUT, string.format("%8.2f litprobe: %s\n", CurTime(), s))
end

local function SphereTris(r, nu, nv, uTile, vTile)
	local rows = {}
	for i = 0, nv do
		local phi = i / nv * pi
		rows[i] = {}
		for j = 0, nu do
			local th = j / nu * 2 * pi
			local nx, ny, nz = sin(phi) * cos(th), sin(phi) * sin(th), cos(phi)
			rows[i][j] = { pos = Vector(nx * r, ny * r, nz * r), normal = Vector(nx, ny, nz), u = j / nu * uTile, v = i / nv * vTile,
				userdata = { -sin(th), cos(th), 0, -1 }, color = Color(255 * (0.5 + 0.5 * nx), 255 * (0.5 + 0.5 * ny), 255 * (0.5 + 0.5 * nz), 255) }
		end
	end
	local tris = {}
	for i = 0, nv - 1 do
		for j = 0, nu - 1 do
			local a, b, c, d = rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]
			tris[#tris + 1] = a tris[#tris + 1] = b tris[#tris + 1] = c
			tris[#tris + 1] = a tris[#tris + 1] = c tris[#tris + 1] = d
		end
	end
	return tris
end

local R = 9
local meshes, mats, variants, carrier, dummy, paint
local serial = 0
local function Mat(name, shader, kv)
	serial = serial + 1
	return CreateMaterial(string.format("nt_lp_%s_%d_%d", name, serial, floor(SysTime() * 1000) % 100000), shader, kv)
end

local METHODS = { "none", "direct", "dummy", "ent" }

local function Setup()
	if meshes then return end
	meshes = {}
	local t0 = SysTime()
	local tris = SphereTris(R, 48, 32, 4, 2)
	meshes.one = Mesh()
	meshes.one:BuildFromTriangles(tris)
	Log(string.format("a sphere of %d triangles with normals and tangents: built in %.1f ms", #tris / 3, (SysTime() - t0) * 1000))
	meshes.small = Mesh()
	meshes.small:BuildFromTriangles(SphereTris(R / 8, 48, 32, 4, 2))
	t0 = SysTime()
	local big = SphereTris(R, 144, 70, 4, 2)
	local tb = SysTime()
	local m = Mesh()
	m:BuildFromTriangles(big)
	Log(string.format("%d triangles: the tables in %.0f ms, the mesh in %.0f ms", #big / 3, (tb - t0) * 1000, (SysTime() - tb) * 1000))
	m:Destroy()

	for _, name in ipairs({ "dev/flat_normal", "models/debug/debugwhite", "neurotrauma/probe/bump_n", "neurotrauma/probe/warp", "neurotrauma/probe/env" }) do
		Log(string.format("texture %s: %s", name, tostring(file.Exists("materials/" .. name .. ".vtf", "GAME"))))
	end
	local s = file.Read("data_static/neurotrauma/probe.dat", "GAME")
	if s then
		local sum = 0
		for i = 1, #s do sum = sum + string.byte(s, i) end
		Log(string.format("data file: %d bytes, bytes 1, 2, 256, 257, 1024 = %d %d %d %d %d, sum %d (should be 1024 bytes, 0 1 255 0 255, 130560)", #s,
			string.byte(s, 1) or -1, string.byte(s, 2) or -1, string.byte(s, 256) or -1, string.byte(s, 257) or -1, string.byte(s, 1024) or -1, sum))
	else
		Log("data file: not readable from the GAME path")
	end

	-- the paint: a small target with coloured cells, to be multiplied over a surface
	paint = GetRenderTarget("nt_lp_paint", 64, 64)
	render.PushRenderTarget(paint)
	render.Clear(128, 128, 128, 255, true, true)
	cam.Start2D()
	for y = 0, 7 do
		for x = 0, 7 do
			local k = (x + y) % 4
			if k == 0 then surface.SetDrawColor(128, 20, 20, 255) elseif k == 1 then surface.SetDrawColor(20, 128, 30, 255) elseif k == 2 then surface.SetDrawColor(128, 128, 128, 255) else surface.SetDrawColor(30, 40, 128, 255) end
			surface.DrawRect(x * 8, y * 8, 8, 8)
		end
	end
	cam.End2D()
	render.PopRenderTarget()

	local W = "models/debug/debugwhite"
	local B = "neurotrauma/probe/bump_n"
	local function Lit(extra)
		local kv = { ["$basetexture"] = W, ["$nocull"] = 1 }
		for k, v in pairs(extra or {}) do kv[k] = v end
		return kv
	end
	local PH = { ["$phong"] = 1, ["$phongexponent"] = 25, ["$phongboost"] = 6, ["$phongfresnelranges"] = "[1 1 1]" }
	local function Phong(extra)
		local kv = Lit(PH)
		kv["$bumpmap"] = B
		for k, v in pairs(extra or {}) do kv[k] = v end
		return kv
	end
	variants = {
		{ "plain", Mat("plain", "VertexLitGeneric", Lit()) },
		{ "phong, flat normal map", Mat("phflat", "VertexLitGeneric", Phong({ ["$bumpmap"] = "dev/flat_normal" })) },
		{ "phong, no normal map", Mat("phnone", "VertexLitGeneric", Lit(PH)) },
		{ "phong, normal map", Mat("phbump", "VertexLitGeneric", Phong()) },
		{ "cube map", Mat("env", "VertexLitGeneric", Lit({ ["$envmap"] = "neurotrauma/probe/env", ["$envmaptint"] = "[1 1 1]" })) },
		{ "cube map, normal map, masked by its alpha", Mat("envbump", "VertexLitGeneric", Lit({ ["$bumpmap"] = B, ["$envmap"] = "neurotrauma/probe/env", ["$envmaptint"] = "[1 1 1]", ["$normalmapalphaenvmapmask"] = 1 })) },
		{ "detail: the paint, multiplied", Mat("detail", "VertexLitGeneric", Lit({ ["$detail"] = W, ["$detailscale"] = 1, ["$detailblendmode"] = 0, ["$detailblendfactor"] = 1 })), detail = true },
		{ "detail with phong and normal map", Mat("detailph", "VertexLitGeneric", Phong({ ["$detail"] = W, ["$detailscale"] = 1, ["$detailblendmode"] = 0, ["$detailblendfactor"] = 1 })), detail = true },
		{ "$color2 green, set at the draw", Mat("color2", "VertexLitGeneric", Phong()), color2 = Vector(0.2, 1, 0.3) },
		{ "drawn at eight times its size", Mat("scale8", "VertexLitGeneric", Phong()), mesh = "small", scale = Vector(8, 8, 8) },
		{ "stretched 1.3, 1, 0.75", Mat("aniso", "VertexLitGeneric", Phong()), scale = Vector(1.3, 1, 0.75) },
		{ "translucent 0.35", Mat("alpha", "VertexLitGeneric", Phong({ ["$alpha"] = 0.35, ["$translucent"] = 1 })) },
		{ "light warp", Mat("warp", "VertexLitGeneric", Phong({ ["$lightwarptexture"] = "neurotrauma/probe/warp" })) },
		{ "rim light", Mat("rim", "VertexLitGeneric", Phong({ ["$rimlight"] = 1, ["$rimlightexponent"] = 3, ["$rimlightboost"] = 2 })) },
		{ "unlit, vertex colours", Mat("unlit", "UnlitGeneric", { ["$basetexture"] = W, ["$vertexcolor"] = 1, ["$nocull"] = 1 }) },
		{ "unlit, cube map", Mat("unlitenv", "UnlitGeneric", { ["$basetexture"] = W, ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$envmap"] = "neurotrauma/probe/env", ["$envmaptint"] = "[1 1 1]" }) },
	}
	for i, v in ipairs(variants) do
		if v.detail then v[2]:SetTexture("$detail", paint) end
		Log(string.format("column %d: %s", i, v[1]))
	end
	for i, m2 in ipairs(METHODS) do Log(string.format("row %d: %s", i, m2)) end

	-- the carrier: a scripted entity that hands the engine a mesh instead of its model
	local ENT = { Type = "anim", Base = "base_anim" }
	function ENT:GetRenderMesh() return self.NT_rm end
	function ENT:Draw() end
	scripted_ents.Register(ENT, "nt_lp_carrier")
	-- (Found in run lp1: an entity cannot be made while the game is drawing, "ents.Create cannot
	-- be called while rendering", and this is called from a hook that draws; the engine says so
	-- on the console whether the call is guarded or not. So no carrier is made any more: its row
	-- stays empty. The row that needs none is the one the brain is drawn like.)
	carrier = nil
	dummy = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl")
	if IsValid(dummy) then
		dummy:SetNoDraw(true)
		dummy:SetModelScale(0.02, 0)
	end
	Log(string.format("carrier %s, dummy %s", tostring(IsValid(carrier)), tostring(IsValid(dummy))))
end

local LIGHT = { type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1.3, 1.25, 1.2), dir = Vector(0.6, -0.5, -0.6):GetNormalized() }
local function Lights(on, at)
	render.SuppressEngineLighting(on)
	if on then
		render.SetLightingOrigin(at)
		render.ResetModelLighting(0.07, 0.07, 0.09)
		render.SetLocalModelLights({ LIGHT })
	else
		render.SetLocalModelLights()
	end
end

local M = Matrix()
local function DrawOne(method, v, pos)
	local mat = v[2]
	local msh = meshes[v.mesh or "one"]
	if v.color2 then mat:SetVector("$color2", v.color2) end
	M:Identity()
	M:SetTranslation(pos)
	if v.scale then M:Scale(v.scale) end
	if method == "none" then
		render.SetMaterial(mat)
		cam.PushModelMatrix(M)
		msh:Draw()
		cam.PopModelMatrix()
	elseif method == "direct" then
		Lights(true, pos)
		render.SetMaterial(mat)
		cam.PushModelMatrix(M)
		msh:Draw()
		cam.PopModelMatrix()
		Lights(false)
	elseif method == "dummy" then
		Lights(true, pos)
		if IsValid(dummy) then
			dummy:SetRenderOrigin(pos)
			dummy:SetupBones()
			dummy:DrawModel()
		end
		render.SetMaterial(mat)
		cam.PushModelMatrix(M)
		msh:Draw()
		cam.PopModelMatrix()
		Lights(false)
	elseif method == "ent" and IsValid(carrier) then
		Lights(true, pos)
		local S = Matrix()
		if v.scale then S:Scale(v.scale) end
		carrier.NT_rm = { Mesh = msh, Material = mat, Matrix = S }
		carrier:SetRenderOrigin(pos)
		carrier:SetRenderAngles(angle_zero)
		carrier:SetPos(pos)
		carrier:SetupBones()
		carrier:DrawModel()
		Lights(false)
	end
end

local FOV, DIST, STEP = 34, 700, 24
local function Place(col, row) return Vector(0, (8.5 - col) * STEP, (2.5 - row) * STEP) end

local wantMeasure
hook.Add("HUDPaint", "NT_LitProbe", function()
	if LP.mode ~= "hud" then return end
	Setup()
	local w, h = ScrW(), ScrH()
	surface.SetDrawColor(24, 26, 34, 255)
	surface.DrawRect(0, 0, w, h)
	cam.Start3D(Vector(-DIST, 0, 0), Angle(0, 0, 0), FOV, 0, 0, w, h, 4, 4000)
	render.ClearDepth()
	render.OverrideDepthEnable(true, true)
	for r, method in ipairs(METHODS) do
		for c, v in ipairs(variants) do DrawOne(method, v, Place(c, r)) end
	end
	render.OverrideDepthEnable(false, false)
	cam.End3D()
	if wantMeasure then
		wantMeasure = nil
		render.CapturePixels()
		local k = (w * 0.5) / math.tan(math.rad(FOV * 0.5))
		local function Lum(x, y)
			local r, g, b = render.ReadPixel(floor(x), floor(y))
			return r, g, b
		end
		for r, method in ipairs(METHODS) do
			local line = {}
			for c in ipairs(variants) do
				local p = Place(c, r)
				local sx, sy = w * 0.5 - p.y / DIST * k, h * 0.5 - p.z / DIST * k
				local o = R / DIST * k * 0.5
				local r1, g1, b1 = Lum(sx - o, sy - o)
				local r2, g2, b2 = Lum(sx, sy)
				local r3, g3, b3 = Lum(sx + o, sy + o)
				line[#line + 1] = string.format("%d:(%d %d %d|%d %d %d|%d %d %d)", c, r1, g1, b1, r2, g2, b2, r3, g3, b3)
			end
			Log(string.format("row %s, towards the light | middle | away from it: %s", method, table.concat(line, " ")))
		end
	end
end)

-- the same in the world, in front of the eye: where the brain in a head is drawn
hook.Add("PostDrawTranslucentRenderables", "NT_LitProbe", function(_, sky)
	if sky or LP.mode ~= "world" then return end
	Setup()
	local eye, ang = EyePos(), EyeAngles()
	local base = eye + ang:Forward() * 150
	for r, method in ipairs(METHODS) do
		local k = 0
		for _, c in ipairs({ 1, 4, 8, 13, 5 }) do
			k = k + 1
			DrawOne(method, variants[c], base + ang:Right() * ((k - 3) * STEP) + ang:Up() * ((2.5 - r) * STEP))
		end
	end
end)

function LP.Run(t)
	if t.mode then LP.mode = t.mode ~= "off" and t.mode or nil end
	if t.measure then wantMeasure = true end
end
