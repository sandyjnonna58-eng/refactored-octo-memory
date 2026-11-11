-- Client: the brain as a body, drawn in two places:
--
--   the viewer     brain_view [target] (superadmin, neuro_dev 1): a window in which the brain of the
--                  watched character can be turned (drag), brought near (wheel) and asked about
--                  (click a structure). Coloured by what is asked: as it looks, by lobe, by
--                  damage, by blood flow, by what is in use right now, by a group of functions, by
--                  arterial territory; layers for the cortex (with its opacity), the deep nuclei,
--                  the hindbrain with the spinal cord, the motor pathway, the arteries, their
--                  branches, the veins and sinuses.
--   in the head    neuro_brain_world 1 (the same developers): the same mesh at the head bone of
--                  every near character, standing, falling or lying, seen through the skull.
--
-- What it is, and is not. No model of a brain ships with the game or with Z-City, and Source has no
-- soft bodies. Everything drawn here is made, none of it is a scan:
--   the hemispheres, the cerebellum, the brainstem with the cord: surfaces made by tools/braingen
--     (folds, vessels of the pia, colour, relief), drawn lit by cl_brainsurf.lua. Whose a place on
--     them is, is the atlas's: the nearest cortical region, the part of the cerebellum, the level
--     of the brainstem or the cord;
--   the deep nuclei as bodies at the atlas's places, the motor pathway and the other tracts:
--     built here from the atlas, once, and drawn lit under the same lights;
--   the arteries, the veins and the sinuses: courses made by tools/braingen with the surfaces
--     (the carotid's bends, the circle under the brain, branches that lie in the furrows and
--     thin into the painted vessels of the pia), read and built by cl_brainvasc.lua. Whose an
--     artery is, is the atlas's: every one of them carries the key of a vessel of the atlas.
-- It has the atlas's 114 regions, 41 tracts and 90 vessels to ask about, no more. The brain a
-- bullet or a blow meets is the server's atlas in the head's own frame (sv_injury.lua); what is
-- drawn sits in the same frame, so it is where the server says it is.
--
-- Colours. A lit mesh cannot carry a colour per vertex. The lit surfaces have a paint that is
-- multiplied over them (cl_brainsurf.lua); the bodies built here take their colour from a small
-- picture, the palette, in which every structure has a cell of its own. A change of colour paints
-- cells; no mesh is built a second time. What is in use is painted the same way.
--
-- Cost: nothing for anybody who has not opened it. The bodies are built when the brain is first
-- drawn, one mesh a frame; the figures are in docs/NEUROTRAUMA_PERFORMANCE.md, section 4.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
local A, C = NT.Atlas, NT.Config
local BS = NT.BrainSurf
local BV = NT.BrainVasc
NT.Brain3D = NT.Brain3D or {}
local B3 = NT.Brain3D
local sin, cos, sqrt, abs, max, min, floor, exp, pi = math.sin, math.cos, math.sqrt, math.abs, math.max, math.min, math.floor, math.exp, math.pi
local Clamp = math.Clamp
-- (the bodies are drawn in the proportions of a head, as the lit surfaces are)
local PX, PY, PZ = BS.scale[1], BS.scale[2], BS.scale[3]

------------------------------------------------------------------------------------------
-- Noise (for the furrows): smooth value noise in three dimensions, -1..1
------------------------------------------------------------------------------------------
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit
local function Hash(ix, iy, iz)
	local h = bxor(tobit(ix * 73856093), tobit(iy * 19349663), tobit(iz * 83492791))
	h = bxor(h, rshift(h, 13))
	h = tobit(band(h, 0xfffff) * 9301 + 49297)
	h = bxor(h, rshift(h, 11))
	return band(h, 0xffff) / 32767.5 - 1
end
local function Noise3(x, y, z)
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local fx, fy, fz = x - ix, y - iy, z - iz
	fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
	local a = Hash(ix, iy, iz) + (Hash(ix + 1, iy, iz) - Hash(ix, iy, iz)) * fx
	local b = Hash(ix, iy + 1, iz) + (Hash(ix + 1, iy + 1, iz) - Hash(ix, iy + 1, iz)) * fx
	local c = Hash(ix, iy, iz + 1) + (Hash(ix + 1, iy, iz + 1) - Hash(ix, iy, iz + 1)) * fx
	local d = Hash(ix, iy + 1, iz + 1) + (Hash(ix + 1, iy + 1, iz + 1) - Hash(ix, iy + 1, iz + 1)) * fx
	local e, f = a + (b - a) * fy, c + (d - c) * fy
	return e + (f - e) * fz
end
local function Smooth(a, b, x)
	local t = Clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

------------------------------------------------------------------------------------------
-- Building. A layer is a set of vertices and triangles per side (L, R, M); a vertex knows the
-- structure it belongs to (kind r region, t tract, v vessel, s sinus) and how brightly it is lit.
-- Everything is in the atlas's own frame: x to the left, y to the front, z up.
------------------------------------------------------------------------------------------
local layers = {}
local built = false
-- (the two frames this is drawn in mirror the atlas's: a triangle is wound for that)
local FLIP = true

local function Part(layer, side)
	local l = layers[layer]
	if not l then l = {} layers[layer] = l end
	local p = l[side]
	if not p then p = { verts = {}, tris = {} } l[side] = p end
	return p
end

-- A vertex. Its place as it is drawn is in the proportions of a head, and its normal is turned
-- with that; its place in the atlas's own frame is kept for the click (ax, ay, az). The lit
-- shader wants a direction along the surface too: the normal map of the bodies is flat, so any
-- direction will do.
local function Vtx(part, x, y, z, nx, ny, nz, kind, id)
	nx, ny, nz = nx / PX, ny / PY, nz / PZ
	local len = sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-6 then nx, ny, nz, len = 0, 0, 1, 1 end
	nx, ny, nz = nx / len, ny / len, nz / len
	local tx, ty, tz
	if abs(nz) < 0.9 then tx, ty, tz = -ny, nx, 0 else tx, ty, tz = 0, -nz, ny end
	local tl = sqrt(tx * tx + ty * ty + tz * tz)
	local v = { pos = Vector(x * PX, y * PY, z * PZ), normal = Vector(nx, ny, nz), u = 0, v = 0, userdata = { tx / tl, ty / tl, tz / tl, 1 },
		ax = x, ay = y, az = z, kind = kind, id = id, sk = kind .. id }
	part.verts[#part.verts + 1] = v
	return v
end

local function Tri(part, a, b, c, flip)
	local t = part.tris
	local n = #t
	if flip then t[n + 1], t[n + 2], t[n + 3] = a, c, b else t[n + 1], t[n + 2], t[n + 3] = a, b, c end
end

-- a closed surface from a grid of points: rows[i][j] = { x, y, z, ao, kind, id }, j wraps
local function Skin(part, rows, nRows, nCols, cx, cy, cz, flip)
	local vs = {}
	for i = 0, nRows do
		vs[i] = {}
		local up, dn = rows[max(i - 1, 0)], rows[min(i + 1, nRows)]
		for j = 0, nCols - 1 do
			local p = rows[i][j]
			local a, b = rows[i][(j + 1) % nCols], rows[i][(j - 1) % nCols]
			local c, d = dn[j], up[j]
			local ux, uy, uz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
			local vx, vy, vz = c[1] - d[1], c[2] - d[2], c[3] - d[3]
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			-- outward: away from the middle of the body
			local ox, oy, oz = p[1] - cx, p[2] - cy, p[3] - cz
			if nx * nx + ny * ny + nz * nz < 1e-10 then nx, ny, nz = ox, oy, oz
			elseif nx * ox + ny * oy + nz * oz < 0 then nx, ny, nz = -nx, -ny, -nz end
			vs[i][j] = Vtx(part, p[1], p[2], p[3], nx, ny, nz, p[5], p[6], p[4])
		end
	end
	for i = 0, nRows - 1 do
		for j = 0, nCols - 1 do
			local j2 = (j + 1) % nCols
			local a, b, c, d = vs[i][j], vs[i + 1][j], vs[i + 1][j2], vs[i][j2]
			Tri(part, a, b, c, flip)
			Tri(part, a, c, d, flip)
		end
	end
end

-- An ellipsoid, with an optional ripple (the folia of the cerebellum) and a way to say which
-- structure a point belongs to.
local function Ellipsoid(part, cx, cy, cz, rx, ry, rz, nu, nv, kind, id, ripple, flip)
	local rows = {}
	for i = 0, nv do
		local b = (i / nv) * pi
		local sb, cb = sin(b), cos(b)
		rows[i] = {}
		for j = 0, nu - 1 do
			local a = (j / nu) * 2 * pi
			local x, y, z = cx + rx * cos(a) * sb, cy + ry * sin(a) * sb, cz + rz * cb
			local ao = 1
			if ripple then
				local w = sin(z * 62 + y * 9)
				local k = 1 + 0.018 * w
				x, y = cx + (x - cx) * k, cy + (y - cy) * k
				ao = 0.9 + 0.1 * w
			end
			rows[i][j] = { x, y, z, ao, kind, isfunction(id) and id(x, y, z) or id }
		end
	end
	Skin(part, rows, nv, nu, cx, cy, cz, flip)
end

-- A tube along a line of points. radii: one per point; ids: one structure per point (or one for all).
local function Tube(part, pts, radii, kind, ids, seg, flip)
	seg = seg or 8
	local n = #pts
	if n < 2 then return end
	local rows = {}
	local px, py, pz              -- a direction across the tube, carried along it
	for k = 1, n do
		local p, q = pts[max(k - 1, 1)], pts[min(k + 1, n)]
		local tx, ty, tz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
		local tl = sqrt(tx * tx + ty * ty + tz * tz)
		if tl < 1e-6 then tx, ty, tz, tl = 0, 0, 1, 1 end
		tx, ty, tz = tx / tl, ty / tl, tz / tl
		if not px then
			if abs(tz) < 0.9 then px, py, pz = 0, 0, 1 else px, py, pz = 1, 0, 0 end
		end
		-- across = what is left of the carried direction when the part along the tube is taken out
		local dot = px * tx + py * ty + pz * tz
		px, py, pz = px - tx * dot, py - ty * dot, pz - tz * dot
		local pl = sqrt(px * px + py * py + pz * pz)
		if pl < 1e-6 then px, py, pz, pl = ty, -tx, 0, sqrt(tx * tx + ty * ty) + 1e-6 end
		px, py, pz = px / pl, py / pl, pz / pl
		local qx, qy, qz = ty * pz - tz * py, tz * px - tx * pz, tx * py - ty * px
		local r = istable(radii) and radii[k] or radii
		local c = pts[k]
		rows[k - 1] = {}
		for j = 0, seg - 1 do
			local a = (j / seg) * 2 * pi
			local ca, sa = cos(a), sin(a)
			rows[k - 1][j] = { c[1] + (px * ca + qx * sa) * r, c[2] + (py * ca + qy * sa) * r, c[3] + (pz * ca + qz * sa) * r, 1, kind, istable(ids) and ids[k] or ids, c }
		end
	end
	-- (outward is away from the tube's own middle line, point by point)
	local vs = {}
	for i = 0, n - 1 do
		vs[i] = {}
		for j = 0, seg - 1 do
			local p = rows[i][j]
			local c = p[7]
			vs[i][j] = Vtx(part, p[1], p[2], p[3], p[1] - c[1], p[2] - c[2], p[3] - c[3], p[5], p[6], 1)
		end
	end
	for i = 0, n - 2 do
		for j = 0, seg - 1 do
			local j2 = (j + 1) % seg
			Tri(part, vs[i][j], vs[i + 1][j], vs[i + 1][j2], flip)
			Tri(part, vs[i][j], vs[i + 1][j2], vs[i][j2], flip)
		end
	end
end

local structures = {}       -- what can be asked about: { kind, id, x, y, z, radius, layer, side }
-- the palette: a picture of PAL by PAL, in cells of PAL_CELL; palCell: structure key -> its cell
local PAL, PAL_CELL = 128, 4
local PAL_ROW = PAL / PAL_CELL
local palCell = {}
local structOf = { r = {}, t = {}, v = {} }       -- the same, by kind and id

local function Build()
	if built then return end
	built = true
	layers = {}
	structures = {}
	-- (the cortex is a lit surface made by tools/braingen and drawn by cl_brainsurf.lua; what can be
	-- asked about on it is still the atlas's cortical regions)
	for _, r in ipairs(A.regions) do
		if r.kind == "C" then structures[#structures + 1] = { "r", r.id, r.x, r.y, r.z, r.radius, "cortex", r.side } end
	end

	-- (the cerebellum, the brainstem and the cord are lit surfaces too)
	for _, r in ipairs(A.regions) do
		if r.kind == "X" or r.kind == "B" then structures[#structures + 1] = { "r", r.id, r.x, r.y, r.z, r.radius, "hind", r.side } end
	end

	for _, t in ipairs(A.tracts) do
		if t.cord then structures[#structures + 1] = { "t", t.id, t.x, t.y, t.z, 0.12, "hind", t.side } end
	end

	-- the deep nuclei, each a body at its place
	for _, r in ipairs(A.regions) do
		if r.kind == "D" then
			local long = r.base == "hippocampus" and 2.0 or (r.base == "caudate" and 1.6 or 1)
			Ellipsoid(Part("deep", r.side), r.x, r.y, r.z, r.radius * 0.85, r.radius * 0.85 * long, r.radius * 0.8, 14, 9, "r", r.id, false, FLIP)
			structures[#structures + 1] = { "r", r.id, r.x, r.y, r.z, r.radius, "deep", r.side }
		end
	end

	-- the motor pathway of each hemisphere: down through capsule, peduncle, pons and pyramid, across,
	-- and down the cord of the other side; and the other tracts as short pieces at their places
	for _, S in ipairs({ "L", "R" }) do
		local O = S == "L" and "R" or "L"
		local keys = { S .. "_corona", S .. "_ic_post", S .. "_peduncle", S .. "_pons_base", S .. "_pyramid", O .. "_cord_cervical", O .. "_cord_thoracic", O .. "_cord_lumbar" }
		local pts, ids = {}, {}
		local zone = A.Region(S .. "_precentral_hand")
		pts[1], ids[1] = { zone.x * 0.92, zone.y, zone.z * 0.92 }, A.tractOf[keys[1]]
		for _, key in ipairs(keys) do
			local t = A.Tract(key)
			pts[#pts + 1], ids[#ids + 1] = { t.x, t.y, t.z }, t.id
		end
		Tube(Part("tracts", S), pts, 0.022, "t", ids, 6, FLIP)
	end
	for _, t in ipairs(A.tracts) do
		if not t.cord then
			local side = t.side
			if t.side == "M" then
				-- the corpus callosum: a band from one side to the other
				Tube(Part("tracts", "M"), { { 0.30, t.y, t.z - 0.03 }, { 0.12, t.y, t.z + 0.02 }, { 0, t.y, t.z + 0.03 }, { -0.12, t.y, t.z + 0.02 }, { -0.30, t.y, t.z - 0.03 } }, 0.03, "t", t.id, 6, FLIP)
			else
				Ellipsoid(Part("tracts", side), t.x, t.y, t.z, t.radius * 0.45, t.radius * 0.45, t.radius * 0.45, 8, 6, "t", t.id, false, FLIP)
			end
			structures[#structures + 1] = { "t", t.id, t.x, t.y, t.z, t.radius, "tracts", t.side }
		end
	end

	-- The arteries, the veins and the sinuses are bodies made by tools/braingen with the surfaces
	-- (cl_brainvasc.lua): a vessel that lies on the folds cannot be made from the atlas's points
	-- alone. What can be asked about is still the atlas's vessel, at the atlas's place.
	for _, v in ipairs(A.vessels) do
		structures[#structures + 1] = { "v", v.id, v.x, v.y, v.z, 0.07, (v.kind == "C" or v.kind == "P") and "branches" or "arteries", v.side }
	end
	for _, s in ipairs(structures) do structOf[s[1]][s[2]] = s end
	-- The palette: every structure that has a body gets a cell, and every vertex of the body points
	-- at the middle of it.
	local n = 0
	for _, sides in pairs(layers) do
		for _, part in pairs(sides) do
			for _, v in ipairs(part.verts) do
				local c = palCell[v.sk]
				if not c then c, n = n, n + 1 palCell[v.sk] = c end
				v.u, v.v = ((c % PAL_ROW) + 0.5) * PAL_CELL / PAL, (floor(c / PAL_ROW) + 0.5) * PAL_CELL / PAL
			end
		end
	end
	-- (the vessels are bodies of another file: a cell for every artery of the atlas, and for the
	-- veins by their kind)
	for _, v in ipairs(A.vessels) do palCell["v" .. v.id], n = n, n + 1 end
	for id = 1, 6 do palCell["s" .. id], n = n, n + 1 end
end

-- Where in the palette a place of a vessel has its colour: the cell of the vessel, and in it the
-- row of how thick the vessel is there (0 a hair .. 1 a trunk; the rows run from trunk to hair).
local function VesselUV(kind, id, thick)
	local c = palCell[kind .. id] or palCell["s6"] or 0
	return ((c % PAL_ROW) + 0.5) * PAL_CELL / PAL, (floor(c / PAL_ROW) * PAL_CELL + 0.5 + (PAL_CELL - 1) * (1 - thick)) / PAL
end

------------------------------------------------------------------------------------------
-- Colours: what each structure shows in a mode.
------------------------------------------------------------------------------------------
local LOBE = {
	frontal = { 96, 140, 226 }, parietal = { 100, 196, 122 }, temporal = { 234, 160, 78 }, occipital = { 178, 122, 226 },
	insular = { 84, 196, 196 }, limbic = { 234, 132, 178 }, deep = { 170, 160, 190 }, brainstem = { 232, 218, 150 }, cerebellum = { 233, 192, 165 },
}
-- (the cortex is a lit surface with a colour map of its own: "as it looks" leaves it as it is)
-- (the deep nuclei are grey matter)
local NATURAL = { C = { 255, 255, 255 }, D = { 206, 178, 170 }, B = { 255, 255, 255 }, X = { 255, 255, 255 } }
local GLOW = { 255, 232, 90 }
local MAJOR = { aca = { 236, 110, 110 }, mca = { 110, 208, 128 }, pca = { 110, 150, 244 }, ica = { 236, 214, 104 }, vb = { 196, 124, 226 } }
-- A vessel's colour by how thick it is, from a trunk (row 1) to a hair (row 4). An artery: the red
-- of blood under a wall of muscle, deep and not bright in a trunk; the thinner, the more of the
-- pale tissue shows with it. A vein: thin-walled and dark, the violet of blood without oxygen; a
-- sinus lies in the dura and is the darkest and the least red.
-- (As painted they were the red and the blue of a diagram, run v37a. Under the viewer's lights a
-- colour comes out about a third brighter than it is written here.)
local ARTERY = { { 134, 36, 34 }, { 146, 44, 40 }, { 158, 60, 52 }, { 172, 94, 84 } }
local VEIN = { { 72, 68, 96 }, { 88, 60, 90 }, { 106, 72, 98 }, { 134, 104, 120 } }
local TRACT, CORD = { 238, 230, 204 }, { 255, 255, 255 }
local GREY = { 112, 114, 122 }

local function Mix(a, b, f)
	return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
end

local view = {
	mode = "natural", side = "B", alpha = 1, yaw = 205, pitch = 12, dist = 64, tx = 0, ty = 0, tz = -0.05, spin = true,
	layers = { cortex = true, hind = true, deep = true, tracts = false, arteries = false, branches = false, veins = false },
}
B3.view = view
local EMPTY = { has = false, dom = "L", d = {}, td = {}, rs = {}, ts = {}, shut = {}, low = {}, ch = {}, on = {}, stg = {}, out = {} }
local act, tact = {}, {}        -- what is in use: region / tract id -> 0..1, fading

local groupCache = {}
local function Group(dom, group)
	local key = dom .. group
	local w = groupCache[key]
	if w then return w end
	w = { r = {}, t = {} }
	for _, c in ipairs(A.compiled[dom]) do
		local take = c.group == group
		if group == "visual" then take = string.find(c.base, "vision", 1, true) ~= nil end
		if group == "sensory" then take = c.group == "sensory" and not string.find(c.base, "vision", 1, true) end
		if take then
			for _, s in ipairs(c.stages) do
				for _, it in ipairs(s.items) do
					local m = it[1] and w.t or w.r
					m[it[2]] = max(m[it[2]] or 0, it[3])
				end
			end
		end
	end
	groupCache[key] = w
	return w
end

local function RegionRGB(r, d)
	local mode = view.mode
	local id = r.id
	local dm, off = d.d[id] or 0, d.rs[id] or 0
	if mode == "natural" then
		local c = NATURAL[r.kind]
		-- (a destroyed structure is dark and red; one that is switched off is dull)
		local x, y, z = Mix(c, { 110, 30, 30 }, Clamp(dm * 1.1, 0, 1))
		local k = 1 - 0.35 * off
		return x * k, y * k, z * k
	elseif mode == "lobes" then
		local c = LOBE[r.lobe] or GREY
		return c[1], c[2], c[3]
	elseif mode == "damage" then
		local x, y, z = Mix(GREY, { 236, 52, 40 }, dm > 0.01 and Clamp(0.25 + dm, 0, 1) or 0)
		if off > 0.1 and dm < 0.5 then x, y, z = Mix({ x, y, z }, { 250, 170, 40 }, off * 0.7) end
		return x, y, z
	elseif mode == "perfusion" then
		return Mix({ 84, 136, 226 }, { 16, 16, 22 }, d.low[id] or 0)
	elseif mode == "activation" then
		-- (what is in use is painted over this: Ready)
		return 92, 94, 104
	elseif mode == "vascular" then
		local best, share = nil, 0
		for key, s in pairs(r.supply) do
			if s > share then best, share = key, s end
		end
		local v = best and A.Vessel(best)
		local c = v and MAJOR[v.major] or GREY
		return c[1], c[2], c[3]
	end
	local w = Group(d.dom, mode).r[id]
	if not w then return GREY[1], GREY[2], GREY[3] end
	local x, y, z = Mix(GREY, { 96, 226, 146 }, Clamp(0.3 + w, 0, 1))
	if dm > 0.05 then x, y, z = Mix({ x, y, z }, { 236, 52, 40 }, dm) end
	return x, y, z
end

local function TractRGB(t, d)
	local mode = view.mode
	local left = (1 - (d.td[t.id] or 0)) * (1 - (d.ts[t.id] or 0))
	if mode == "natural" or mode == "lobes" or mode == "vascular" then
		return Mix(t.cord and CORD or TRACT, { 120, 36, 30 }, 1 - left)
	elseif mode == "activation" then
		return 92, 94, 104
	elseif mode == "damage" then
		return Mix(GREY, { 236, 52, 40 }, left < 0.99 and Clamp(1.25 - left, 0, 1) or 0)
	elseif mode == "perfusion" then
		-- (the stream says the blood flow of regions only)
		return GREY[1], GREY[2], GREY[3]
	end
	local w = Group(d.dom, mode).t[t.id]
	if not w then return GREY[1], GREY[2], GREY[3] end
	return Mix({ 236, 60, 44 }, { 96, 226, 146 }, left)
end

local function VesselRGB(v, d, row)
	local shut = d.shut[v.id] or 0
	local c = ARTERY[row]
	if view.mode == "vascular" then
		-- (by territory: the colour of its main artery, paler the thinner)
		local m = MAJOR[v.major]
		local k = (row - 1) * 0.10
		c = { m[1] + (255 - m[1]) * k, m[2] + (255 - m[2]) * k, m[3] + (255 - m[3]) * k }
	end
	return Mix(c, { 40, 8, 8 }, shut)
end

-- What the colours stand on: a number that changes when they would.
local function ColourKey(d)
	local k = 0
	local function Sum(map, m) for id, v in pairs(map) do k = k + id * floor(v * 15 + 0.5) * m end end
	Sum(d.d, 3) Sum(d.rs, 5) Sum(d.td, 7) Sum(d.ts, 11) Sum(d.shut, 13) Sum(d.low, 17)
	return view.mode .. (d.dom or "L") .. k
end

local matLit, matVessel, matFine, palette
local function Materials()
	if matLit then return end
	palette = GetRenderTargetEx("nt_b3_palette", PAL, PAL, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)
	matLit = CreateMaterial("nt_brain_lit", "VertexLitGeneric", {
		["$basetexture"] = "neurotrauma/brain/warp", ["$bumpmap"] = "neurotrauma/brain/flat_n",
		["$phong"] = 1, ["$phongexponent"] = 26, ["$phongboost"] = 1.1, ["$phongfresnelranges"] = "[0.35 0.7 1]",
		["$lightwarptexture"] = "neurotrauma/brain/warp", ["$nocull"] = 1,
	})
	matLit:SetTexture("$basetexture", palette)
	-- A vessel is wet tissue, not a painted pipe: a soft highlight that is strongest where the
	-- wall is seen edge on (a wall has a thickness), and a fine vessel has less of it than a trunk.
	-- (A broad white stripe along a tube is a plastic pipe, run v37a; none at all is a rubber hose,
	-- run v37b. The highlight is a narrow line, strongest at the edge, a little of the wall's colour.)
	matVessel = CreateMaterial("nt_brain_vessel", "VertexLitGeneric", {
		["$basetexture"] = "neurotrauma/brain/warp", ["$bumpmap"] = "neurotrauma/brain/flat_n",
		["$phong"] = 1, ["$phongexponent"] = 42, ["$phongboost"] = 1.0, ["$phongfresnelranges"] = "[0.3 0.6 1.6]",
		["$phongtint"] = "[1 0.88 0.84]",
		["$lightwarptexture"] = "neurotrauma/brain/warp", ["$nocull"] = 1,
	})
	matVessel:SetTexture("$basetexture", palette)
	matFine = CreateMaterial("nt_brain_vessel_fine", "VertexLitGeneric", {
		["$basetexture"] = "neurotrauma/brain/warp", ["$bumpmap"] = "neurotrauma/brain/flat_n",
		["$phong"] = 1, ["$phongexponent"] = 26, ["$phongboost"] = 0.45, ["$phongfresnelranges"] = "[0.2 0.5 1.2]",
		["$phongtint"] = "[1 0.88 0.84]",
		["$lightwarptexture"] = "neurotrauma/brain/warp", ["$nocull"] = 1,
	})
	matFine:SetTexture("$basetexture", palette)
end

local glowNow = {}          -- structure key -> how brightly, this frame

-- Paints into the palette what every structure with a body shows; says how many cells that was.
local function PaintPalette(d, lit)
	local n = 0
	local old = DisableClipping(true)
	render.SetScissorRect(0, 0, 0, 0, false)
	render.PushRenderTarget(palette)
	cam.Start2D()
	for sk, c in pairs(palCell) do
		local kind, id = string.sub(sk, 1, 1), tonumber(string.sub(sk, 2))
		local x, y, z
		local px, py = (c % PAL_ROW) * PAL_CELL, floor(c / PAL_ROW) * PAL_CELL
		if kind == "v" or kind == "s" then
			-- (a vessel's cell: a row for each thickness, trunk to hair)
			for row = 1, PAL_CELL do
				if kind == "v" then
					x, y, z = VesselRGB(A.vessels[id], d, row)
				else
					-- (a sinus is darker than a vein of the surface)
					local vc = VEIN[(id <= 4) and math.max(row - 1, 1) or row]
					x, y, z = vc[1], vc[2], vc[3]
				end
				surface.SetDrawColor(x, y, z, 255)
				surface.DrawRect(px, py + row - 1, PAL_CELL, 1)
			end
		else
			if kind == "r" then x, y, z = RegionRGB(A.regions[id], d)
			else x, y, z = TractRGB(A.tracts[id], d) end
			if lit then
				local g = glowNow[sk]
				if g then x, y, z = Mix({ x, y, z }, GLOW, floor(g * 8 + 0.5) / 8) end
			end
			surface.SetDrawColor(x, y, z, 255)
			surface.DrawRect(px, py, PAL_CELL, PAL_CELL)
		end
		n = n + 1
	end
	cam.End2D()
	render.PopRenderTarget()
	DisableClipping(old)
	return n
end

-- What the paint stands on: the colours, and what is in use, in eighths.
local function PaintKey(d)
	local k = ColourKey(d) .. "/" .. #BS.patches
	if view.mode == "activation" then
		local s = 0
		for sk, g in pairs(glowNow) do s = s + (tonumber(string.sub(sk, 2)) or 0) * floor(g * 8 + 0.5) end
		k = k .. "/" .. s
	end
	return k
end

local colourKey, paintedKey
local nextPaint = 0
local meshTodo
local function Ready(d)
	if not built then
		local t0 = SysTime()
		Build()
		B3.buildMs = (SysTime() - t0) * 1000
		meshTodo = {}
		for _, sides in pairs(layers) do
			for _, part in pairs(sides) do meshTodo[#meshTodo + 1] = part end
		end
	end
	Materials()
	-- (the bodies' meshes: one a frame, so that opening the window does not stop the game)
	if #meshTodo > 0 then
		local t0 = SysTime()
		local part = table.remove(meshTodo)
		part.mesh = Mesh()
		part.mesh:BuildFromTriangles(part.tris)
		B3.buildMs = B3.buildMs + (SysTime() - t0) * 1000
	end
	local surfaces = BS.Step(0.012)
	-- (the vessels after the surfaces, a few thousand triangles a frame)
	local vessels = surfaces and BV.Step(0.006, VesselUV)
	B3.surfReady = surfaces and vessels and #meshTodo == 0
	local pk = PaintKey(d)
	-- (a target can lose what was painted into it, so it is painted again every few seconds)
	if pk ~= paintedKey or SysTime() > nextPaint then
		paintedKey, nextPaint = pk, SysTime() + 3
		local lit = view.mode == "activation"
		local function Shows(sk)
			local id = tonumber(string.sub(sk, 2))
			local x, y, z
			if string.sub(sk, 1, 1) == "r" then x, y, z = RegionRGB(A.regions[id], d) else x, y, z = TractRGB(A.tracts[id], d) end
			if lit then
				local g = glowNow[sk]
				if g then x, y, z = Mix({ x, y, z }, GLOW, floor(g * 8 + 0.5) / 8) end
			end
			return x, y, z
		end
		local t0 = SysTime()
		BS.Paint("cortex", Shows)
		BS.Paint("hind", Shows)
		B3.bakeParts = PaintPalette(d, lit)
		B3.bakeMs = (SysTime() - t0) * 1000
		B3.bakeAllMs = B3.bakeAllMs or B3.bakeMs
		B3.paints = (B3.paints or 0) + 1
	end
	-- (how often the colours themselves have changed: what is in use does not count)
	local key = ColourKey(d)
	if key ~= colourKey then colourKey, B3.bakes = key, (B3.bakes or 0) + 1 end
end

-- Which channels the watched character is using. For a character with a record the server says
-- it; one without is uninjured, and what it is doing (the actions of sh_atlas.lua) says it.
local chanIndex = {}
local function InUse(d)
	if d.has then return d.on end
	local bits = d.actions or 0
	if bits == 0 then return nil end
	local dom = d.dom or "L"
	local idx = chanIndex[dom]
	if not idx then
		idx = {}
		for i, c in ipairs(A.compiled[dom]) do idx[c.key] = i end
		chanIndex[dom] = idx
	end
	local on = {}
	for i, a in ipairs(A.actions) do
		if bit.band(bits, bit.lshift(1, i - 1)) ~= 0 then
			for _, k in ipairs(a.channels) do
				if idx[k] then on[idx[k]] = true end
			end
		end
	end
	return on
end

-- what the watched character is using: lights up the structures it runs on, and fades
local function Activity(d, dt)
	local fade = dt * 1.2
	for id, a in pairs(act) do act[id] = a > fade and a - fade or nil end
	for id, a in pairs(tact) do tact[id] = a > fade and a - fade or nil end
	local on = InUse(d)
	if on then
		local comp = A.compiled[d.dom or "L"]
		for i = 1, #comp do
			if on[i] then
				for _, s in ipairs(comp[i].stages) do
					for _, it in ipairs(s.items) do
						local tbl = it[1] and tact or act
						tbl[it[2]] = max(tbl[it[2]] or 0, 0.35 + 0.65 * it[3])
					end
				end
			end
		end
	end
	-- (a structure that is destroyed or switched off does not light up, whatever is asked of it)
	for k in pairs(glowNow) do glowNow[k] = nil end
	for id, a in pairs(act) do
		local g = a * (1 - (d.d[id] or 0)) * (1 - (d.rs[id] or 0))
		if g > 0.02 then glowNow["r" .. id] = min(g, 1) end
	end
	for id, a in pairs(tact) do
		local g = a * (1 - (d.td[id] or 0)) * (1 - (d.ts[id] or 0))
		if g > 0.02 then glowNow["t" .. id] = min(g, 1) end
	end
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
-- window: drawn among the game's flat drawing, where nothing is tested against depth unless asked
-- (without it the far side of the brain was drawn over the near one in the order of the mesh,
-- run p25c).
local ORDER = { "deep", "tracts", "arteries", "branches", "veins" }
-- what is needed to know of the frame the brain is drawn in: its matrix (everything is in the
-- proportions of a head already), the angles of the eye and the place the light is worked out for
local ctx = {}
local function DrawLayers(alpha, ignoreSide, window)
	local side = ignoreSide and "B" or view.side
	if window then render.OverrideDepthEnable(true, true) end
	-- (The deep nuclei lie inside the hemispheres. Under a cortex that is not clear they are not
	-- drawn: they are bodies at the atlas's places, a little larger than the walls the surface has
	-- there, and would stand out of its inner face and its base.)
	local buried = view.layers.cortex and alpha >= 0.99 and BS.Has("cortex")
	-- (In a head the cord goes down the neck's canal, which does not run the way the mesh's cord does:
	-- what lies beyond the skull's base is drawn a second time, turned about that place, and each
	-- time only the side of the plane between the two that belongs to it. ctx.cord: DrawInHead.)
	local cord, clip = ctx.cord, nil
	if cord then
		clip = render.EnableClipping(true)
		render.PushCustomClipPlane(cord.brainN, cord.brainD)
	end
	cam.PushModelMatrix(ctx.mp)
	BS.LightsOn(ctx.ang, ctx.at)
	render.SetMaterial(matLit)
	for _, name in ipairs(ORDER) do
		if view.layers[name] and layers[name] and not (buried and name == "deep") then
			for s, part in pairs(layers[name]) do
				if part.mesh and (side == "B" or s == "M" or s == side) then part.mesh:Draw() end
			end
		end
	end
	-- the vessels: the arteries, their branches, the veins and sinuses
	-- (in a head that is not near, the fine ones are thinner than a pixel and are left out)
	if view.layers.arteries then BV.Draw(0, side, matVessel, matFine, ctx.coarse) end
	if view.layers.branches then BV.Draw(1, side, matVessel, matFine, ctx.coarse) end
	if view.layers.veins then BV.Draw(2, side, matVessel, matFine, ctx.coarse) end
	render.SetMaterial(matLit)
	if view.layers.hind and BS.Has("hind") then BS.Draw("hind", side, 1) end
	if view.layers.cortex and alpha > 0.01 and BS.Has("cortex") then
		-- (a clear cortex hides nothing that is drawn after it)
		if alpha < 0.99 and window then render.OverrideDepthEnable(true, false) end
		if alpha < 0.99 then BS.Glass(alpha) end
		BS.Draw("cortex", side, alpha)
	end
	BS.LightsOff(window)
	cam.PopModelMatrix()
	if cord then
		-- the cord's side: the stem's surface, the tracts and the vessels that run down it
		render.PopCustomClipPlane()
		render.PushCustomClipPlane(cord.cordN, cord.cordD)
		cam.PushModelMatrix(cord.mp)
		BS.LightsOn(ctx.ang, ctx.at)
		render.SetMaterial(matLit)
		if view.layers.tracts and layers.tracts then
			for s, part in pairs(layers.tracts) do
				if part.mesh and (side == "B" or s == "M" or s == side) then part.mesh:Draw() end
			end
		end
		if view.layers.arteries then BV.Draw(0, side, matVessel, matFine, ctx.coarse) end
		if view.layers.veins then BV.Draw(2, side, matVessel, matFine, ctx.coarse) end
		render.SetMaterial(matLit)
		if view.layers.hind and BS.Has("hind") then BS.Draw("hind", side, 1, "stem") end
		BS.LightsOff(window)
		cam.PopModelMatrix()
		render.PopCustomClipPlane()
		render.EnableClipping(clip)
	end
	if window then render.OverrideDepthEnable(false, false) end
end

-- The atlas's frame into a frame of the game: x (left) to the game's y, y (front) to its x. The
-- atlas counts every axis of the head from -1 to 1; a head is longer than it is wide or high, and
-- the window gives it the proportions the game's head has (C.Anatomy.headX, headY, headZ).
local SCALE = 10
local SX, SY, SZ = SCALE * C.Anatomy.headX / 3.0, SCALE * C.Anatomy.headY / 3.0, SCALE * C.Anatomy.headZ / 3.0
-- (what is drawn has the head's proportions in it: a turn and one scale)
local viewMP = Matrix()
viewMP:SetUnpacked(0, SCALE, 0, 0, SCALE, 0, 0, 0, 0, 0, SCALE, 0, 0, 0, 0, 1)
local function ToView(x, y, z) return Vector(y * SY, x * SX, z * SZ) end

------------------------------------------------------------------------------------------
-- The viewer
------------------------------------------------------------------------------------------
surface.CreateFont("NT_B3", { font = "Tahoma", size = 14, weight = 600, antialias = true })
surface.CreateFont("NT_B3Small", { font = "Tahoma", size = 13, weight = 500, antialias = true })
surface.CreateFont("NT_B3Head", { font = "Tahoma", size = 18, weight = 800, antialias = true })

local MODES = {
	{ "natural", "As it looks" }, { "lobes", "Lobes" }, { "damage", "Damage" }, { "perfusion", "Blood flow" }, { "activation", "In use now" },
	{ "motor", "Motor" }, { "language", "Language" }, { "visual", "Vision" }, { "sensory", "Feeling, hearing" }, { "vascular", "Arterial territories" },
}
local function Layers(t)
	local l = view.layers
	for k in pairs(l) do l[k] = t[k] == true end
end
local PRESETS = {
	-- (each with the height it is best seen from: the circle of Willis lies under the brain)
	{ "Whole brain", function() Layers({ cortex = true, hind = true, deep = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch = 1, 64, -0.05, 0, 12 end },
	-- (the arteries no longer come up the whole neck: these two are framed on the brain)
	{ "Vasculature", function() Layers({ cortex = true, hind = true, arteries = true, branches = true, veins = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch = 0.14, 72, -0.3, 0, 6 end },
	{ "Circle of Willis", function() Layers({ cortex = true, hind = true, arteries = true, branches = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch = 1, 44, -0.5, 0, -66 end },
	{ "Deep grey", function() Layers({ cortex = true, deep = true, hind = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch = 0.12, 52, -0.1, 0, 14 end },
	{ "Hindbrain and cord", function() Layers({ cortex = true, hind = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch = 0.2, 110, -1.5, -0.3, 4 end },
	{ "Motor pathway", function() Layers({ cortex = true, hind = true, tracts = true }) view.alpha, view.dist, view.tz, view.ty, view.pitch, view.mode = 0.1, 110, -1.3, -0.2, 4, "motor" end },
}
B3.presets = PRESETS

local selected            -- the structure that was asked about
local function Channels(d, kind, id)
	-- the functions a structure carries, with what each still does
	local out = {}
	local comp = A.compiled[d.dom or "L"]
	for i, c in ipairs(comp) do
		for _, s in ipairs(c.stages) do
			for _, it in ipairs(s.items) do
				if it[2] == id and ((kind == "t") == (it[1] == true)) then
					out[#out + 1] = string.format("%s: %d%% of \"%s\"  ->  %s now at %d%%", A.channelNames[c.key] or c.key, floor(it[3] * 100 + 0.5), s.name, c.key, floor((d.has and d.ch[i] or 1) * 100 + 0.5))
				end
			end
		end
	end
	return out
end

local function Describe(d, s)
	local lines = {}
	local kind, id = s[1], s[2]
	if kind == "r" then
		local r = A.regions[id]
		local dm, off = d.d[id] or 0, d.rs[id] or 0
		lines[1] = string.upper(r.name)
		lines[#lines + 1] = string.format("%s%s", r.lobe, r.brodmann ~= "" and ("  |  Brodmann " .. r.brodmann) or "")
		lines[#lines + 1] = string.format("Integrity: %d%%", floor((1 - dm) * 100 + 0.5))
		lines[#lines + 1] = string.format("Working now: %d%%%s", floor((1 - dm) * (1 - off) * 100 + 0.5), off > 0.05 and "  (switched off in part: blood, pressure or after a seizure)" or "")
		lines[#lines + 1] = string.format("Blood flow: %d%%", floor((1 - (d.low[id] or 0)) * 100 + 0.5))
		lines[#lines + 1] = string.format("Activation: %d%%", floor(Clamp((act[id] or 0) * (1 - dm) * (1 - off), 0, 1) * 100 + 0.5))
		local sup = {}
		for key, share in pairs(r.supply) do
			local v = A.Vessel(key)
			sup[#sup + 1] = string.format("%s %d%%", v and v.name or key, floor(share * 100 + 0.5))
		end
		table.sort(sup)
		lines[#lines + 1] = "Supplied by: " .. table.concat(sup, ", ")
	elseif kind == "t" then
		local t = A.tracts[id]
		lines[1] = string.upper(t.name)
		lines[#lines + 1] = t.cord and "spinal cord (from Z-City's spine)" or "white matter"
		lines[#lines + 1] = string.format("Integrity: %d%%", floor((1 - (d.td[id] or 0)) * 100 + 0.5))
		lines[#lines + 1] = string.format("Conducting now: %d%%", floor((1 - (d.td[id] or 0)) * (1 - (d.ts[id] or 0)) * 100 + 0.5))
		lines[#lines + 1] = string.format("Activation: %d%%", floor(Clamp(tact[id] or 0, 0, 1) * 100 + 0.5))
	else
		local v = A.vessels[id]
		lines[1] = string.upper(v.name)
		lines[#lines + 1] = ({ T = "trunk", S = "segment", W = "circle of Willis", C = "cortical branch", P = "perforator (end artery)" })[v.kind] or ""
		lines[#lines + 1] = string.format("Open: %d%%", floor((1 - (d.shut[id] or 0)) * 100 + 0.5))
		local feeds = {}
		for _, r in ipairs(A.regions) do
			if r.supply[v.key] then feeds[#feeds + 1] = string.format("%s %d%%", r.name, floor(r.supply[v.key] * 100 + 0.5)) end
		end
		if #feeds > 0 then lines[#lines + 1] = "Feeds: " .. table.concat(feeds, ", ", 1, min(#feeds, 5)) .. (#feeds > 5 and " ..." or "") end
	end
	if kind ~= "v" then
		for i, l in ipairs(Channels(d, kind, id)) do
			if i > 7 then lines[#lines + 1] = "..." break end
			lines[#lines + 1] = l
		end
	end
	return lines
end

local function Data()
	local BV = NT.BrainView
	local d = BV and BV.Data()
	if not d or CurTime() - d.t > 3 or not d.has then
		EMPTY.name = d and d.name or nil
		EMPTY.actions = (d and CurTime() - d.t <= 3) and d.actions or 0
		return EMPTY, d ~= nil and CurTime() - d.t <= 3
	end
	return d, true
end

-- The camera of the viewer: turned about the point it looks at.
local function Camera()
	local at = ToView(view.tx, view.ty, view.tz)
	local ang = Angle(view.pitch, view.yaw, 0)
	local pos = at - ang:Forward() * view.dist
	return pos, ang, at
end

-- Where a point of the viewer's space is in the viewport, in the viewport's own pixels: worked out
-- from the camera. (It was asked of Vector:ToScreen at first. Inside a 3D context with a viewport
-- of its own, ScrW and ScrH are the viewport's, while ToScreen answers in the pixels of the whole
-- screen, as if the viewport were stretched over it: the mark of a structure was drawn far from
-- it, runs p25d to p25f. The field of view given to cam.Start3D is the one across the viewport's
-- width as it is. Checked in the picture itself: the mark and the click land on the structure to
-- the pixel, scene neuro_brain3d.)
local FOV = 38
local function Projector(pos, ang, w, h)
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local k = (w * 0.5) / math.tan(math.rad(FOV * 0.5))
	return function(p)
		local d = p - pos
		local z = max(d:Dot(f), 1)
		return w * 0.5 + d:Dot(r) / z * k, h * 0.5 - d:Dot(u) / z * k, z
	end, { pos = pos, fwd = f, right = r, up = u, k = k, w = w, h = h }
end

local function KeyOf(s)
	if not s then return nil end
	local o = s[1] == "r" and A.regions[s[2]] or (s[1] == "t" and A.tracts[s[2]] or A.vessels[s[2]])
	return o and o.key
end

local Pick

local function PaintView(self, w, h)
	local d, answered = Data()
	Activity(d, FrameTime())
	Ready(d)
	if view.spin and not self.dragging then view.yaw = (view.yaw + FrameTime() * 14) % 360 end
	local x, y = self:LocalToScreen(0, 0)
	surface.SetDrawColor(13, 17, 30, 255)
	surface.DrawRect(0, 0, w, h)
	local pos, ang, at = Camera()
	local tDraw = SysTime()
	render.SetScissorRect(x, y, x + w, y + h, true)
	cam.Start3D(pos, ang, FOV, x, y, w, h, 2, 600)
	render.ClearDepth()
	render.SuppressEngineLighting(true)
	ctx.mp, ctx.ang, ctx.at, ctx.coarse = viewMP, ang, at, false
	DrawLayers(view.alpha, false, true)
	render.SuppressEngineLighting(false)
	-- (For the test scenes: a body of a colour nothing else has, at the place of what was asked
	-- about, over everything; where it is found in the picture is where the structure is drawn.)
	local probe = B3.probeArmed and selected
	local said
	if probe then
		local p = ToView(selected[3], selected[4], selected[5])
		render.SetColorMaterialIgnoreZ()
		render.DrawSphere(p, 0.5, 12, 12, Color(255, 0, 255))
		local a, q = at:ToScreen(), p:ToScreen()
		said = string.format("the middle at %.0f, %.0f and the structure at %.0f, %.0f of a screen of %d x %d", a.x, a.y, q.x, q.y, ScrW(), ScrH())
	end
	cam.End3D()
	render.SetScissorRect(0, 0, 0, 0, false)
	-- where the structures are in the viewport, for the mark and for a click beside every body
	local Proj, eye = Projector(pos, ang, w, h)
	self.eye = eye
	B3.drawMs = (B3.drawMs or 0) * 0.9 + (SysTime() - tDraw) * 100
	local right = eye.right
	local hits = self.hits
	local buried = view.layers.cortex and view.alpha >= 0.99 and BS.Has("cortex")
	for i = 1, #structures do
		local s = structures[i]
		local shown = view.layers[s[7]] and (view.side == "B" or s[8] == "M" or s[8] == view.side) and not (buried and s[7] == "deep")
		local hit = hits[i]
		if not hit then hit = {} hits[i] = hit end
		hit.shown = shown
		if shown then
			local p = ToView(s[3], s[4], s[5])
			local sx, sy, depth = Proj(p)
			local ex = Proj(p + right * (s[6] * SCALE))
			hit.x, hit.y, hit.r, hit.depth = sx, sy, max(abs(ex - sx), 5), depth
		end
	end
	if probe then
		B3.probeArmed = nil
		render.CapturePixels()
		local n, sumX, sumY = 0, 0, 0
		for py = y, y + h - 1, 2 do
			for px = x, x + w - 1, 2 do
				local r, g, b = render.ReadPixel(px, py)
				if r > 200 and g < 70 and b > 200 then n, sumX, sumY = n + 1, sumX + px, sumY + py end
			end
		end
		local hit
		for i = 1, #structures do if structures[i] == selected then hit = hits[i] break end end
		local res = { n = n, drawnX = n > 0 and sumX / n - x or -1, drawnY = n > 0 and sumY / n - y or -1, markX = hit and hit.x or -1, markY = hit and hit.y or -1, toScreen = said, w = w, h = h }
		if n > 0 then
			local t0 = SysTime()
			res.picked = KeyOf(Pick(self, res.drawnX, res.drawnY)) or "nothing"
			res.pickMs = (SysTime() - t0) * 1000
		end
		B3.probe = res
	end

	-- the mark on what was asked about, and what is known of it
	if selected then
		local hit
		for i = 1, #structures do if structures[i] == selected then hit = hits[i] break end end
		if hit and hit.shown then surface.DrawCircle(hit.x, hit.y, hit.r + 3, 255, 235, 110, 255) end
		local lines = Describe(d, selected)
		local bw = 0
		surface.SetFont("NT_B3Small")
		for _, l in ipairs(lines) do bw = max(bw, (surface.GetTextSize(l))) end
		bw = min(bw + 24, w - 24)
		local bx, by = w - bw - 12, 12
		draw.RoundedBox(8, bx, by, bw, #lines * 17 + 18, Color(24, 28, 42, 235))
		for i, l in ipairs(lines) do
			draw.SimpleText(l, i == 1 and "NT_B3" or "NT_B3Small", bx + 12, by + 8 + (i - 1) * 17, i == 1 and Color(255, 235, 150) or Color(226, 228, 236))
		end
	end
	local who = d.name and ("brain of " .. d.name) or "no answer from the server (neuro_dev 1, superadmin)"
	if answered and d == EMPTY then who = who .. ": no neurological record (uninjured)" end
	draw.SimpleText(who, "NT_B3", 14, h - 44, Color(150, 195, 255))
	draw.SimpleText("drag to turn  |  wheel to come near  |  click a structure to ask about it", "NT_B3Small", 14, h - 24, Color(150, 154, 170))
end

-- The structure under a point of the viewport. First the ray from the eye through that point,
-- against every triangle that is drawn: the structure of the nearest one is what was pointed at.
-- (A click is rare, and this takes some tens of milliseconds.) The atlas's frame from the viewer's:
local function FromView(v) return v.y / SX, v.x / SY, v.z / SZ end
local function RayPick(self, mx, my)
	local eye = self.eye
	if not eye then return nil end
	local ox, oy, oz = FromView(eye.pos)
	local dx, dy, dz = FromView(eye.fwd + eye.right * ((mx - eye.w * 0.5) / eye.k) - eye.up * ((my - eye.h * 0.5) / eye.k))
	local glass = view.alpha < 0.5
	-- (the deep nuclei are not drawn under a cortex that is not clear: nor are they clicked)
	local buried = view.layers.cortex and view.alpha >= 0.99 and BS.Has("cortex")
	local best, bt
	for name, sides in pairs(layers) do
		-- (through a cortex that is nearly clear, what lies inside is meant)
		if view.layers[name] and not (glass and name == "cortex") and not (buried and name == "deep") then
			for s, part in pairs(sides) do
				if view.side == "B" or s == "M" or s == view.side then
					local tris = part.tris
					for i = 1, #tris, 3 do
						local a, b, c = tris[i], tris[i + 1], tris[i + 2]
						local ax, ay, az = a.ax, a.ay, a.az
						local bx, by, bz = b.ax, b.ay, b.az
						local cx, cy, cz = c.ax, c.ay, c.az
						local e1x, e1y, e1z = bx - ax, by - ay, bz - az
						local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
						local px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
						local det = e1x * px + e1y * py + e1z * pz
						if det > 1e-12 or det < -1e-12 then
							local inv = 1 / det
							local tx, ty, tz = ox - ax, oy - ay, oz - az
							local u = (tx * px + ty * py + tz * pz) * inv
							if u >= 0 and u <= 1 then
								local qx, qy, qz = ty * e1z - tz * e1y, tz * e1x - tx * e1z, tx * e1y - ty * e1x
								local v = (dx * qx + dy * qy + dz * qz) * inv
								if v >= 0 and u + v <= 1 then
									local t = (e2x * qx + e2y * qy + e2z * qz) * inv
									if t > 0 and (not bt or t < bt) then
										-- (the corner of the triangle the point is nearest to says whose it is)
										local near = a
										if u > 1 - u - v and u >= v then near = tris[i + 1] elseif v > 1 - u - v and v > u then near = tris[i + 2] end
										local st = structOf[near.kind]
										st = st and st[near.id]
										if st then best, bt = st, t end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	do
		-- (the vessels are bodies of another file, asked by their middle lines)
		local sc = BS.scale
		local t, kind, id = BV.Ray(view.layers, view.side, ox * sc[1], oy * sc[2], oz * sc[3], dx * sc[1], dy * sc[2], dz * sc[3])
		local st = t and structOf[kind] and structOf[kind][id]
		if st and (not bt or t < bt) then best, bt = st, t end
	end
	for _, layer in ipairs({ "cortex", "hind" }) do
		if view.layers[layer] and not (glass and layer == "cortex") then
			local sc = BS.scale
			local t, sk = BS.Ray(layer, view.side, ox * sc[1], oy * sc[2], oz * sc[3], dx * sc[1], dy * sc[2], dz * sc[3])
			local st = sk and structOf[string.sub(sk, 1, 1)][tonumber(string.sub(sk, 2))]
			if t and (not bt or t < bt) and st then best, bt = st, t end
		end
	end
	return best
end

-- Beside every body (a thin artery is easily missed): the nearest to the eye of the structures
-- whose place the point is near.
function Pick(self, mx, my)
	local found = RayPick(self, mx, my)
	if found then return found end
	local best, bd
	local glass = view.alpha < 0.5
	for i = 1, #structures do
		local hit = self.hits[i]
		if hit and hit.shown then
			local dx, dy = mx - hit.x, my - hit.y
			if dx * dx + dy * dy <= hit.r * hit.r then
				-- (through a cortex that is nearly clear, what lies inside is meant)
				local depth = hit.depth + ((glass and structures[i][7] == "cortex") and 1000 or 0)
				if not bd or depth < bd then best, bd = structures[i], depth end
			end
		end
	end
	return best
end

local function Button(parent, text, x, y, w, h, click, isOn)
	local b = vgui.Create("DButton", parent)
	b:SetPos(x, y)
	b:SetSize(w, h)
	b:SetText("")
	b.Paint = function(_, pw, ph)
		local on = isOn and isOn()
		draw.RoundedBox(6, 0, 0, pw, ph, on and Color(232, 234, 240) or (b:IsHovered() and Color(66, 72, 92) or Color(46, 50, 66)))
		draw.SimpleText(text, "NT_B3Small", 10, ph * 0.5, on and Color(20, 22, 30) or Color(226, 228, 236), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	b.DoClick = click
	return b
end

-- A window that is painted for a test scene is not for hands. The game's window covers the whole
-- screen while a scene runs, so every click on the machine lands in it: one turned the view
-- between two steps (run p25g), another asked about a structure the scene had not asked about
-- (run r25b). The window keeps the mouse (so that clicks do not reach the game) and does nothing
-- with it.
local function Hands(f, off)
	f:SetPaintedManually(off)
	f:SetDraggable(not off)
	f:ShowCloseButton(not off)
	if IsValid(f.side) then f.side:SetMouseInputEnabled(not off) end
	if IsValid(f.view) then f.view:SetMouseInputEnabled(not off) end
end

local function Label(parent, text, x, y)
	local l = vgui.Create("DLabel", parent)
	l:SetPos(x, y)
	l:SetFont("NT_B3Small")
	l:SetTextColor(Color(140, 146, 166))
	l:SetText(string.upper(text))
	l:SizeToContents()
	return l
end

function B3.Open()
	if IsValid(B3.frame) then return B3.frame end
	local sw, sh = ScrW(), ScrH()
	local f = vgui.Create("DFrame")
	f:SetSize(min(sw - 60, 1560), min(sh - 60, 920))
	f:Center()
	f:SetTitle("")
	f:SetDraggable(true)
	f:SetDeleteOnClose(true)
	f:MakePopup()
	f.Paint = function(_, w, h)
		draw.RoundedBox(10, 0, 0, w, h, Color(10, 13, 24, 252))
		draw.SimpleText("NeuroTrauma  |  brain", "NT_B3Head", 16, 6, Color(232, 234, 240))
	end
	f.OnRemove = function()
		B3.frame = nil
		RunConsoleCommand("brain_show_off")
	end
	B3.frame = f

	local side = vgui.Create("DPanel", f)
	side:SetPos(12, 34)
	side:SetSize(300, f:GetTall() - 46)
	side.Paint = function(_, w, h) draw.RoundedBox(10, 0, 0, w, h, Color(28, 32, 46, 255)) end
	local y = 12
	Label(side, "whose", 12, y) y = y + 18
	Button(side, "Mine", 12, y, 86, 26, function() RunConsoleCommand("brain_show_3d", "self") end)
	Button(side, "Under the crosshair", 104, y, 184, 26, function() RunConsoleCommand("brain_show_3d", "aim") end)
	y = y + 38
	Label(side, "hemisphere", 12, y) y = y + 18
	for i, s in ipairs({ { "L", "Left" }, { "B", "Both" }, { "R", "Right" } }) do
		Button(side, s[2], 12 + (i - 1) * 94, y, 88, 26, function() view.side = s[1] end, function() return view.side == s[1] end)
	end
	y = y + 38
	Label(side, "views", 12, y) y = y + 18
	for i, p in ipairs(PRESETS) do
		Button(side, p[1], 12 + ((i - 1) % 2) * 141, y + floor((i - 1) / 2) * 30, 135, 26, function() p[2]() end)
	end
	y = y + math.ceil(#PRESETS / 2) * 30 + 10
	Label(side, "colour by", 12, y) y = y + 18
	for i, m in ipairs(MODES) do
		Button(side, m[2], 12 + ((i - 1) % 2) * 141, y + floor((i - 1) / 2) * 30, 135, 26, function() view.mode = m[1] end, function() return view.mode == m[1] end)
	end
	y = y + math.ceil(#MODES / 2) * 30 + 10
	Label(side, "layers", 12, y) y = y + 18
	local names = { { "cortex", "Cortex" }, { "deep", "Deep nuclei" }, { "hind", "Hindbrain, cord" }, { "tracts", "Motor pathway" }, { "arteries", "Arteries" }, { "branches", "Their branches" }, { "veins", "Veins, sinuses" } }
	for i, n in ipairs(names) do
		Button(side, n[2], 12 + ((i - 1) % 2) * 141, y + floor((i - 1) / 2) * 30, 135, 26, function() view.layers[n[1]] = not view.layers[n[1]] end, function() return view.layers[n[1]] end)
	end
	y = y + math.ceil(#names / 2) * 30 + 10
	Label(side, "cortex opacity", 12, y) y = y + 16
	local sl = vgui.Create("DSlider", side)
	sl:SetPos(12, y)
	sl:SetSize(276, 22)
	sl:SetSlideX(view.alpha)
	sl:SetLockY(0.5)
	sl.TranslateValues = function(_, sx, sy) view.alpha = Clamp(sx, 0, 1) return sx, 0.5 end
	sl.Paint = function(_, w, h)
		draw.RoundedBox(3, 0, h * 0.5 - 3, w, 6, Color(60, 64, 82))
		draw.RoundedBox(3, 0, h * 0.5 - 3, w * view.alpha, 6, Color(200, 190, 150))
	end
	sl.Think = function(s) if not s:IsEditing() then s:SetSlideX(view.alpha) end end
	y = y + 34
	Button(side, "Reset view", 12, y, 135, 28, function() view.yaw, view.pitch = 205, 12 PRESETS[1][2]() view.mode = "natural" selected = nil end)
	Button(side, "Spinning", 153, y, 135, 28, function() view.spin = not view.spin end, function() return view.spin end)

	local v = vgui.Create("DPanel", f)
	v:SetPos(324, 34)
	v:SetSize(f:GetWide() - 336, f:GetTall() - 46)
	v.hits = {}
	v.Paint = PaintView
	v.OnMousePressed = function(s, code)
		if code ~= MOUSE_LEFT or B3.manual then return end
		s.dragging = true
		s.moved = 0
		s.lastX, s.lastY = gui.MousePos()
		s:MouseCapture(true)
	end
	v.OnMouseReleased = function(s, code)
		if code ~= MOUSE_LEFT or B3.manual then return end
		s:MouseCapture(false)
		s.dragging = false
		if (s.moved or 0) < 5 then
			local mx, my = s:CursorPos()
			selected = Pick(s, mx, my)
		end
	end
	v.Think = function(s)
		if B3.manual then s.dragging = false end
		if not s.dragging then return end
		local mx, my = gui.MousePos()
		local dx, dy = mx - s.lastX, my - s.lastY
		s.lastX, s.lastY = mx, my
		s.moved = (s.moved or 0) + abs(dx) + abs(dy)
		view.yaw = (view.yaw - dx * 0.4) % 360
		view.pitch = Clamp(view.pitch + dy * 0.4, -85, 85)
	end
	v.OnMouseWheeled = function(_, delta)
		if B3.manual then return end
		view.dist = Clamp(view.dist * (delta > 0 and 0.9 or 1.1), 14, 220)
	end
	B3.viewport = v
	f.side, f.view = side, v
	if B3.manual then Hands(f, true) end
	return f
end

function B3.Close()
	if IsValid(B3.frame) then B3.frame:Remove() end
end

-- the stream's mode decides: brain_show_3d opens the window, any other mode closes it
hook.Add("NT_BrainViewMode", "NT_Brain3D", function(mode)
	if mode == "3d" then B3.Open() else B3.Close() end
end)

concommand.Add("brain_view", function(_, _, args)
	RunConsoleCommand("brain_show_3d", args[1] or "self")
end, nil, "NeuroTrauma: the brain of a character in three dimensions (superadmin, neuro_dev 1). brain_view [self | aim | name]")

------------------------------------------------------------------------------------------
-- In the head: the same mesh at the head bone, seen through the skull.
------------------------------------------------------------------------------------------
local cvWorld = CreateClientConVar("neuro_brain_world", "0", false, false, "NeuroTrauma: draw the brain inside the heads of near characters (superadmin, neuro_dev 1)", 0, 1)

-- the head's frame, as the server reads it (sv_zcity.lua, Z.HeadFrame)
local lateralSign = {}
local function HeadFrame(ent)
	local b = ent:LookupBone("ValveBiped.Bip01_Head1")
	local m = b and ent:GetBoneMatrix(b)
	if not m then return nil end
	local pos, ang = m:GetTranslation(), m:GetAngles()
	local mdl = ent:GetModel() or ""
	local s = lateralSign[mdl]
	if not s then
		s = 1
		local l, r = ent:LookupBone("ValveBiped.Bip01_L_Clavicle"), ent:LookupBone("ValveBiped.Bip01_R_Clavicle")
		local lm, rm = l and ent:GetBoneMatrix(l), r and ent:GetBoneMatrix(r)
		if lm and rm then
			s = (lm:GetTranslation() - rm:GetTranslation()):Dot(ang:Up()) >= 0 and 1 or -1
			lateralSign[mdl] = s
		end
	end
	local up, face = ang:Forward(), ang:Right()
	return pos + up * 4.2 + face * 0.8, up, face, ang:Up() * s
end
B3.HeadFrame = HeadFrame

local worldMP = Matrix()
-- (the brain lags a little behind a head that is thrown about, and comes back: a show of its own
-- weight, on this client only; the server's atlas does not move)
local lag = setmetatable({}, { __mode = "k" })

-- Where the brain is drawn in a head. It belongs in the skull, and the skull module knows how the
-- skull lies in each model's head and the brain in that skull (lua/skeleton/sh_headfit.lua: one
-- size, a centre and a pitch a model, and the cord's way down the neck). Where that module is
-- loaded and knows the body, the brain is drawn where it says; else, or with neuro_brain_fit 0, at
-- this module's own place and size on the head bone, the same for every model. This is where the
-- mesh is drawn on this client and nothing else: the atlas, the head frame the server reads hits
-- in and every state are what they were.
local cvFit = CreateClientConVar("neuro_brain_fit", "1", false, false, "NeuroTrauma: draw the brain in a head where the skeleton module has fitted the skull to that head (0: at this module's own place on the head bone, one size for every model)", 0, 1)
local cordMP = Matrix()
local cordCtx = {}
local fitWarned

local function DrawInHead(ent, dt)
	local centre, up, face, left = HeadFrame(ent)
	if not centre then return end
	local st = lag[ent]
	if not st then st = { pos = centre, vel = Vector(), off = Vector() } lag[ent] = st end
	if dt > 0 then
		local vel = (centre - st.pos) / dt
		local acc = (vel - st.vel) / dt
		st.pos, st.vel = centre, vel
		-- a spring that is pushed by the head's change of speed, and settles
		st.off = st.off * math.max(1 - dt * 9, 0) - acc * (dt * 0.00035)
		local l = st.off:Length()
		if l > 0.45 then st.off:Mul(0.45 / l) end
	end
	local off = st.off
	local place
	if cvFit:GetBool() and istable(HemoSkeleton) and isfunction(HemoSkeleton.BrainPlace) then
		local ok, res = pcall(HemoSkeleton.BrainPlace, ent)
		if ok then
			place = res
		elseif not fitWarned then
			fitWarned = true
			NT.Print("the skeleton module could not place the brain (%s): drawn at this module's own place", tostring(res))
		end
	end
	local c
	if place then
		-- the fitted skull's frame, as the head bone is now: the mesh's own units -> world
		local r = place.rows
		c = Vector(r[4] + off.x, r[8] + off.y, r[12] + off.z)
		worldMP:SetUnpacked(r[1], r[2], r[3], c.x, r[5], r[6], r[7], c.y, r[9], r[10], r[11], c.z, 0, 0, 0, 1)
		local cd = place.cord
		if cd then
			local q = cd.rows
			cordMP:SetUnpacked(q[1], q[2], q[3], q[4] + off.x, q[5], q[6], q[7], q[8] + off.y, q[9], q[10], q[11], q[12] + off.z, 0, 0, 0, 1)
			-- (a clip plane keeps what lies on the side its normal points to)
			local n = Vector(cd.nx, cd.ny, cd.nz)
			local d = n.x * (cd.hx + off.x) + n.y * (cd.hy + off.y) + n.z * (cd.hz + off.z)
			cordCtx.mp, cordCtx.cordN, cordCtx.cordD, cordCtx.brainN, cordCtx.brainD = cordMP, n, d, -n, -d
			ctx.cord = cordCtx
		end
		B3.worldFit = place.src
	else
		c = centre + off
		local k = 0.86 * 3
		worldMP:SetUnpacked(
			left.x * k, face.x * k, up.x * k, c.x,
			left.y * k, face.y * k, up.y * k, c.y,
			left.z * k, face.z * k, up.z * k, c.z,
			0, 0, 0, 1)
		B3.worldFit = "this module's own place"
	end
	ctx.mp, ctx.ang, ctx.at, ctx.coarse = worldMP, EyeAngles(), c, c:DistToSqr(EyePos()) > 3600
	DrawLayers(0.85, true)
	ctx.cord = nil
end

-- One body's brain drawn in its head now, as below: for the skeleton module's fitting view, which
-- draws a skull and its brain in an order of its own (lua/skeleton/cl_headview.lua). The same
-- people may see it. Returns whether it was drawn.
function B3.DrawHead(body, dt)
	local me = LocalPlayer()
	if not IsValid(me) or not (me:IsSuperAdmin() or me:IsListenServerHost()) or not IsValid(body) then return false end
	local d = Data()
	if not IsValid(B3.frame) and not cvWorld:GetBool() then
		Activity(d, FrameTime())
		Ready(d)
	end
	if not built then return false end
	render.DepthRange(0, 0.02)
	DrawInHead(body, dt or 0)
	render.DepthRange(0, 1)
	return true
end

hook.Add("PostDrawTranslucentRenderables", "NT_Brain3D", function(depth, sky)
	if sky or not cvWorld:GetBool() then return end
	local me = LocalPlayer()
	if not IsValid(me) or not (me:IsSuperAdmin() or me:IsListenServerHost()) then return end
	local d = Data()
	if not IsValid(B3.frame) then
		Activity(d, FrameTime())
		Ready(d)
	end
	if not built then return end
	local eye = EyePos()
	local dt = FrameTime()
	local RagOf = NT.Pose and NT.Pose.RagOf
	-- (Seen through the skull, and still a body: its depth is squeezed into the nearest part of
	-- the range, so that it is in front of the head it is in and its own parts still hide each other.)
	local t0, n = SysTime(), 0
	render.DepthRange(0, 0.02)
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and (ply ~= me or ply:ShouldDrawLocalPlayer()) then
			local body = RagOf and RagOf(ply) or ply
			if IsValid(body) and not body:IsDormant() and body:GetPos():DistToSqr(eye) < 640000 then DrawInHead(body, dt) n = n + 1 end
		end
	end
	render.DepthRange(0, 1)
	if n > 0 then B3.worldMs, B3.worldHeads = (B3.worldMs or 0) * 0.9 + (SysTime() - t0) * 100, n end
end)

------------------------------------------------------------------------------------------
-- For the test scenes: open the window as asked, and say what was built.
------------------------------------------------------------------------------------------
-- (The harness takes its pictures before the game paints its windows: for a test the window is
-- painted by hand, with the rest of the HUD.)
hook.Add("HUDPaint", "NT_Brain3DManual", function()
	if B3.manual and IsValid(B3.frame) then B3.frame:PaintManual() end
end)

function B3.Test(t)
	local d = Data()
	Ready(d)
	if t.manual ~= nil then
		B3.manual = t.manual
		if IsValid(B3.frame) then Hands(B3.frame, t.manual) end
	end
	if t.world ~= nil then RunConsoleCommand("neuro_brain_world", t.world and "1" or "0") end
	if t.probe then B3.probeArmed, B3.probe = true, nil end
	if t.close then B3.Close() return end
	if t.open then B3.Open() end
	if t.preset then
		for _, p in ipairs(PRESETS) do if p[1] == t.preset then p[2]() end end
	end
	if t.mode then view.mode = t.mode end
	if t.yaw then view.yaw = t.yaw end
	if t.pitch then view.pitch = t.pitch end
	if t.dist then view.dist = t.dist end
	if t.at then view.tx, view.ty, view.tz = t.at[1], t.at[2], t.at[3] end
	if t.tune then BS.Tune(t.tune) end
	if t.alpha then view.alpha = t.alpha end
	if t.side then view.side = t.side end
	if t.spin ~= nil then view.spin = t.spin end
	if t.layers then Layers(t.layers) end
	if t.select then
		selected = nil
		for _, s in ipairs(structures) do
			if KeyOf(s) == t.select then selected = s end
		end
	end
	local verts, tris = 0, 0
	for _, sides in pairs(layers) do
		for _, part in pairs(sides) do verts, tris = verts + #part.verts, tris + #part.tris / 3 end
	end
	local st = BS.stats
	local vs = BV.stats
	local rayHit, rayWant
	if t.vesselRay then
		-- (a ray from in front of a vessel straight at it: whose is what it meets first)
		local v = A.Vessel(t.vesselRay)
		local x, y, z = BV.Middle("v", v.id)
		rayWant = "v" .. v.id
		if x then
			local tt, kind, id = BV.Ray({ arteries = true, branches = true, veins = true }, "B", x, y + 0.08, z, 0, -1, 0)
			rayHit = tt and (kind .. id) or "nothing"
		else
			rayHit = "no such vessel among the bodies"
		end
	end
	return { verts = verts + st.verts + vs.verts, tris = tris + st.tris + vs.tris, structures = #structures,
		vessels = vs.vessels, vesselVerts = vs.verts, vesselTris = vs.tris, vesselMeshes = vs.meshes, vesselLoadMs = vs.loadMs, vesselBuildMs = vs.buildMs,
		vesselWorstMs = vs.worstMs, rayHit = rayHit, rayWant = rayWant, selected = selected and Describe(d, selected) or nil,
		surfReady = B3.surfReady, surfLoadMs = st.loadMs, surfBuildMs = st.buildMs, paints = B3.paints,
		buildMs = B3.buildMs, bakeMs = B3.bakeMs, bakeAllMs = B3.bakeAllMs, bakeParts = B3.bakeParts, bakes = B3.bakes, probe = B3.probe,
		glowing = table.Count(glowNow), drawMs = B3.drawMs, worldMs = B3.worldMs, worldHeads = B3.worldHeads }
end
