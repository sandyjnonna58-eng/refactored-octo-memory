-- Client half of the scenes of phase 23 (server/sv_p23test.lua; developer tool, inert unless the test
-- harness is running). The scenes' cameras, figures and checks are cl_p21test.lua's and cl_p22test.lua's;
-- this file sets any number in ABL.Config for the scenes after it and puts it back.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log

-- Every pool within t.r (40) units of t.pos, or all: the surface it lies on, what it holds, what it
-- covers, how deep it stands (mean, deepest, and the spread as a share of the mean, over its cells
-- holding more than a third of a film), and how far its outline strays from a disc (perimeter^2 / 4 pi
-- area over those cells, the perimeter counted along the cells' sides: 16 / pi^2 = 1.62 for a disc,
-- more for a ragged or long one).
local MM = ABL.Config.MM_PER_UNIT
function H.p23pools(t)
	local r2 = (t.r or 40) ^ 2
	local n = 0
	for _, p in ipairs(ABL.Pools.list) do
		local pos = t.pos
		local px, py, pz = p.cx or p.x, p.cy or p.y, p.cz or p.z
		if not pos or (px - pos.x) ^ 2 + (py - pos.y) ^ 2 + (pz - pos.z) ^ 2 < r2 then
			local g = p.sim
			if g then
				n = n + 1
				local N, h, k, blk = g.n, g.h, g.k, g.blk
				local thr = g.film / 3
				local cells, edges, sum, sum2, most = 0, 0, 0, 0, 0
				for j = 0, N - 1 do
					for i = 0, N - 1 do
						local c = j * N + i + 1
						local w = h[c] + k[c]
						if blk[c] == 0 and w > thr then
							cells = cells + 1
							sum, sum2 = sum + w, sum2 + w * w
							if w > most then most = w end
							for _, q in ipairs({ { i - 1, j }, { i + 1, j }, { i, j - 1 }, { i, j + 1 } }) do
								local ii, jj = q[1], q[2]
								if ii < 0 or jj < 0 or ii >= N or jj >= N then
									edges = edges + 1
								else
									local cq = jj * N + ii + 1
									if blk[cq] ~= 0 or h[cq] + k[cq] <= thr then edges = edges + 1 end
								end
							end
						end
					end
				end
				local a = g.a
				local area, per = cells * a * a, edges * a
				local mean = cells > 0 and sum / cells or 0
				local sd = cells > 0 and math.sqrt(math.max(sum2 / cells - mean * mean, 0)) or 0
				Log(string.format("p23pools %s: pool %d on %s (film %.2f mm, slope %.1f degrees): %.2f ml, %.1f units^2 | depth %.2f mm mean (%.2f films), %.2f at most, spread %.2f | outline %.2f | cells %.2f units, %d x %d | wetness %.2f, %s",
					tostring(t.name), p.id, tostring(p.surf and p.surf.name), g.film * MM, math.deg(math.asin(math.min(p.slope or 0, 1))), p.vol, area,
					mean * MM, mean / g.film, most * MM, mean > 0 and sd / mean or 0, area > 0 and per * per / (4 * math.pi * area) or 0, a, N, N,
					p.wet or 0, ABL.PoolSim.Active(g) and "moving" or "at rest"))
			end
		end
	end
	if n == 0 then Log("p23pools " .. tostring(t.name) .. ": no pool") end
end

-- The cells of the pool under t.a along the line from t.a to t.b (world points), every cell's: the floor
-- (zt, mm), the floor the liquid runs on (zf), the wet layer (h, films), set blood (k), the surface
-- (zf + h, mm), what a dry cell holds back (hc, films), viscosity (mu x cf), whether it has been wet,
-- whether it is open, its relief (mr): what a straight line across a merged pool is made of.
function H.p23row(t)
	local P = ABL.Pools
	local best, bd = nil, math.huge
	for _, p in ipairs(P.list) do
		if p.sim then
			local d = (p.cx - t.a.x) ^ 2 + (p.cy - t.a.y) ^ 2
			if d < bd then best, bd = p, d end
		end
	end
	if not best then Log("p23row " .. tostring(t.name) .. ": no pool") return end
	local p, g = best, best.sim
	local N, a = g.n, g.a
	local function Cell(x, y, z)
		local rx, ry, rz = x - p.x, y - p.y, z - p.z
		local u, v = rx * p.sx + ry * p.sy + rz * p.sz, rx * p.tx + ry * p.ty + rz * p.tz
		return math.floor(u / a) - g.i0, math.floor(v / a) - g.j0
	end
	local i0, j0 = Cell(t.a.x, t.a.y, t.a.z)
	local i1, j1 = Cell(t.b.x, t.b.y, t.b.z)
	local steps = math.max(math.abs(i1 - i0), math.abs(j1 - j0), 1)
	Log(string.format("p23row %s: pool %d, cells %.2f, %d x %d, window from (%d, %d); from cell (%d, %d) to (%d, %d)", tostring(t.name), p.id, a, N, N, g.i0, g.j0, i0, j0, i1, j1))
	local film = g.film
	for s = 0, steps do
		local i = math.floor(i0 + (i1 - i0) * s / steps + 0.5)
		local j = math.floor(j0 + (j1 - j0) * s / steps + 0.5)
		if i >= 0 and j >= 0 and i < N and j < N then
			local c = j * N + i + 1
			Log(string.format("  (%3d,%3d) zt %6.3f zf %6.3f h %5.2f k %5.2f surf %6.3f | hc %5.2f mu %6.2f cf %6.2f w %d blk %d mr %6.2f",
				i, j, g.zt[c] * MM, g.zf[c] * MM, g.h[c] / film, g.k[c] / film, (g.zf[c] + g.h[c]) * MM, g.hc[c] / film, g.mu[c], g.cf[c], g.w[c], g.blk[c], g.mr and g.mr[c] or 0))
		end
	end
end

-- The table and key that a dotted name names in ABL.Config ("P22.sunRimK", "Pool.sim.rimGlow").
local function Resolve(name)
	local parts = string.Explode(".", name)
	local tab = ABL.Config
	for i = 1, #parts - 1 do
		tab = tab[parts[i]]
		if not istable(tab) then return nil end
	end
	return tab, parts[#parts]
end

-- t.name (a dotted name in ABL.Config) set to t.value, or put back as it was (t.restore); every pool is
-- painted again (most of these numbers are read only while a pool is painted).
local kept = {}
function H.p23set(t)
	local name = tostring(t.name)
	local tab, key = Resolve(name)
	if not tab then
		Log("p23set " .. name .. ": no such table")
		return
	end
	local was = tab[key]
	if t.restore then
		if kept[name] ~= nil then tab[key], kept[name] = kept[name], nil end
	else
		if kept[name] == nil then kept[name] = was end
		tab[key] = t.value
	end
	for _, p in ipairs(ABL.Pools.list or {}) do p.dirty = true end
	Log(string.format("p23set %s: %s (was %s)", name, tostring(tab[key]), tostring(was)))
end
