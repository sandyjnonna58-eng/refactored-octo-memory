-- Film chart: where a body's surface lies in the textures of its materials.
-- The blood film (cl_film.lua) is a layer on the body's surface, and it is drawn by the model
-- itself: the body is drawn once more with a texture of the film's in place of each material's
-- (cl_filmdraw.lua). So the film lies on every vertex the engine skins, in every pose, and no
-- geometry is made for it. That texture is read with the material's own texture coordinates, so the
-- film's cells are laid out there: one grid per material, over the part of its texture space the
-- body's triangles use. A chart is that layout for one surface model (ABL.BodyMesh: one per model
-- and outfit):
--   which triangle of the surface model owns each cell, and from it where the cell is on the body
--     (its place, the surface's normal, how far one cell reaches along the grid's two directions);
--   which cells cannot be painted, because two places of the body far from each other are mapped
--     to the same texels (mirrored hands and shoes: paint on one would show on the other);
--   and where the surface goes on beyond the rim of a material's map: across a texture seam onto
--     another island, or across a gap onto another piece of the mesh (a shirt's hem, trousers).
-- Built once per surface model, in slices (CH.RunJobs). A body most of whose surface cannot be
-- painted has no film: its blood stays with the flow core's channels (cl_flowcore.lua).

ABL.NoJIT()
ABL.FilmChart = ABL.FilmChart or {}
local CH = ABL.FilmChart
local C, BM = ABL.Config, ABL.BodyMesh
local K = C.Film
local sqrt, floor, ceil, min, max, abs = math.sqrt, math.floor, math.ceil, math.min, math.max, math.abs
local yield = coroutine.yield

-- (kept across a reload of this file: a chart that waits for its turn is still built)
CH.jobs = CH.jobs or {}
local jobs = CH.jobs
CH.built = CH.built or 0

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------
-- The triangles of `list` that lie in one stretch along one axis of the texture: islands with
-- nothing between them are told apart, and small ones at either end are left out while what is
-- left out stays under `budget` (area). lo, hi: each triangle's extent along the axis.
-- Returns the stretch kept (a, b) and the area left out.
local function Stretch(list, lo, hi, tarea, budget)
	local order = {}
	for i = 1, #list do order[i] = list[i] end
	table.sort(order, function(p, q) return lo[p] < lo[q] end)
	local groups = {}
	local g
	for i = 1, #order do
		local t = order[i]
		if not g or lo[t] > g.b + 1e-5 then
			g = { a = lo[t], b = hi[t], area = 0 }
			groups[#groups + 1] = g
		end
		if hi[t] > g.b then g.b = hi[t] end
		g.area = g.area + tarea[t]
	end
	local first, last, out = 1, #groups, 0
	-- (the smaller of the two outermost goes first, while it fits)
	while first < last do
		local ga, gb = groups[first], groups[last]
		local pick = ga.area <= gb.area and first or last
		local a = groups[pick].area
		if out + a > budget then break end
		out = out + a
		if pick == first then first = first + 1 else last = last - 1 end
	end
	return groups[first].a, groups[last].b, out
end

local EPS = 1e-4

local function Build(m, ch)
	local nt = m.nt
	local tm, tu1, tv1, tu2, tv2, tu3, tv3 = m.tm, m.tu1, m.tv1, m.tu2, m.tv2, m.tu3, m.tv3
	local vx, vy, vz, t1, t2, t3 = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3
	if not tm or not m.mats then ch.failed = true return end

	-- per triangle: its area, and how the body's surface runs along the texture's two directions
	-- there (the place of a texel is A + Ju (u - u1) + Jv (v - v1), in bind space)
	local tarea = {}
	local jux, juy, juz, jvx, jvy, jvz = {}, {}, {}, {}, {}, {}
	local lists = {}
	for k = 1, #m.mats do lists[k] = {} end
	local total = 0
	for t = 1, nt do
		local a, b, c = t1[t], t2[t], t3[t]
		local ex, ey, ez = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
		local fx, fy, fz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
		local cx, cy, cz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
		local area = 0.5 * sqrt(cx * cx + cy * cy + cz * cz)
		tarea[t] = area
		total = total + area
		local du1, dv1 = tu2[t] - tu1[t], tv2[t] - tv1[t]
		local du2, dv2 = tu3[t] - tu1[t], tv3[t] - tv1[t]
		local det = du1 * dv2 - du2 * dv1
		if abs(det) > 1e-12 then
			local inv = 1 / det
			jux[t], juy[t], juz[t] = (ex * dv2 - fx * dv1) * inv, (ey * dv2 - fy * dv1) * inv, (ez * dv2 - fz * dv1) * inv
			jvx[t], jvy[t], jvz[t] = (fx * du1 - ex * du2) * inv, (fy * du1 - ey * du2) * inv, (fz * du1 - ez * du2) * inv
			local l = lists[tm[t]]
			if l then l[#l + 1] = t end
		else
			-- (all three corners at one place of the texture: no part of it is this triangle's)
			jux[t] = false
		end
		if t % 600 == 0 then yield() end
	end
	ch.jux, ch.juy, ch.juz, ch.jvx, ch.jvy, ch.jvz = jux, juy, juz, jvx, jvy, jvz

	local S = K.canvas - 2 * K.border
	local far2 = K.overlapDist * K.overlapDist
	local maps = {}
	local painted = 0
	local work = 0
	for k = 1, #m.mats do
		local list = lists[k]
		local info = m.mats[k]
		-- (bare skin takes up a little too: what its furrows and its hair hold)
		local mp = { k = k, name = info.name, path = info.path, skin = info.skin, absorb = info.skin and K.skinSoak or info.absorb, ok = false, cells = 0, shared = 0 }
		maps[k] = mp
		if #list > 0 then
			-- how much of the body a unit of texture covers along u and along v, and the extent used
			-- (by what each triangle covers of the texture: one squeezed into a sliver of it stretches
			-- over the body without end, and says nothing about the rest)
			local area, su, sv, uvArea = 0, 0, 0, 0
			local lu, hu, lv, hv = {}, {}, {}, {}
			for i = 1, #list do
				local t = list[i]
				area = area + tarea[t]
				local ua = 0.5 * abs((tu2[t] - tu1[t]) * (tv3[t] - tv1[t]) - (tu3[t] - tu1[t]) * (tv2[t] - tv1[t]))
				uvArea = uvArea + ua
				su = su + ua * (jux[t] * jux[t] + juy[t] * juy[t] + juz[t] * juz[t])
				sv = sv + ua * (jvx[t] * jvx[t] + jvy[t] * jvy[t] + jvz[t] * jvz[t])
				lu[t], hu[t] = min(tu1[t], tu2[t], tu3[t]), max(tu1[t], tu2[t], tu3[t])
				lv[t], hv[t] = min(tv1[t], tv2[t], tv3[t]), max(tv1[t], tv2[t], tv3[t])
			end
			su, sv = sqrt(su / max(uvArea, 1e-12)), sqrt(sv / max(uvArea, 1e-12))
			local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
			for i = 1, #list do
				local t = list[i]
				u0, u1, v0, v1 = min(u0, lu[t]), max(u1, hu[t]), min(v0, lv[t]), max(v1, hv[t])
			end
			local cell = max(K.cell, (u1 - u0) * su / S, (v1 - v0) * sv / S)
			if cell > K.cell * 1.08 then
				-- Too large for the canvas at the cell size asked for. Small islands far off the rest
				-- (a collar's inside, a strip of lining) are left out, if that lets the rest have
				-- finer cells: they get no film.
				local a0, a1, outV = Stretch(list, lv, hv, tarea, area * K.trim)
				local kept = {}
				for i = 1, #list do
					local t = list[i]
					if lv[t] >= a0 - 1e-6 and hv[t] <= a1 + 1e-6 then kept[#kept + 1] = t end
				end
				local b0, b1 = Stretch(kept, lu, hu, tarea, (area - outV) * K.trim)
				local kept2 = {}
				for i = 1, #kept do
					local t = kept[i]
					if lu[t] >= b0 - 1e-6 and hu[t] <= b1 + 1e-6 then kept2[#kept2 + 1] = t end
				end
				local cell2 = max(K.cell, (b1 - b0) * su / S, (a1 - a0) * sv / S)
				if cell2 < cell * 0.9 and #kept2 > 0 then
					list, u0, u1, v0, v1, cell = kept2, b0, b1, a0, a1, cell2
				end
			end
			local cu, cv = cell / max(su, 1e-9), cell / max(sv, 1e-9)
			local W = max(1, min(S, ceil((u1 - u0) / cu - 1e-6)))
			local H = max(1, min(S, ceil((v1 - v0) / cv - 1e-6)))
			mp.u0, mp.v0, mp.cu, mp.cv, mp.W, mp.H, mp.cell, mp.su, mp.sv = u0, v0, cu, cv, W, H, cell, su, sv
			mp.area = area

			-- which triangle owns each cell (the one its centre lies in); a cell two places of the
			-- body far from each other both claim is nobody's
			local tri = {}
			for i = 1, W * H do tri[i] = 0 end
			local qx, qy, qz = {}, {}, {}
			local cells, shared = 0, 0
			for i = 1, #list do
				local t = list[i]
				local a = t1[t]
				local gx1, gy1 = (tu1[t] - u0) / cu, (tv1[t] - v0) / cv
				local e1x, e1y = (tu2[t] - tu1[t]) / cu, (tv2[t] - tv1[t]) / cv
				local e2x, e2y = (tu3[t] - tu1[t]) / cu, (tv3[t] - tv1[t]) / cv
				local det = e1x * e2y - e2x * e1y
				if abs(det) > 1e-12 then
					local idet = 1 / det
					local x0 = max(0, ceil(min(gx1, gx1 + e1x, gx1 + e2x) - 0.5 - EPS))
					local x1 = min(W - 1, floor(max(gx1, gx1 + e1x, gx1 + e2x) - 0.5 + EPS))
					local y0 = max(0, ceil(min(gy1, gy1 + e1y, gy1 + e2y) - 0.5 - EPS))
					local y1 = min(H - 1, floor(max(gy1, gy1 + e1y, gy1 + e2y) - 0.5 + EPS))
					local ax, ay, az = vx[a], vy[a], vz[a]
					local ux, uy, uz, wx, wy, wz = jux[t] * cu, juy[t] * cu, juz[t] * cu, jvx[t] * cv, jvy[t] * cv, jvz[t] * cv
					for y = y0, y1 do
						for x = x0, x1 do
							local px, py = x + 0.5 - gx1, y + 0.5 - gy1
							local b = (px * e2y - py * e2x) * idet
							local c = (py * e1x - px * e1y) * idet
							if b >= -EPS and c >= -EPS and b + c <= 1 + EPS then
								local idx = y * W + x + 1
								local X, Y, Z = ax + ux * px + wx * py, ay + uy * px + wy * py, az + uz * px + wz * py
								local cur = tri[idx]
								if cur == 0 then
									tri[idx] = t
									qx[idx], qy[idx], qz[idx] = X, Y, Z
									cells = cells + 1
								elseif cur > 0 then
									local dx, dy, dz = X - qx[idx], Y - qy[idx], Z - qz[idx]
									if dx * dx + dy * dy + dz * dz > far2 then
										tri[idx] = -1
										cells, shared = cells - 1, shared + 1
									end
								end
							end
						end
					end
				end
				work = work + 1
				if work % 120 == 0 then yield() end
			end
			mp.tri, mp.cells, mp.shared = tri, cells, shared
			mp.links = {}
			mp.ok = cells >= 30 and cells / max(cells + shared, 1) >= K.minUsable
			-- (not the outside of a body: nothing runs over it, and nothing is seen of it)
			for _, pat in ipairs(K.inside) do
				if string.find(mp.name, pat, 1, true) then mp.ok = false end
			end
			if mp.ok then
				local kept = 0
				for i = 1, #list do kept = kept + tarea[list[i]] end
				painted = painted + kept * cells / max(cells + shared, 1)
			end
		end
		yield()
	end
	ch.mats = maps
	ch.share = painted / max(total, 1e-9)
	ch.ok = ch.share >= K.minBody
	ch.ready = true
	CH.built = CH.built + 1
	local parts = {}
	for k = 1, #maps do
		local mp = maps[k]
		if mp.W then
			parts[#parts + 1] = string.format("%s %dx%d cells of %.2f%s%s", mp.name, mp.W, mp.H, mp.cell,
				mp.shared > 0 and string.format(" (%d%% shared)", floor(100 * mp.shared / max(mp.cells + mp.shared, 1) + 0.5)) or "", mp.ok and "" or " (no film)")
		end
	end
	ABL.Print("film chart ready: %s (%d%% of the surface carries a film%s; %s)", tostring(m.model), floor(ch.share * 100 + 0.5), ch.ok and "" or ": too little, the body keeps the flow core", table.concat(parts, ", "))
end

-- The chart of surface model m, or nil while it is being built (and for a model that has none).
function CH.Get(m)
	if not m or not m.ready then return nil end
	local ch = m.chart
	if ch then return ch.ready and ch or nil end
	ch = { m = m, ready = false }
	m.chart = ch
	jobs[#jobs + 1] = { ch = ch, co = coroutine.create(function() Build(m, ch) end) }
	return nil
end

function CH.RunJobs(budgetMs)
	if #jobs == 0 then return end
	local t0 = SysTime()
	while #jobs > 0 and (SysTime() - t0) * 1000 < budgetMs do
		local job = jobs[1]
		local ok, err = coroutine.resume(job.co)
		if not ok then
			job.ch.failed = true
			ABL.Print("film chart build failed for %s: %s", tostring(job.ch.m.model), tostring(err))
			table.remove(jobs, 1)
		elseif coroutine.status(job.co) == "dead" then
			table.remove(jobs, 1)
		end
	end
end

------------------------------------------------------------------------------------------
-- Cells
------------------------------------------------------------------------------------------
-- Cell (x, y) of map mp (both from 0): the triangle that owns it, its place in bind space, and how
-- far one cell reaches on the body along the grid's x and y (two vectors in bind space; their
-- cross product is the cell's area along the surface normal). nil where the grid has no cell.
function CH.Geom(ch, mp, x, y)
	if x < 0 or y < 0 or x >= mp.W or y >= mp.H then return nil end
	local t = mp.tri[y * mp.W + x + 1]
	if t <= 0 then return nil end
	local m = ch.m
	local a = m.t1[t]
	local du, dv = mp.u0 + (x + 0.5) * mp.cu - m.tu1[t], mp.v0 + (y + 0.5) * mp.cv - m.tv1[t]
	local ux, uy, uz, wx, wy, wz = ch.jux[t], ch.juy[t], ch.juz[t], ch.jvx[t], ch.jvy[t], ch.jvz[t]
	return t, m.vx[a] + ux * du + wx * dv, m.vy[a] + uy * du + wy * dv, m.vz[a] + uz * du + wz * dv,
		ux * mp.cu, uy * mp.cu, uz * mp.cu, wx * mp.cv, wy * mp.cv, wz * mp.cv
end

-- The centre of cell (x, y) of map mp as a point of the surface model: its triangle and the weights
-- of that triangle's second and third corner (what ABL.BodyMesh's poses take), and where that is in
-- bind space. nil where the grid has no cell.
function CH.Place(ch, mp, x, y)
	if x < 0 or y < 0 or x >= mp.W or y >= mp.H then return nil end
	local t = mp.tri[y * mp.W + x + 1]
	if t <= 0 then return nil end
	local m = ch.m
	local du, dv = mp.u0 + (x + 0.5) * mp.cu - m.tu1[t], mp.v0 + (y + 0.5) * mp.cv - m.tv1[t]
	local du1, dv1 = m.tu2[t] - m.tu1[t], m.tv2[t] - m.tv1[t]
	local du2, dv2 = m.tu3[t] - m.tu1[t], m.tv3[t] - m.tv1[t]
	local det = du1 * dv2 - du2 * dv1
	local a = m.t1[t]
	return t, (du * dv2 - dv * du2) / det, (dv * du1 - du * dv1) / det,
		m.vx[a] + ch.jux[t] * du + ch.jvx[t] * dv, m.vy[a] + ch.juy[t] * du + ch.jvy[t] * dv, m.vz[a] + ch.juz[t] * du + ch.jvz[t] * dv
end

-- The cell a point of the surface model lies in (triangle t, weights bu, bv of its second and third
-- corner). A point on the rim of a map, or on a triangle smaller than a cell, belongs to the
-- nearest cell there is within one cell. Returns map, x, y, or nil: no film can lie there.
function CH.CellOf(ch, t, bu, bv)
	local m = ch.m
	local mp = ch.mats[m.tm[t]]
	if not mp or not mp.ok then return nil end
	local u = m.tu1[t] + bu * (m.tu2[t] - m.tu1[t]) + bv * (m.tu3[t] - m.tu1[t])
	local v = m.tv1[t] + bu * (m.tv2[t] - m.tv1[t]) + bv * (m.tv3[t] - m.tv1[t])
	local fx, fy = (u - mp.u0) / mp.cu, (v - mp.v0) / mp.cv
	local x, y = floor(fx), floor(fy)
	local W, H, tri = mp.W, mp.H, mp.tri
	if x >= 0 and y >= 0 and x < W and y < H and tri[y * W + x + 1] > 0 then return mp, x, y end
	local bx, by, bd
	for yy = y - 1, y + 1 do
		for xx = x - 1, x + 1 do
			if xx >= 0 and yy >= 0 and xx < W and yy < H and tri[yy * W + xx + 1] > 0 then
				local d = (xx + 0.5 - fx) ^ 2 + (yy + 0.5 - fy) ^ 2
				if not bd or d < bd then bx, by, bd = xx, yy, d end
			end
		end
	end
	if bx then return mp, bx, by end
	return nil
end

-- Where the surface goes on from cell (x, y) of map mp one cell further along (dx, dy), when the
-- grid has no cell there. Across a texture seam the surface is right there, on another island;
-- at an open edge of a piece of the mesh another piece may lie across a gap (K.bridge), facing
-- roughly the same way. Returns the map and the cell it goes on in (and true when that is across
-- such a gap: a hem over trousers, a cuff), or nil: an edge the blood leaves the body at, or a
-- place that cannot be painted. Asked once per cell and direction.
function CH.Link(ch, mp, x, y, dx, dy)
	local key = (y * mp.W + x) * 9 + (dy + 1) * 3 + dx + 1
	local l = mp.links[key]
	if l ~= nil then
		if l then return l[1], l[2], l[3], l[4] end
		return nil
	end
	local m = ch.m
	local found = false
	local t, px, py, pz, ux, uy, uz, wx, wy, wz = CH.Geom(ch, mp, x, y)
	if t then
		local qx, qy, qz = px + ux * dx + wx * dy, py + uy * dx + wy * dy, pz + uz * dx + wz * dy
		local t2, b2, c2 = BM.Closest(m, qx, qy, qz, mp.cell * K.seam)
		if t2 then
			local mp2, x2, y2 = CH.CellOf(ch, t2, b2, c2)
			-- (the nearest surface is the place it came from: there is no more of this piece here)
			if mp2 and not (mp2 == mp and abs(x2 - x) <= 1 and abs(y2 - y) <= 1) then found = { mp2, x2, y2 } end
		end
		if not found then
			local nx, ny, nz = BM.BindNormal(m, t)
			local t3, b3, c3 = BM.Closest(m, qx, qy, qz, K.bridge, m.shell[t], nx, ny, nz, -0.35)
			if t3 then
				local mp3, x3, y3 = CH.CellOf(ch, t3, b3, c3)
				if mp3 then found = { mp3, x3, y3, true } end
			end
		end
	end
	mp.links[key] = found
	if found then return found[1], found[2], found[3], found[4] end
	return nil
end

-- The charts that are still being built are forgotten (they are begun again when they are asked for).
function CH.Clear()
	for i = #jobs, 1, -1 do
		jobs[i].ch.m.chart = nil
		jobs[i] = nil
	end
end
