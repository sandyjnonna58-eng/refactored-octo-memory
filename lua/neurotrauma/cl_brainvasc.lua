-- Client: the vessels of the developer's brain as bodies (cl_brain3d.lua draws with them).
--
-- The arteries from the neck to the surface, the veins and the sinuses are made by
-- tools/braingen with the brain's own surfaces (its class Vasc): every vessel a course with a
-- radius at every point, laid on the folds where it runs on them, a branch beginning inside its
-- trunk. The file (data_static/neurotrauma/vessels.dat) holds the courses, not triangles: a ring
-- of the tube is a middle point, two axes and two radii. Here the rings are made into meshes, a
-- few thousand triangles at a time, so that opening the window does not stop the game.
--
-- A lit mesh cannot carry a colour per vertex. Every vertex points into the viewer's palette
-- instead: at the cell of the atlas's vessel it belongs to (so that a shut artery, or a
-- territory, is a repaint of cells and never a new mesh), and within the cell by how thick the
-- vessel is there: a cell is painted in rows from the colour of a trunk to that of a hair.
--
-- Coordinates: as the surfaces (the atlas's axes in the proportions of a head).

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
NT.BrainVasc = NT.BrainVasc or {}
local BV = NT.BrainVasc
local A = NT.Atlas
local byte, floor, sqrt, cos, sin, min = string.byte, math.floor, math.sqrt, math.cos, math.sin, math.min

BV.stats = { vessels = 0, verts = 0, tris = 0, loadMs = 0, buildMs = 0, worstMs = 0, meshes = 0 }
-- a mesh holds no more triangles than this (what one frame is asked to build)
local CHUNK_TRIS = 1500
-- thinner than this (of the file's 0..1) a vessel is drawn with the material of the fine ones
local FINE = 0.42

-- [layer][side] = { thick = { IMesh ... }, fine = { IMesh ... } }; layers 0 arteries, 1 their branches, 2 veins
local parts = {}
local tubes, raw, at, left
local state = "new"            -- new -> read -> build -> done / none
local uvOf                      -- (kind, id, thickness) -> u, v in the palette: given by the viewer
local ringCos, ringSin = {}, {}
for seg = 3, 16 do
	ringCos[seg], ringSin[seg] = {}, {}
	for j = 0, seg - 1 do ringCos[seg][j], ringSin[seg][j] = cos(j / seg * 2 * math.pi), sin(j / seg * 2 * math.pi) end
end

local function I32(s, o)
	local a, b, c, d = byte(s, o, o + 3)
	local v = a + b * 256 + c * 65536 + d * 16777216
	if v >= 2147483648 then v = v - 4294967296 end
	return v
end
local function S8(v) return (v > 127 and v - 256 or v) / 127 end

local box
local SIDES = { [0] = "L", "R", "M" }

-- Reads the head of the file; false when there is none.
local function Open()
	raw = file.Read("data_static/neurotrauma/vessels.dat", "GAME")
	if not raw or #raw < 30 or string.sub(raw, 1, 4) ~= "NTV1" then raw = nil return false end
	left = byte(raw, 5) + byte(raw, 6) * 256
	local lx, ly, lz = I32(raw, 7) / 65536, I32(raw, 11) / 65536, I32(raw, 15) / 65536
	box = { lx, ly, lz, (I32(raw, 19) / 65536 - lx) / 65535, (I32(raw, 23) / 65536 - ly) / 65535, (I32(raw, 27) / 65536 - lz) / 65535 }
	at = 31
	tubes = {}
	BV.stats.vessels = left
	return true
end

-- The next vessel of the file as a list of rings (numbers only: nothing is drawn from this yet).
local function ReadTube()
	local s, o = raw, at
	local layer, side, kind, id, klen = byte(s, o, o + 4)
	local key = klen > 0 and string.sub(s, o + 5, o + 4 + klen) or ""
	o = o + 5 + klen
	local seg = byte(s, o)
	local n = byte(s, o + 1) + byte(s, o + 2) * 256
	o = o + 3
	local t = { layer = layer, side = SIDES[side] or "M", kind = string.char(kind), id = id, seg = seg, n = n, o = o }
	if t.kind == "v" then
		-- (an artery belongs to a vessel of the atlas; one the atlas does not know is drawn as nobody's)
		t.id = A.vesselOf[key] or 0
		if t.id == 0 then t.kind, t.id = "s", 6 end
	end
	at = o + n * 17
	return t
end

-- current mesh under construction per (layer, side, fine)
local open = {}
local function Flush(key)
	local c = open[key]
	if not c or #c.tris == 0 then return end
	local m = Mesh()
	m:BuildFromTriangles(c.tris)
	local p = parts[c.layer]
	if not p then p = {} parts[c.layer] = p end
	local ps = p[c.side]
	if not ps then ps = { thick = {}, fine = {} } p[c.side] = ps end
	local list = c.fine and ps.fine or ps.thick
	list[#list + 1] = m
	BV.stats.tris = BV.stats.tris + #c.tris / 3
	BV.stats.meshes = BV.stats.meshes + 1
	open[key] = nil
end

-- A vessel, or the next part of a long one, into the mesh it belongs to. Returns true when a mesh
-- was built by it; t.done says that all of the vessel is in a mesh. (A long sinus is thousands of
-- triangles: built in one go it held a frame for 24 ms, run v37d.)
local function BuildTube(t)
	local s = raw
	local lx, ly, lz, kx, ky, kz = box[1], box[2], box[3], box[4], box[5], box[6]
	local seg, n = t.seg, t.n
	local cs, sn = ringCos[seg], ringSin[seg]
	if not cs then t.done = true return false end
	if not t.key then
		-- (how thick it is in the main: which material it has)
		local thSum = 0
		for i = 0, n - 1, 4 do thSum = thSum + byte(s, t.o + i * 17 + 16) end
		t.fine = thSum / (floor((n - 1) / 4) + 1) / 255 < FINE
		t.key = t.layer .. t.side .. (t.fine and "f" or "t")
		-- (the middle line is kept: a click is asked of it)
		t.mx, t.my, t.mz, t.mr = {}, {}, {}, {}
		t.at = 0
	end
	local key = t.key
	local c = open[key]
	if not c then c = { tris = {}, layer = t.layer, side = t.side, fine = t.fine } open[key] = c end
	local tris = c.tris
	local nt = #tris
	local kind, id = t.kind, t.id
	local prev = t.prev
	local mx, my, mz, mr = t.mx, t.my, t.mz, t.mr
	for i = t.at, n - 1 do
		local o = t.o + i * 17
		local a, b, c2, d, e, f, g, h, i2, j2, u1, u2, u3, v1, v2, v3, th = byte(s, o, o + 16)
		local x, y, z = lx + (a + b * 256) * kx, ly + (c2 + d * 256) * ky, lz + (e + f * 256) * kz
		local ru, rv = (g + h * 256) / 65536, (i2 + j2 * 256) / 65536
		mx[i + 1], my[i + 1], mz[i + 1], mr[i + 1] = x, y, z, ru > rv and ru or rv
		local ux, uy, uz, vx, vy, vz = S8(u1), S8(u2), S8(u3), S8(v1), S8(v2), S8(v3)
		-- (the lit shader wants a direction along the surface: the way the vessel runs)
		local tx, ty, tz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		local tl = sqrt(tx * tx + ty * ty + tz * tz)
		if tl < 1e-6 then tx, ty, tz, tl = 0, 0, 1, 1 end
		tx, ty, tz = tx / tl, ty / tl, tz / tl
		local pu, pv = uvOf(kind, id, th / 255)
		local ring = {}
		for j = 0, seg - 1 do
			local ca, sa = cs[j], sn[j]
			local nx, ny, nz = ux * ca * rv + vx * sa * ru, uy * ca * rv + vy * sa * ru, uz * ca * rv + vz * sa * ru
			local nl = sqrt(nx * nx + ny * ny + nz * nz)
			if nl < 1e-9 then nx, ny, nz, nl = ux, uy, uz, 1 end
			ring[j] = { pos = Vector(x + ux * ca * ru + vx * sa * rv, y + uy * ca * ru + vy * sa * rv, z + uz * ca * ru + vz * sa * rv),
				normal = Vector(nx / nl, ny / nl, nz / nl), u = pu, v = pv, userdata = { tx, ty, tz, 1 } }
		end
		if prev then
			for j = 0, seg - 1 do
				local j1 = (j + 1) % seg
				local p0, p1, q0, q1 = prev[j], prev[j1], ring[j], ring[j1]
				tris[nt + 1], tris[nt + 2], tris[nt + 3], tris[nt + 4], tris[nt + 5], tris[nt + 6] = p0, q0, q1, p0, q1, p1
				nt = nt + 6
			end
		end
		prev = ring
		BV.stats.verts = BV.stats.verts + seg
		if nt / 3 >= CHUNK_TRIS and i < n - 1 then
			-- (the mesh is full and the vessel is not at its end: it goes on in the next one)
			t.at, t.prev = i + 1, ring
			Flush(key)
			return true
		end
	end
	t.done, t.prev = true, nil
	if nt / 3 >= CHUNK_TRIS then Flush(key) return true end
	return false
end

-- Does a part of what is left to do; true when the vessels are read and built (or there are none).
-- uv: where in the palette a vessel's colour is (the viewer's).
function BV.Step(budget, uv)
	if state == "done" or state == "none" then return true end
	local t0 = SysTime()
	local st = BV.stats
	uvOf = uv
	if state == "new" then
		if not Open() then
			state = "none"
			NT.Print("the vessels are missing or damaged (data_static/neurotrauma/vessels.dat): the brain is drawn without them")
			return true
		end
		state = "read"
		BV.stats.loadMs = (SysTime() - t0) * 1000
		return false
	end
	if state == "read" then
		while left > 0 do
			tubes[#tubes + 1] = ReadTube()
			left = left - 1
		end
		state = "build"
		at = 1
		BV.stats.loadMs = BV.stats.loadMs + (SysTime() - t0) * 1000
		return false
	end
	-- build: vessels into meshes until one mesh has been built or the time is up
	while at <= #tubes do
		local built = BuildTube(tubes[at])
		if tubes[at].done then at = at + 1 end
		if built or SysTime() - t0 > (budget or 0.008) then
			local ms = (SysTime() - t0) * 1000
			st.buildMs = st.buildMs + ms
			if ms > st.worstMs then st.worstMs = ms end
			return false
		end
	end
	-- (what is left in the meshes that were not full: one a call)
	for key in pairs(open) do
		Flush(key)
		local ms = (SysTime() - t0) * 1000
		st.buildMs = st.buildMs + ms
		if ms > st.worstMs then st.worstMs = ms end
		return false
	end
	state = "done"
	raw = nil
	return true
end

function BV.Has(layer) return parts[layer] ~= nil end

-- Draws a layer. The caller has set the lights and pushed the matrix; thick and fine: the materials.
-- coarse: without the fine vessels (seen from far they are thinner than a pixel).
function BV.Draw(layer, side, thick, fine, coarse)
	local p = parts[layer]
	if not p then return end
	for s, ps in pairs(p) do
		if side == "B" or s == "M" or s == side then
			if #ps.thick > 0 then
				render.SetMaterial(thick)
				for _, m in ipairs(ps.thick) do m:Draw() end
			end
			if #ps.fine > 0 and not coarse then
				render.SetMaterial(fine)
				for _, m in ipairs(ps.fine) do m:Draw() end
			end
		end
	end
end

-- The vessel a ray meets first: how far along the ray, and whose it is (kind, id). A click is rare,
-- and every stretch of every middle line is asked: the nearest places of the ray and the stretch,
-- and whether they are nearer than the vessel is thick there (a hair of a vessel is given a little
-- more, or nobody could point at it). shown: the viewer's layers; the ray in the frame of the meshes.
local LAYER = { [0] = "arteries", "branches", "veins" }
function BV.Ray(shown, side, ox, oy, oz, dx, dy, dz)
	if state ~= "done" or not tubes then return nil end
	local dd = dx * dx + dy * dy + dz * dz
	if dd < 1e-12 then return nil end
	local best, bk, bi
	for n = 1, #tubes do
		local t = tubes[n]
		local mx = t.mx
		if mx and shown[LAYER[t.layer]] and (side == "B" or t.side == "M" or t.side == side) then
			local my, mz, mr = t.my, t.mz, t.mr
			for i = 1, #mx - 1 do
				local ax, ay, az = mx[i], my[i], mz[i]
				local ux, uy, uz = mx[i + 1] - ax, my[i + 1] - ay, mz[i + 1] - az
				local wx, wy, wz = ox - ax, oy - ay, oz - az
				local b, c = dx * ux + dy * uy + dz * uz, ux * ux + uy * uy + uz * uz
				local d, e = dx * wx + dy * wy + dz * wz, ux * wx + uy * wy + uz * wz
				local den = dd * c - b * b
				local sOn = den > 1e-14 and (dd * e - b * d) / den or 0
				if sOn < 0 then sOn = 0 elseif sOn > 1 then sOn = 1 end
				-- (the place on the ray nearest to that place of the stretch)
				local qx, qy, qz = ax + ux * sOn - ox, ay + uy * sOn - oy, az + uz * sOn - oz
				local tr = (qx * dx + qy * dy + qz * dz) / dd
				if tr > 0 and (not best or tr < best) then
					local ex, ey, ez = qx - dx * tr, qy - dy * tr, qz - dz * tr
					local r = (mr[i] + (mr[i + 1] - mr[i]) * sOn) * 1.4 + 0.004
					if ex * ex + ey * ey + ez * ez < r * r then best, bk, bi = tr, t.kind, t.id end
				end
			end
		end
	end
	return best, bk, bi
end

-- A place on a vessel: the middle of the thickest course that belongs to it (for the tests).
function BV.Middle(kind, id)
	if state ~= "done" or not tubes then return nil end
	local best, br
	for n = 1, #tubes do
		local t = tubes[n]
		if t.mx and t.kind == kind and t.id == id then
			local i = math.floor(#t.mx / 2) + 1
			if not br or t.mr[i] > br then best, br = t, t.mr[i] end
		end
	end
	if not best then return nil end
	local i = math.floor(#best.mx / 2) + 1
	return best.mx[i], best.my[i], best.mz[i], best.mr[i]
end
