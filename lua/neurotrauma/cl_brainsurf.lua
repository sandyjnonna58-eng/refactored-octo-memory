-- Client: the lit surfaces of the developer's brain (cl_brain3d.lua draws with them).
--
-- A surface is a grid of vertices made by tools/braingen (data_static/neurotrauma/<key>.dat), with
-- a colour map and a normal map made by the same run (materials/neurotrauma/brain). It is drawn
-- with the engine's own lit shader: light that moves over it as it is turned, a highlight, relief
-- from the normal map. What the scene neuro_litprobe found to work is what is used here: a mesh
-- drawn directly under lights set with render.SetLocalModelLights.
--
-- A lit surface cannot carry a colour per vertex, so what a structure shows (damage, blood flow, a
-- lobe, what is in use) is painted into a small picture that is multiplied over the surface: one
-- cell per patch of surface, each cell belonging to one structure of the atlas. Changing a colour
-- repaints cells; no mesh is ever built again.
--
-- Coordinates: the atlas's axes in the proportions of a head (atlas x, y, z times headX, headY,
-- headZ over 3), so that the meshes need no stretching and their normals are true.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
NT.BrainSurf = NT.BrainSurf or {}
local BS = NT.BrainSurf
local A, C = NT.Atlas, NT.Config
local byte, floor, min, max, sqrt = string.byte, math.floor, math.min, math.max, math.sqrt

local PX, PY, PZ = C.Anatomy.headX / 3, C.Anatomy.headY / 3, C.Anatomy.headZ / 3
BS.scale = { PX, PY, PZ }
local CHUNK = 64          -- quads along the side of one mesh
local PAINT = 128         -- cells along the side of the paint

-- which structure a place on a surface belongs to: by kind of surface
local Owner = {}

local DEFS = {
	{ key = "cortex_l", layer = "cortex", side = "L", tex = "neurotrauma/brain/cortex_l", owner = "cortex" },
	{ key = "cortex_r", layer = "cortex", side = "R", tex = "neurotrauma/brain/cortex_r", owner = "cortex" },
	{ key = "cereb_l", layer = "hind", side = "L", tex = "neurotrauma/brain/cereb_l", owner = "cerebellum" },
	{ key = "cereb_r", layer = "hind", side = "R", tex = "neurotrauma/brain/cereb_r", owner = "cerebellum" },
	-- (the brainstem and the cord are two halves as well: with one side shown, what shows is the cut through the middle)
	{ key = "stem_l", layer = "hind", side = "L", tex = "neurotrauma/brain/stem_l", owner = "stem" },
	{ key = "stem_r", layer = "hind", side = "R", tex = "neurotrauma/brain/stem_r", owner = "stem" },
}
local patches = {}
BS.patches = patches
BS.stats = { verts = 0, tris = 0, loadMs = 0, buildMs = 0 }

------------------------------------------------------------------------------------------
-- Reading a surface
------------------------------------------------------------------------------------------
local function I32(s, o)
	local a, b, c, d = byte(s, o, o + 3)
	local v = a + b * 256 + c * 65536 + d * 16777216
	if v >= 2147483648 then v = v - 4294967296 end
	return v
end
local function S8(v) return (v > 127 and v - 256 or v) / 127 end

local function Load(def)
	local s = file.Read("data_static/neurotrauma/" .. def.key .. ".dat", "GAME")
	if not s or #s < 34 or string.sub(s, 1, 4) ~= "NTB1" then return nil end
	local gw, gh = byte(s, 5) + byte(s, 6) * 256, byte(s, 7) + byte(s, 8) * 256
	local n = gw * gh
	if #s < 34 + n * 12 then return nil end
	local w = byte(s, 9)
	local p = { def = def, gw = gw, gh = gh, w = w > 127 and -1 or 1, ccw = byte(s, 10) == 1, raw = s, px = {}, py = {}, pz = {}, chunks = {}, todo = {} }
	local lx, ly, lz = I32(s, 11) / 65536, I32(s, 15) / 65536, I32(s, 19) / 65536
	local kx, ky, kz = (I32(s, 23) / 65536 - lx) / 65535, (I32(s, 27) / 65536 - ly) / 65535, (I32(s, 31) / 65536 - lz) / 65535
	local px, py, pz = p.px, p.py, p.pz
	local o = 35
	for i = 1, n do
		local a, b, c, d, e, f = byte(s, o, o + 5)
		px[i], py[i], pz[i] = lx + (a + b * 256) * kx, ly + (c + d * 256) * ky, lz + (e + f * 256) * kz
		o = o + 12
	end
	-- the meshes it will be drawn as, and the ball each of them lies in (for a click)
	for cj = 0, gh - 2, CHUNK do
		for ci = 0, gw - 2, CHUNK do
			local i1, j1 = min(ci + CHUNK, gw - 1), min(cj + CHUNK, gh - 1)
			local sx, sy, sz, cnt = 0, 0, 0, 0
			for j = cj, j1, 8 do
				for i = ci, i1, 8 do
					local k = j * gw + i + 1
					sx, sy, sz, cnt = sx + px[k], sy + py[k], sz + pz[k], cnt + 1
				end
			end
			local ch = { i0 = ci, j0 = cj, i1 = i1, j1 = j1, cx = sx / cnt, cy = sy / cnt, cz = sz / cnt, r = 0 }
			for j = cj, j1, 4 do
				for i = ci, i1, 4 do
					local k = j * gw + i + 1
					local dx, dy, dz = px[k] - ch.cx, py[k] - ch.cy, pz[k] - ch.cz
					ch.r = max(ch.r, sqrt(dx * dx + dy * dy + dz * dz))
				end
			end
			ch.r = ch.r + 0.03
			p.chunks[#p.chunks + 1] = ch
			p.todo[#p.todo + 1] = ch
		end
	end
	-- the cells of the paint: whose each one is
	p.cell = {}
	local own = Owner[def.owner]
	for cy = 0, PAINT - 1 do
		for cx = 0, PAINT - 1 do
			local i, j = floor((cx + 0.5) / PAINT * (gw - 1) + 0.5), floor((cy + 0.5) / PAINT * (gh - 1) + 0.5)
			local k = j * gw + i + 1
			p.cell[cy * PAINT + cx + 1] = own(def, px[k] / PX, py[k] / PY, pz[k] / PZ)
		end
	end
	return p
end

-- the cortex: the nearest of the atlas's cortical regions of that side
local cortical
function Owner.cortex(def, x, y, z)
	if not cortical then
		cortical = { L = {}, R = {} }
		for _, r in ipairs(A.regions) do
			if r.kind == "C" and (r.side == "L" or r.side == "R") then cortical[r.side][#cortical[r.side] + 1] = r end
		end
	end
	local best, bd
	for _, r in ipairs(cortical[def.side]) do
		local dx, dy, dz = x - r.x, y - r.y, z - r.z
		local d = (dx * dx + dy * dy + dz * dz) / (r.radius * r.radius)
		if not bd or d < bd then best, bd = r.id, d end
	end
	return "r" .. best
end

-- the cerebellum: the vermis in the middle, the upper and the lower part of the hemisphere beside it
function Owner.cerebellum(def, x, y, z)
	if math.abs(x) < 0.13 then return "r" .. A.regionOf.vermis end
	return "r" .. A.regionOf[def.side .. (z > -0.88 and "_cerebellum_sup" or "_cerebellum_inf")]
end

-- the brainstem and the cord: by level, and by the half it is
function Owner.stem(def, x, _, z)
	local s = def.side
	if z > -0.55 then return "r" .. A.regionOf[s .. "_midbrain_teg"] end
	if z > -1.02 then return "r" .. A.regionOf[s .. "_pons_teg"] end
	if z > -1.50 then return "r" .. A.regionOf[s .. (math.abs(x) > 0.115 and "_medulla_lateral" or "_medulla_teg")] end
	if z > -2.20 then return "t" .. A.tractOf[s .. "_cord_cervical"] end
	if z > -3.00 then return "t" .. A.tractOf[s .. "_cord_thoracic"] end
	return "t" .. A.tractOf[s .. "_cord_lumbar"]
end

------------------------------------------------------------------------------------------
-- Building: one mesh at a time, so that opening the window does not stop the game
------------------------------------------------------------------------------------------
local function BuildChunk(p, ch)
	local gw, s, px, py, pz = p.gw, p.raw, p.px, p.py, p.pz
	local un, vn = 1 / (p.gw - 1), 1 / (p.gh - 1)
	local w = p.w
	local vs = {}
	local cols = ch.i1 - ch.i0 + 1
	for j = ch.j0, ch.j1 do
		for i = ch.i0, ch.i1 do
			local k = j * gw + i
			local o = 35 + k * 12 + 6
			local a, b, c, d, e, f = byte(s, o, o + 5)
			vs[(j - ch.j0) * cols + (i - ch.i0) + 1] = {
				pos = Vector(px[k + 1], py[k + 1], pz[k + 1]), normal = Vector(S8(a), S8(b), S8(c)),
				u = i * un, v = j * vn, userdata = { S8(d), S8(e), S8(f), w },
			}
		end
	end
	local tris, n = {}, 0
	local ccw = p.ccw
	for j = 0, ch.j1 - ch.j0 - 1 do
		for i = 0, cols - 2 do
			local a = vs[j * cols + i + 1]
			local b, c, d = vs[j * cols + i + 2], vs[(j + 1) * cols + i + 1], vs[(j + 1) * cols + i + 2]
			-- (the frames this is drawn in are mirror images of the atlas's: what is counter-clockwise
			-- there faces the eye here)
			if ccw then
				tris[n + 1], tris[n + 2], tris[n + 3], tris[n + 4], tris[n + 5], tris[n + 6] = a, c, d, a, d, b
			else
				tris[n + 1], tris[n + 2], tris[n + 3], tris[n + 4], tris[n + 5], tris[n + 6] = a, d, c, a, b, d
			end
			n = n + 6
		end
	end
	ch.mesh = Mesh()
	ch.mesh:BuildFromTriangles(tris)
	BS.stats.verts = BS.stats.verts + #vs
	BS.stats.tris = BS.stats.tris + n / 3
end

local loadAt = 1
-- Does a part of what is left to do; true when everything is read and built.
function BS.Step(budget)
	local t0 = SysTime()
	while loadAt <= #DEFS do
		local def = DEFS[loadAt]
		loadAt = loadAt + 1
		local p = Load(def)
		BS.stats.loadMs = BS.stats.loadMs + (SysTime() - t0) * 1000
		if p then patches[#patches + 1] = p else NT.Print("the surface %s is missing or damaged (data_static/neurotrauma/%s.dat)", def.key, def.key) end
		return false
	end
	local left = false
	for _, p in ipairs(patches) do
		while #p.todo > 0 do
			if SysTime() - t0 > (budget or 0.012) then return false end
			local ch = table.remove(p.todo)
			BuildChunk(p, ch)
			BS.stats.buildMs = BS.stats.buildMs + (SysTime() - t0) * 1000
			t0 = SysTime()
			left = #p.todo > 0
		end
	end
	if not left then
		-- (the vertices' normals and tangents were in the file's text: it is not needed any more)
		for _, p in ipairs(patches) do p.raw = nil end
	end
	return not left
end

------------------------------------------------------------------------------------------
-- Materials and the paint
------------------------------------------------------------------------------------------
-- The look: the three lights, the light from all round, the highlight, the reflection. Kept in one
-- table so that the scene neuro_brainlook can try several in one run (BS.Tune).
BS.look = {
	key = { 0.78, 0.76, 0.72 }, fill = { 0.07, 0.085, 0.12 }, rim = { 0.18, 0.18, 0.20 }, ambient = { 0.04, 0.04, 0.05 },
	-- (exponent 36, boost 1.4 until phase 37: bright narrow streaks on every gyrus, a glazed thing;
	-- wet tissue under its membrane has a wide, weak shine)
	exponent = 22, boost = 0.8, env = 0.02,
}
local function ApplyLook(p)
	local L = BS.look
	for _, m in ipairs({ p.mat, p.glass }) do
		m:SetFloat("$phongexponent", L.exponent)
		m:SetFloat("$phongboost", L.boost)
		m:SetVector("$envmaptint", Vector(L.env, L.env, L.env))
	end
end
function BS.Tune(t)
	for k, v in pairs(t) do BS.look[k] = v end
	for _, p in ipairs(patches) do
		if p.mat then ApplyLook(p) end
	end
end

local serial = 0
local function Materials(p)
	if p.mat then return end
	serial = serial + 1
	local def = p.def
	p.paint = GetRenderTargetEx("nt_bs_paint_" .. def.key, PAINT, PAINT, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)
	local function Make(glass)
		local m = CreateMaterial(string.format("nt_bs_%s_%s%d", def.key, glass and "g" or "s", serial), "VertexLitGeneric", {
			["$basetexture"] = def.tex, ["$bumpmap"] = def.tex .. "_n",
			["$detail"] = "models/debug/debugwhite", ["$detailscale"] = 1, ["$detailblendmode"] = 0, ["$detailblendfactor"] = 1,
			["$phong"] = 1, ["$phongexponent"] = 34, ["$phongboost"] = 1.6, ["$phongfresnelranges"] = "[0.35 0.7 1]",
			["$lightwarptexture"] = "neurotrauma/brain/warp",
			["$envmap"] = "neurotrauma/brain/env", ["$envmaptint"] = "[0 0 0]", ["$normalmapalphaenvmapmask"] = 1,
			["$translucent"] = glass and 1 or 0,
		})
		m:SetTexture("$detail", p.paint)
		return m
	end
	p.mat, p.glass = Make(false), Make(true)
	ApplyLook(p)
end

-- Paints what every structure of a layer shows. colour(key) -> r, g, b of 0..255, where the key
-- is the structure's kind and number ("r12" a region, "t5" a tract); the paint holds
-- half of it (it is multiplied over the surface twice over, so that white leaves the surface as
-- it is). Cells of one colour in a row are one rectangle.
function BS.Paint(layer, colour)
	local cache = {}
	local old = DisableClipping(true)
	render.SetScissorRect(0, 0, 0, 0, false)
	for _, p in ipairs(patches) do
		if p.def.layer == layer then
			Materials(p)
			render.PushRenderTarget(p.paint)
			cam.Start2D()
			local cell = p.cell
			for cy = 0, PAINT - 1 do
				local from, id = 0, cell[cy * PAINT + 1]
				for cx = 1, PAINT do
					local nid = cx < PAINT and cell[cy * PAINT + cx + 1] or nil
					if nid ~= id then
						local c = cache[id]
						if not c then
							local r, g, b = colour(id)
							c = { r * 0.5, g * 0.5, b * 0.5 }
							cache[id] = c
						end
						surface.SetDrawColor(c[1], c[2], c[3], 255)
						surface.DrawRect(from, cy, cx - from, 1)
						from, id = cx, nid
					end
				end
			end
			cam.End2D()
			render.PopRenderTarget()
		end
	end
	DisableClipping(old)
end

------------------------------------------------------------------------------------------
-- Light: fixed to the eye, so that it moves over the brain as the brain is turned. A key from the
-- upper left, a cool fill from the right, a rim from behind.
------------------------------------------------------------------------------------------
local lights = {
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
}
function BS.LightsOn(ang, at)
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local L = BS.look
	lights[1].color = Vector(L.key[1], L.key[2], L.key[3])
	lights[2].color = Vector(L.fill[1], L.fill[2], L.fill[3])
	lights[3].color = Vector(L.rim[1], L.rim[2], L.rim[3])
	-- (dir: the way the light travels)
	lights[1].dir = (f * 0.62 + r * 0.50 - u * 0.62):GetNormalized()
	lights[2].dir = (f * 0.45 - r * 0.80 - u * 0.10):GetNormalized()
	lights[3].dir = (-f * 0.75 - u * 0.55 - r * 0.20):GetNormalized()
	render.SuppressEngineLighting(true)
	render.SetLightingOrigin(at)
	render.ResetModelLighting(L.ambient[1], L.ambient[2], L.ambient[3])
	render.SetLocalModelLights(lights)
end
-- A cortex that is nearly clear is drawn in more light from all round. Lit as a solid one, its
-- shaded side is dark, and a few per cent of something dark only dims what is seen through it:
-- the clear brain was a smoky shape. The clearer, the more even the light.
function BS.Glass(alpha)
	local L = BS.look
	local k = (1 - alpha) * 0.5
	render.ResetModelLighting(L.ambient[1] + k, L.ambient[2] + k, L.ambient[3] + k * 1.08)
	render.SetLocalModelLights(lights)
end
function BS.LightsOff(keepSuppressed)
	render.SetLocalModelLights()
	if not keepSuppressed then render.SuppressEngineLighting(false) end
end

------------------------------------------------------------------------------------------
-- Drawing. The caller has set the lights and pushed the matrix of this frame of coordinates.
------------------------------------------------------------------------------------------
-- only: the patches of one owner alone ("stem": what is drawn a second time, turned, where the cord
-- leaves the skull: cl_brain3d.lua).
function BS.Draw(layer, side, alpha, only)
	local glass = alpha < 0.99
	for _, p in ipairs(patches) do
		local def = p.def
		if def.layer == layer and (side == "B" or def.side == "M" or def.side == side) and (not only or def.owner == only) then
			Materials(p)
			local m = glass and p.glass or p.mat
			if glass then m:SetFloat("$alpha", alpha) end
			render.SetMaterial(m)
			for _, ch in ipairs(p.chunks) do
				if ch.mesh then ch.mesh:Draw() end
			end
		end
	end
end

function BS.Has(layer)
	for _, p in ipairs(patches) do
		if p.def.layer == layer then return true end
	end
	return false
end

------------------------------------------------------------------------------------------
-- A click: the ray against the surfaces of a layer (in this frame of coordinates). Returns how
-- far along the ray the nearest surface is, and whose that place is.
------------------------------------------------------------------------------------------
function BS.Ray(layer, side, ox, oy, oz, dx, dy, dz)
	local bt, bid
	local dl = sqrt(dx * dx + dy * dy + dz * dz)
	for _, p in ipairs(patches) do
		local def = p.def
		if def.layer == layer and (side == "B" or def.side == "M" or def.side == side) then
			local gw, px, py, pz = p.gw, p.px, p.py, p.pz
			for _, ch in ipairs(p.chunks) do
				-- (only the meshes whose ball the ray passes through)
				local cx, cy, cz = ch.cx - ox, ch.cy - oy, ch.cz - oz
				local along = (cx * dx + cy * dy + cz * dz) / dl
				local d2 = cx * cx + cy * cy + cz * cz - along * along
				if d2 <= ch.r * ch.r then
					for j = ch.j0, ch.j1 - 1 do
						for i = ch.i0, ch.i1 - 1 do
							local ka = j * gw + i + 1
							local kb, kc, kd = ka + 1, ka + gw, ka + gw + 1
							local ax, ay, az = px[ka], py[ka], pz[ka]
							for half = 1, 2 do
								local k1, k2 = half == 1 and kc or kd, half == 1 and kd or kb
								local e1x, e1y, e1z = px[k1] - ax, py[k1] - ay, pz[k1] - az
								local e2x, e2y, e2z = px[k2] - ax, py[k2] - ay, pz[k2] - az
								local qx, qy, qz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
								local det = e1x * qx + e1y * qy + e1z * qz
								if det > 1e-14 or det < -1e-14 then
									local inv = 1 / det
									local tx, ty, tz = ox - ax, oy - ay, oz - az
									local u = (tx * qx + ty * qy + tz * qz) * inv
									if u >= 0 and u <= 1 then
										local rx, ry, rz = ty * e1z - tz * e1y, tz * e1x - tx * e1z, tx * e1y - ty * e1x
										local v = (dx * rx + dy * ry + dz * rz) * inv
										if v >= 0 and u + v <= 1 then
											local t = (e2x * rx + e2y * ry + e2z * rz) * inv
											if t > 0 and (not bt or t < bt) then
												bt = t
												local cxl = min(floor(i / (gw - 1) * PAINT), PAINT - 1)
												local cyl = min(floor(j / (p.gh - 1) * PAINT), PAINT - 1)
												bid = p.cell[cyl * PAINT + cxl + 1]
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return bt, bid
end
