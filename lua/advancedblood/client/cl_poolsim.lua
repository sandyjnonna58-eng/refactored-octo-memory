-- Pool liquid.
-- The blood of a pool stands on a lattice laid in the pool's own surface frame (cl_pools.lua).
-- Every cell holds what is on it, in units of thickness:
--   h    liquid that can still run           k    blood that has set (a gel: wet, but it stays)
--   s    blood that has dried there          ab   blood the surface has taken up
-- and the pool is what those add up to. Nothing here knows about drawing or about the engine:
-- arrays and arithmetic.
--   * Liquid moves across a cell face from the higher free surface to the lower one by the flow
--     core's law for a thin layer (mean speed kFlow x slope x h^2 / mu, cl_flowcore.lua), with
--     blood's shear thinning (a layer that moves is thin, one that slows thickens and creeps) and
--     its clotting (blood that has been out of the vessel for most of the clotting time hardly
--     moves). The step is explicit, so what crosses a face in one step is held to a quarter of
--     the head difference and a quarter of the layer: thick blood levels as fast as that allows
--     (a few square units a second), thin blood by the law itself.
--   * The contact line: liquid enters a dry cell only when the head over it exceeds what the
--     surface there holds back (the substrate's film thickness times a pinning value that is
--     fixed in the world, so the outline follows the floor and not the lattice). It holds harder
--     at the tip of a finger than along a straight front and less in a bay (surface tension, by
--     how much of a ring around the dry cell is wet: a count that has no favourite direction, so
--     neither has the outline). A cell that has been wet before takes blood
--     far more easily, and a cell never drains below a residual film. Hence a finite volume comes
--     to rest about one film thick, with an outline of its own.
--   * A slope tilts the free surface: the layer runs downhill, leaves the residual film behind
--     and stops when it has thinned to it. Set and dried blood are part of the floor for what
--     arrives later: fresh blood runs over an old pool, and a clotted rim dams it.
--   * Edges: beyond a ledge the lattice has cells without a floor, and past a line downhill on a
--     slope cells where a stream begins. What crosses into them is gone from the lattice and
--     handed to cl_pools.lua (drops off the ledge, a rivulet down the slope).
--   * Time (PS.Age): the surface drinks up to its capacity, liquid older than the clotting time
--     sets, and every wet cell dries from its surface at the same rate, so thin blood (the rim, a
--     residual film) is dry long before the thick middle.
--   * Only the window of cells in which something moved in the last step is stepped again, and a
--     pool in which nothing moves is not stepped at all.
-- The lattice has a fixed cell size in the world. It grows by taking in more cells (blood is
-- copied, not resampled) and, when it would grow past its size limit, by making one cell of every
-- 2 x 2 (volume kept exactly).

ABL.NoJIT()
ABL.PoolSim = ABL.PoolSim or {}
local PS = ABL.PoolSim
local C = ABL.Config
local KF = C.Flow
local sqrt, min, max, floor, ceil, sin, pi = math.sqrt, math.min, math.max, math.floor, math.ceil, math.sin, math.pi
local ClotF = ABL.FlowCore.ClotF

PS.STEP = 0.05           -- s: the liquid's own time step (20 a second whatever the frame rate)
PS.A0 = 0.4              -- units: the finest cell (about 1 cm)
PS.A_MAX = 3.2           -- units: the coarsest (a pool of several litres)
local LIM = 0.25         -- share of the head difference / of the layer that may cross a face in a step
local MU0 = ABL.FlowCore.ShearF(0)      -- blood at rest, relative to its viscosity at high shear
local SH_REST = 0.02     -- 1/s: below this shear memory a cell counts as at rest
local GEL_TAU = 4        -- s over which liquid past its clotting time sets
local DEPK = 0.5         -- how much of its liquid thickness dried blood still stands (the floor for later blood)
PS.WALL, PS.VOID, PS.EXIT = 1, 2, 3
-- (4: under a body that lies on the floor there, cl_pools.lua BodyMask: blood neither enters nor
-- leaves such a cell; what arrives there goes to the nearest open cell, at the body's edge)
PS.BODY = 4

------------------------------------------------------------------------------------------
-- Pinning: how hard the surface holds the contact line at a place, 0..1 (nothing on about a
-- third of the floor, rising to full on patches and ridges). Value noise at three scales (about
-- 6, 1.6 and 0.7 units) on the plane's own axes: fixed in the world. Most of it at the largest
-- scale: a floor is uneven over a hand's width, and a pool on it has a few broad bays and
-- reaches. (With most of it at 1.6 units, as until phase 34, the outline had a bump every
-- couple of centimetres: a blob with knobs on.)
------------------------------------------------------------------------------------------
local function Hash(ix, iy)
	local s = sin(ix * 127.1 + iy * 311.7) * 43758.5453
	return s - floor(s)
end

local function Noise(x, y)
	local ix, iy = floor(x), floor(y)
	local fx, fy = x - ix, y - iy
	fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	local a, b, c, d = Hash(ix, iy), Hash(ix + 1, iy), Hash(ix, iy + 1), Hash(ix + 1, iy + 1)
	return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
end
PS.Noise = Noise

function PS.Pin(U, V)
	local n = 0.28 * Noise(U * 0.62, V * 0.62) + 0.62 * Noise(U * 0.17 + 31.7, V * 0.17 - 12.3) + 0.1 * Noise(U * 1.5 + 5.1, V * 1.5 + 9.7)
	n = (n - 0.3) * 2
	return n < 0 and 0 or (n > 1 and 1 or n)
end

-- (phase 22, C.P22.relief) The floor's own unevenness: a height in -1..1 (times the surface's
-- amplitude, C.P22.reliefAmp), fixed in the world, at about 6, 2.5 and 1 units across (most of it at
-- the largest: a floor is wavy over a hand's width, rough within a finger's). On a lattice of cells a
-- the finer scales fade out from four cells a wave to two: coarse cells cannot carry them, and taken
-- at the cells' middles they would come back as a speckle that changes when the cells change size.
local function Keep(f, a)
	local r = 1 / (f * a)
	return r >= 4 and 1 or (r <= 2 and 0 or (r - 2) * 0.5)
end
function PS.Relief(U, V, a)
	local n = 0.55 * Keep(0.17, a) * (Noise(U * 0.17 + 71.3, V * 0.17 - 23.9) - 0.5)
		+ 0.30 * Keep(0.4, a) * (Noise(U * 0.4 - 17.7, V * 0.4 + 41.1) - 0.5)
		+ 0.15 * Keep(1.0, a) * (Noise(U * 1.0 + 3.3, V * 1.0 - 8.8) - 0.5)
	return n * 2
end

------------------------------------------------------------------------------------------
-- Lattice. Cell (i, j), 0-based, is lattice cell (i0 + i, j0 + j): its centre lies at
-- ((i0 + i + 0.5) a, (j0 + j + 0.5) a) in the pool's frame. Arrays are indexed j n + i + 1.
--   w    1 once the cell has held blood        tb   when the cell's liquid left the vessel (mean)
--   td   when the cell went dry (0: wet; any other time, also one before the map began)
--   zt   floor height there (relief, tilt)
--   zf   the floor the liquid runs on (zt and what has set or dried on it)
--   hc   head the dry cell holds back          blk  0 open, 1 behind a wall, 2 no floor, 3 a stream begins
--   bq   the clip that closed the cell         sh   shear memory, mu: viscosity from it
--   cf   viscosity from clotting
------------------------------------------------------------------------------------------
local NAMES = { "h", "k", "s", "ab", "tb", "td", "w", "zt", "zf", "blk", "bq", "sh", "gn" }

local function Arrays(g, n)
	for q = 1, #NAMES do
		local t = {}
		for c = 1, n * n do t[c] = 0 end
		g[NAMES[q]] = t
	end
	local hc, mu, cf, mr = {}, {}, {}, {}
	for c = 1, n * n do hc[c], mu[c], cf[c], mr[c] = -1, MU0, 1, -99 end
	g.hc, g.mu, g.cf = hc, mu, cf
	-- (phase 22: the floor's own unevenness at the cell, PS.Relief; -99 until it is looked up)
	g.mr = mr
	-- the ring around a cell by which the contact line's shape there is read: index offsets of
	-- the 16 cells at distances 1, sqrt 2 and sqrt 5. (Not the four at distance 2 along the
	-- lattice's axes. With them, of 20 cells, a straight front along an axis has 8 wet cells
	-- behind it and one across the diagonal has 9: the line held harder along the axes, those
	-- were the slow directions, and every pool grew into a square with rounded corners. Of
	-- these 16 a straight front has 7 behind it whether it runs along an axis, across the
	-- diagonal or between the two.)
	local disc = {}
	for dj = -2, 2 do
		for di = -2, 2 do
			local d2 = di * di + dj * dj
			if d2 == 1 or d2 == 2 or d2 == 5 then disc[#disc + 1] = dj * n + di end
		end
	end
	g.disc = disc
end

function PS.New(a, n, i0, j0)
	local g = {
		a = a, n = n, i0 = i0, j0 = j0,
		film = 0.09, res = 0.02, memK = 0.35, amp = 0.5, kf = KF.kFlow, visc = 1,
		abCap = 0, abTau = 6, edgeDry = 0.12, edgeWet = 0.06, tens = C.Pool.sim.tension,
		kEdge = C.Pool.sim.edgeDrying,
		ax0 = n, ax1 = -1, ay0 = n, ay1 = -1,       -- the window that is still moving (empty: at rest)
		bx0 = n, bx1 = -1, by0 = n, by1 = -1,       -- the cells that have ever held blood
		out = {}, outVol = 0, outLoose = 0,         -- what has crossed an edge (cubic units, by cell; total; without a cell)
		floor = {},                                 -- lattice cells found to have floor (true) or none (false) beyond a ledge's line
		wetN = 0, ver = 0, acc = 0, moved = 0, steps = 0, flip = 0, hullVer = -1,
		pour = {}, pourVol = 0, pourLost = 0,       -- blood on its way in (PS.Pour), its sum, what found no place
		liq = 0, gel = 0, dep = 0, soak = 0, wMin = 1, wMax = 1, tMax = 0, cov = 0, sMax = 0,
	}
	Arrays(g, n)
	return g
end

local function Wake(g, i0, j0, i1, j1)
	local m = g.n - 1
	if i0 < 0 then i0 = 0 end
	if j0 < 0 then j0 = 0 end
	if i1 > m then i1 = m end
	if j1 > m then j1 = m end
	if i0 < g.ax0 then g.ax0 = i0 end
	if i1 > g.ax1 then g.ax1 = i1 end
	if j0 < g.ay0 then g.ay0 = j0 end
	if j1 > g.ay1 then g.ay1 = j1 end
end

-- Everything that has been wet may move again (the ground under it changed).
function PS.WakeAll(g)
	if g.bx1 < g.bx0 then return end
	Wake(g, g.bx0 - 1, g.by0 - 1, g.bx1 + 1, g.by1 + 1)
end

function PS.Active(g) return g.ax1 >= g.ax0 end

local function Wet(g, c, i, j)
	g.w[c] = 1
	g.wetN = g.wetN + 1
	g.ver = g.ver + 1
	if i < g.bx0 then g.bx0 = i end
	if i > g.bx1 then g.bx1 = i end
	if j < g.by0 then g.by0 = j end
	if j > g.by1 then g.by1 = j end
end

-- x of liquid that left the vessel at time t onto cell (i, j).
local function Put(g, i, j, x, t)
	local c = j * g.n + i + 1
	if g.w[c] == 0 then Wet(g, c, i, j) end
	local h = g.h[c]
	g.tb[c] = h > 0 and (g.tb[c] * h + t * x) / (h + x) or t
	g.h[c] = h + x
	g.td[c] = 0
end

-- What is still wet in the lattice (liquid and gel, and what has crossed an edge and waits to
-- be handed on), in cubic units.
function PS.Volume(g)
	local sum = 0
	if g.bx1 >= g.bx0 then
		local h, k, n = g.h, g.k, g.n
		for j = g.by0, g.by1 do
			local c = j * n + 1
			for i = g.bx0, g.bx1 do sum = sum + h[c + i] + k[c + i] end
		end
	end
	return sum * g.a * g.a + g.outVol + g.outLoose + g.pourVol
end

-- The same wet blood, f times as much of it (the pool's own volume is what the books go by;
-- this takes out what rounding has added up).
function PS.Scale(g, f)
	if g.bx1 < g.bx0 then return end
	local h, k, n = g.h, g.k, g.n
	for j = g.by0, g.by1 do
		local c = j * n + 1
		for i = g.bx0, g.bx1 do h[c + i], k[c + i] = h[c + i] * f, k[c + i] * f end
	end
end

------------------------------------------------------------------------------------------
-- Blood arriving and leaving
------------------------------------------------------------------------------------------
-- The open cell nearest to (i, j), or nil. (Six cells away at the most; as far as a body that lies
-- on the floor reaches when there is one on the lattice, g.reach. The answer for a cell is kept
-- until the open cells change: blood that seeps from under a lying body arrives at the same few
-- places drop after drop.)
local function NearestFree(g, i, j)
	local n, blk = g.n, g.blk
	local memo = g.nfMemo
	local key = j * n + i
	if memo then
		local e = memo[key]
		if e then
			if e < 0 then return nil end
			return e % n, (e - e % n) / n
		end
	end
	local R = g.reach or 6
	for r = 0, R do
		for jj = j - r, j + r do
			if jj >= 0 and jj < n then
				local edge = jj == j - r or jj == j + r
				for ii = i - r, i + r, (edge and 1 or max(2 * r, 1)) do
					if ii >= 0 and ii < n and blk[jj * n + ii + 1] == 0 then
						if memo then memo[key] = jj * n + ii end
						return ii, jj
					end
				end
			end
		end
	end
	if memo then memo[key] = -1 end
end

-- vol (cubic units) that left the vessel at time t, at (u, v): shared between the four cells
-- around the point. A point outside the lattice lands on its nearest cell. Returns what found no
-- place (0 unless walls and edges close in the whole neighbourhood).
function PS.Splat(g, u, v, vol, t)
	local a, n = g.a, g.n
	local fx, fy = u / a - g.i0 - 0.5, v / a - g.j0 - 0.5
	if fx < 0 then fx = 0 elseif fx > n - 1 then fx = n - 1 end
	if fy < 0 then fy = 0 elseif fy > n - 1 then fy = n - 1 end
	local i, j = floor(fx), floor(fy)
	if i > n - 2 then i = n - 2 end
	if j > n - 2 then j = n - 2 end
	local tx, ty = fx - i, fy - j
	local blk = g.blk
	local c = j * n + i + 1
	local w00, w10, w01, w11 = (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty
	if blk[c] ~= 0 then w00 = 0 end
	if blk[c + 1] ~= 0 then w10 = 0 end
	if blk[c + n] ~= 0 then w01 = 0 end
	if blk[c + n + 1] ~= 0 then w11 = 0 end
	local sum = w00 + w10 + w01 + w11
	local hh = vol / (a * a)
	if sum < 1e-6 then
		local ii, jj = NearestFree(g, i, j)
		if not ii then
			-- (where it found no place: cl_pools.lua makes the lattice larger round there, when it is a
			-- body lying over all of it, and lays the blood down again)
			g.lostU, g.lostV = u, v
			return vol
		end
		Put(g, ii, jj, hh, t)
		Wake(g, ii - 1, jj - 1, ii + 1, jj + 1)
		return 0
	end
	hh = hh / sum
	if w00 > 0 then Put(g, i, j, hh * w00, t) end
	if w10 > 0 then Put(g, i + 1, j, hh * w10, t) end
	if w01 > 0 then Put(g, i, j + 1, hh * w01, t) end
	if w11 > 0 then Put(g, i + 1, j + 1, hh * w11, t) end
	Wake(g, i - 1, j - 1, i + 2, j + 2)
	return 0
end

-- Blood landing at (u, v). An amount that would stand higher than a few films on one cell lands
-- as the disc it would be at that height (a rounded cap), and spreads from there. shear: blood
-- that arrives moving (a rivulet, a drop from height) is thin for a moment.
function PS.Deposit(g, u, v, vol, t, shear)
	local a, n = g.a, g.n
	local r = sqrt(vol / (pi * 1.25 * g.film))      -- a cap 2.5 films high in the middle
	local fx, fy = u / a - g.i0 - 0.5, v / a - g.j0 - 0.5
	if shear and shear > 0 then
		local i, j = min(max(floor(fx + 0.5), 0), n - 1), min(max(floor(fy + 0.5), 0), n - 1)
		local c = j * n + i + 1
		if shear > g.gn[c] then g.gn[c] = shear end
	end
	if r < a * 0.8 then return PS.Splat(g, u, v, vol, t) end
	local rc = r / a
	local i0, i1, j0, j1 = max(floor(fx - rc), 0), min(ceil(fx + rc), n - 1), max(floor(fy - rc), 0), min(ceil(fy + rc), n - 1)
	local blk = g.blk
	local sum = 0
	for j = j0, j1 do
		for i = i0, i1 do
			local d2 = ((i - fx) ^ 2 + (j - fy) ^ 2) / (rc * rc)
			if d2 < 1 and blk[j * n + i + 1] == 0 then sum = sum + 1 - d2 end
		end
	end
	if sum < 1e-6 then return PS.Splat(g, u, v, vol, t) end
	local f = vol / (a * a) / sum
	for j = j0, j1 do
		for i = i0, i1 do
			local d2 = ((i - fx) ^ 2 + (j - fy) ^ 2) / (rc * rc)
			if d2 < 1 and blk[j * n + i + 1] == 0 then Put(g, i, j, f * (1 - d2), t) end
		end
	end
	Wake(g, i0 - 1, j0 - 1, i1 + 1, j1 + 1)
	return 0
end

-- Blood arriving over time. A call says: vol has arrived at (u, v) by time t. It is taken to
-- have arrived evenly since the pool's last arrival (a tenth of a second back at most), and is
-- laid down by the steps, each step the share that falls into its stretch of time
-- (PS.Advance with a clock): what a step receives does not depend on how the frames fall.
function PS.Pour(g, u, v, vol, t, shear)
	local t0 = g.pourT and max(g.pourT, t - 0.1) or t
	if t0 > t then t0 = t end
	g.pourT = t
	local q = g.pour
	q[#q + 1] = { u = u, v = v, vol = vol, t0 = t0, t1 = t, shear = shear, done = 0 }
	g.pourVol = g.pourVol + vol
	-- (the place is awake: the steps run)
	local a = g.a
	local i, j = floor(u / a) - g.i0, floor(v / a) - g.j0
	Wake(g, i - 2, j - 2, i + 2, j + 2)
end

-- What of the blood on its way in belongs to the time up to T1.
local function Inflow(g, T1)
	local q = g.pour
	local n = #q
	if n == 0 then return end
	local w = 0
	for e = 1, n do
		local it = q[e]
		local span = it.t1 - it.t0
		local to = (it.t1 <= T1 or span < 1e-6) and 1 or (T1 - it.t0) / span
		if to > 1 then to = 1 end
		local d = to - it.done
		if d > 0 then
			local x = it.vol * d
			it.done = to
			g.pourVol = g.pourVol - x
			g.pourLost = g.pourLost + PS.Deposit(g, it.u, it.v, x, it.t1 < T1 and it.t1 or T1, it.shear)
		end
		if it.done < 1 then
			w = w + 1
			q[w] = it
		end
	end
	for e = w + 1, n do q[e] = nil end
	if w == 0 and g.pourVol < 1e-12 then g.pourVol = 0 end
end

-- Take vol (cubic units) of wet blood out of the cells nearest to (u, v). Returns what was not
-- there.
function PS.Take(g, u, v, vol)
	if g.bx1 < g.bx0 then return vol end
	local a, n, h, k = g.a, g.n, g.h, g.k
	local need = vol / (a * a)
	local ci, cj = floor(u / a) - g.i0, floor(v / a) - g.j0
	ci, cj = min(max(ci, g.bx0), g.bx1), min(max(cj, g.by0), g.by1)
	local rMax = max(g.bx1 - g.bx0, g.by1 - g.by0) + 1
	for r = 0, rMax do
		for jj = cj - r, cj + r do
			if jj >= g.by0 and jj <= g.by1 then
				local edge = jj == cj - r or jj == cj + r
				for ii = ci - r, ci + r, (edge and 1 or max(2 * r, 1)) do
					if ii >= g.bx0 and ii <= g.bx1 then
						local c = jj * n + ii + 1
						local t = h[c]
						if t > 0 then
							if t > need then t = need end
							h[c], need = h[c] - t, need - t
						end
						t = k[c]
						if t > 0 and need > 0 then
							if t > need then t = need end
							k[c], need = k[c] - t, need - t
						end
						if need <= 0 then
							Wake(g, ci - r - 1, cj - r - 1, ci + r + 1, cj + r + 1)
							return 0
						end
					end
				end
			end
		end
	end
	PS.WakeAll(g)
	return need * a * a
end

------------------------------------------------------------------------------------------
-- The step
------------------------------------------------------------------------------------------
-- One pass over the faces of the moving window in one direction (vert: faces between rows).
-- In place: what leaves a cell is in its neighbour at once, so nothing is ever created or lost,
-- and no cell gives more than it holds. The order of the passes turns from step to step.
local function Sweep(g, vert, rev, kq, qeps)
	local n = g.n
	local i0, i1, j0, j1 = g.ax0, g.ax1, g.ay0, g.ay1
	if vert then j1 = j1 - 1 else i1 = i1 - 1 end
	if i1 < i0 or j1 < j0 then return 0 end
	local h, w, zf, hc, blk, mu, cf, gn, tb = g.h, g.w, g.zf, g.hc, g.blk, g.mu, g.cf, g.gn, g.tb
	local res, memK, kS, tens, disc = g.res, g.memK, g.kS, g.tens, g.disc
	-- (phase 23, C.P23.bridge: cl_pools.lua sets g.bridgeK, nil while it is off)
	local bridgeK = g.bridgeK
	local o = vert and n or 1
	local js, je, is, ie, d1 = j0, j1, i0, i1, 1
	if rev then js, je, is, ie, d1 = j1, j0, i1, i0, -1 end
	local nx0, nx1, ny0, ny1 = g.nx0, g.nx1, g.ny0, g.ny1
	local moved = 0
	for j = js, je, d1 do
		local c = j * n + is + 1
		for i = is, ie, d1 do
			local e = c + o
			local ha, hb = h[c], h[e]
			if ha > 0 or hb > 0 then
				local bc, be = blk[c], blk[e]
				local q = 0
				-- (a cell under a body that lies on the floor is open to the liquid but stands higher,
				-- PS.SetBody: blood gets under the body only where it stands deeper than that beside it)
				if (bc == 0 or bc == 4) and (be == 0 or be == 4) then
					local d = zf[c] + ha - zf[e] - hb
					local up, dn, hu, hd = c, e, ha, hb
					if d < 0 then up, dn, hu, hd, d = e, c, hb, ha, -d end
					hu = hu - res
					local go = hu > 0
					if go and hd <= 0 then
						-- a dry cell ahead: the contact line holds until the head over it is more than
						-- the surface there holds back, by the line's shape there
						local thr = w[dn] ~= 0 and hc[dn] * memK or hc[dn]
							-- (phase 23, C.P23.bridge) A dry cell with liquid on its far side too is a strip
							-- one cell wide between two bodies of liquid: narrower than the outline can be
							-- drawn (cl_poolcanvas.lua, Taps: the outline went over it, and the strip showed
							-- as a seam in the empty cells' colour across one pool, the two bodies standing
							-- at two depths: runs p23_val and p23_mergedbg5), and the two menisci press on
							-- it from both sides: it holds back bridgeK of what it would.
							if bridgeK then
								local opp
								if dn == e then
									if (vert and j + 2 < n) or (not vert and i + 2 < n) then opp = e + o end
								elseif (vert and j > 0) or (not vert and i > 0) then
									opp = c - o
								end
								if opp and h[opp] > 0 and blk[opp] == 0 then thr = thr * bridgeK end
							end
						if tens > 0 and d > thr * 0.5 then
							local nw = 0
							for q = 1, 16 do
								if (h[dn + disc[q]] or 0) > 0 then nw = nw + 1 end
							end
							local f = 1 + tens * (7 - nw) / 7
							thr = thr * (f > 0.5 and f or 0.5)
						end
						go = d > thr
					end
					if go then
						q = kq * d * hu * hu * hu / (mu[up] * cf[up])
						local lim = (hu < d and hu or d) * LIM
						if q > lim then q = lim end
						if q > qeps then
							h[up] = h[up] - q
							tb[dn] = hd > 0 and (tb[dn] * hd + tb[up] * q) / (hd + q) or tb[up]
							h[dn] = hd + q
							-- (the shear of this move: 3 u / h with u = q a / (h dt))
							local s = kS * q / (hu * hu)
							if s > gn[up] then gn[up] = s end
							if w[dn] == 0 then
								if dn == c then Wet(g, dn, i, j) elseif vert then Wet(g, dn, i, j + 1) else Wet(g, dn, i + 1, j) end
							end
						else
							q = 0
						end
					else
						q = 0
					end
				elseif bc ~= 1 and be ~= 1 and bc ~= 4 and be ~= 4 and (bc == 0 or be == 0) then
					-- an edge: a cell without a floor (the layer bulges at the edge before it goes over,
					-- and holds less once the edge is wet) or the start of a stream down a slope
					local up, sk, hu = c, e, ha
					if bc ~= 0 then up, sk, hu = e, c, hb end
					local out = g.out
					local d
					if blk[sk] == 2 then
						hu = hu - (out[sk] and g.edgeWet or g.edgeDry)
						d = hu
					else
						hu = hu - res
						d = zf[up] - zf[sk] + hu * 0.5
					end
					if hu > 0 and d > 0 then
						q = kq * d * hu * hu * hu / (mu[up] * cf[up])
						local lim = (hu < d and hu or d) * LIM
						if q > lim then q = lim end
						if q > qeps then
							h[up] = h[up] - q
							local x = q * g.aa
							out[sk] = (out[sk] or 0) + x
							g.outVol = g.outVol + x
							local s = kS * q / (hu * hu)
							if s > gn[up] then gn[up] = s end
						else
							q = 0
						end
					end
				end
				if q > 0 then
					moved = moved + q
					if i < nx0 then nx0 = i end
					if i > nx1 then nx1 = i end
					if j < ny0 then ny0 = j end
					if j > ny1 then ny1 = j end
				end
			end
			c = c + d1
		end
	end
	g.nx0, g.nx1, g.ny0, g.ny1 = nx0, nx1, ny0, ny1
	return moved
end
PS.Sweep = Sweep

-- One step of dt seconds. Returns false when the pool is at rest (nothing was stepped).
function PS.Step(g, dt)
	local x0, x1, y0, y1 = g.ax0, g.ax1, g.ay0, g.ay1
	if x1 < x0 or y1 < y0 then return false end
	local a, n = g.a, g.n
	local kq = g.kf * dt / (a * a * g.visc)
	local qeps = g.film * 1e-4
	g.kS = 3 * a / dt
	g.aa = a * a
	g.nx0, g.nx1, g.ny0, g.ny1 = n, -1, n, -1
	local f = g.flip
	g.flip = (f + 1) % 4
	local moved
	if f % 2 == 0 then
		moved = Sweep(g, false, f >= 2, kq, qeps) + Sweep(g, true, f >= 2, kq, qeps)
	else
		moved = Sweep(g, true, f >= 2, kq, qeps) + Sweep(g, false, f >= 2, kq, qeps)
	end
	-- the window of the next step: the cells that gave or took, and those around them
	local m = n - 1
	local nx0, nx1, ny0, ny1 = g.nx0 - 1, g.nx1 + 2, g.ny0 - 1, g.ny1 + 2
	if g.nx1 < g.nx0 then
		nx0, nx1, ny0, ny1 = n, -1, n, -1
	else
		if nx0 < 0 then nx0 = 0 end
		if ny0 < 0 then ny0 = 0 end
		if nx1 > m then nx1 = m end
		if ny1 > m then ny1 = m end
	end
	-- shear memory: blood that moved is thinner for a while (cells leaving the window come to rest)
	local sh, mu, gn = g.sh, g.mu, g.gn
	local kr = min(1, dt / KF.shearTau)
	local sMax = 0
	for j = y0, y1 do
		local c = j * n + x0 + 1
		local inRow = j >= ny0 and j <= ny1
		for i = x0, x1 do
			local s, t = sh[c], gn[c]
			if t > 0 or s > 0 then
				if inRow and i >= nx0 and i <= nx1 then
					s = s + (t - s) * kr
					if s < SH_REST then
						sh[c], mu[c] = 0, MU0
					else
						sh[c] = s
						mu[c] = 1 + 15.23 * (1 + 10.976 * s * s) ^ -0.3216
						if s > sMax then sMax = s end
					end
				else
					sh[c], mu[c] = 0, MU0
				end
				gn[c] = 0
			end
			c = c + 1
		end
	end
	g.sMax = sMax
	g.ax0, g.ax1, g.ay0, g.ay1 = nx0, nx1, ny0, ny1
	g.moved = g.moved + moved
	g.steps = g.steps + 1
	return true
end

-- The time since the pool's last turn, in whole steps (at most maxSteps of them now; what is
-- left over waits, up to a few steps' worth: a pool that could not be stepped for a while does
-- not catch up in a burst). A pool at rest spends nothing.
-- With a clock (now: the game's time), the steps lie on a grid of that time (every STEP from
-- zero), whatever the frames are, and each lays down the inflow of its stretch first. onHalf:
-- called with the time after the step that ends on a half second (the pool's ageing).
function PS.Advance(g, dt, maxSteps, now, onHalf)
	local STEP = PS.STEP
	if now then
		if g.ax1 < g.ax0 and g.pourVol <= 0 then
			g.tS = nil
			return 0
		end
		local tS = g.tS
		-- (first step, or not stepped for a while: from the last grid line but a few)
		if not tS or now - tS > STEP * 6 then tS = (floor(now / STEP) - (tS and 5 or 1)) * STEP end
		local n = 0
		while tS + STEP <= now and n < maxSteps do
			tS = tS + STEP
			n = n + 1
			Inflow(g, tS)
			local live = PS.Step(g, STEP)
			if onHalf and floor(tS * 2 + 1e-6) ~= floor((tS - STEP) * 2 + 1e-6) then onHalf(tS) end
			if not live and g.pourVol <= 0 then break end
		end
		g.tS = tS
		return n
	end
	if g.ax1 < g.ax0 then g.acc = 0 return 0 end
	g.acc = min(g.acc + dt, STEP * 6)
	local n = 0
	while g.acc >= STEP and n < maxSteps do
		g.acc = g.acc - STEP
		n = n + 1
		if not PS.Step(g, STEP) then g.acc = 0 break end
	end
	return n
end

------------------------------------------------------------------------------------------
-- Time: soaking in, setting, drying
------------------------------------------------------------------------------------------
-- dt seconds have passed (now: the time at their end). evap: thickness that dries off a wet
-- cell per second. clotT: seconds out of the vessel until blood sets. Returns what dried and
-- what the surface took up (cubic units), and leaves the pool's sums in g: liq, gel, dep, soak
-- (cubic units), the range of wetness over the covered cells (wMin, wMax), the thickest cover
-- (tMax) and the count of covered cells (cov).
function PS.Age(g, now, dt, evap, clotT)
	g.liq, g.gel, g.dep, g.soak, g.wMin, g.wMax, g.tMax, g.cov = 0, 0, 0, 0, 1, 0, 0, 0
	if g.bx1 < g.bx0 then return 0, 0 end
	local n = g.n
	local h, k, s, ab, tb, td, zt, zf, cf, w = g.h, g.k, g.s, g.ab, g.tb, g.td, g.zt, g.zf, g.cf, g.w
	local abCap, abK = g.abCap, min(1, dt / g.abTau)
	local e0 = evap * dt
	local kEdge = g.kEdge * 0.125
	local blk = g.blk
	local gk = min(1, dt / GEL_TAU)
	local low = g.res * 0.25
	local dried, soaked, liq, gel, dep, soak = 0, 0, 0, 0, 0, 0
	local wMin, wMax, cov, tMax = 1, 0, 0, 0
	for j = g.by0, g.by1 do
		local c = j * n + g.bx0 + 1
		for _ = g.bx0, g.bx1 do
			if w[c] ~= 0 then
				local hh, kk = h[c], k[c]
				local T = hh + kk
				if T > 0 then
					-- the surface drinks
					local room = abCap - ab[c]
					if room > 1e-7 then
						local x = room * abK
						if x > T then x = T end
						local f = 1 - x / T
						hh, kk, T = hh * f, kk * f, T - x
						ab[c] = ab[c] + x
						soaked = soaked + x
					end
					-- blood that has been out of the vessel for the clotting time sets
					if hh > 0 then
						local cc = (now - tb[c]) / clotT
						if cc >= 1 then
							local x = hh * gk
							if hh - x < low then x = hh end
							hh, kk = hh - x, kk + x
							cf[c] = 1e4
						else
							cf[c] = ClotF(cc)
						end
					end
					-- and it dries from its surface: faster the more of the open cells around it hold
					-- no wet blood (the edge of the pool first, then inward as the edge moves in)
					local e = e0
					if kEdge > 0 then
						local nd = 0
						local q = c - 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c + 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c - n
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c + n
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c - n - 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c - n + 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c + n - 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						q = c + n + 1
						if (blk[q] or 0) == 0 and (h[q] or 0) + (k[q] or 0) <= 0 then nd = nd + 1 end
						e = e0 * (1 + kEdge * nd)
					end
					if e >= T then
						s[c] = s[c] + T
						dried = dried + T
						hh, kk, T = 0, 0, 0
						td[c] = now
					elseif e > 0 then
						local f = 1 - e / T
						s[c] = s[c] + e
						dried = dried + e
						hh, kk, T = hh * f, kk * f, T - e
					end
					h[c], k[c] = hh, kk
					zf[c] = zt[c] + kk + s[c] * DEPK
					liq, gel = liq + hh, gel + kk
					if T > 0 then td[c] = 0 end
				end
				local all = T + s[c] + ab[c]
				if all > 0 then
					cov = cov + 1
					local om = T / all
					if om < wMin then wMin = om end
					if om > wMax then wMax = om end
					if all > tMax then tMax = all end
					dep, soak = dep + s[c], soak + ab[c]
				end
			end
			c = c + 1
		end
	end
	local aa = g.a * g.a
	g.liq, g.gel, g.dep, g.soak = liq * aa, gel * aa, dep * aa, soak * aa
	g.wMin, g.wMax, g.tMax, g.cov = cov > 0 and wMin or 1, wMax, tMax, cov
	return dried * aa, soaked * aa
end

-- Dry the pool at once until the share `frac` of its blood (surface uptake apart) is still
-- wet, thin places first, as time would have done (developer / snapshots). since: how long ago
-- the dry places went dry. Returns what dried (cubic units).
function PS.DryTo(g, frac, now, since)
	if g.bx1 < g.bx0 then return 0 end
	local n = g.n
	local h, k, s, td, w, zf, zt = g.h, g.k, g.s, g.td, g.w, g.zf, g.zt
	local total, wet, tmax = 0, 0, 0
	for j = g.by0, g.by1 do
		local c = j * n + 1
		for i = g.bx0, g.bx1 do
			local T = h[c + i] + k[c + i]
			total, wet = total + T + s[c + i], wet + T
			if T > tmax then tmax = T end
		end
	end
	local want = frac * total
	local e = 0
	if wet > want then
		-- the depth of drying that leaves `want`: bisection
		local lo, hi = 0, tmax
		for _ = 1, 24 do
			e = (lo + hi) * 0.5
			local left = 0
			for j = g.by0, g.by1 do
				local c = j * n + 1
				for i = g.bx0, g.bx1 do
					local T = h[c + i] + k[c + i]
					if T > e then left = left + T - e end
				end
			end
			if left > want then lo = e else hi = e end
		end
		e = hi
	end
	local dried = 0
	local tdry = now - (since or 0)
	for j = g.by0, g.by1 do
		local c = j * n + g.bx0 + 1
		for _ = g.bx0, g.bx1 do
			if w[c] ~= 0 then
				local T = h[c] + k[c]
				if T > 0 and e > 0 then
					if e >= T then
						s[c], dried = s[c] + T, dried + T
						h[c], k[c] = 0, 0
						td[c] = tdry
					else
						local f = 1 - e / T
						s[c], dried = s[c] + e, dried + e
						h[c], k[c] = h[c] * f, k[c] * f
					end
					zf[c] = zt[c] + k[c] + s[c] * DEPK
				elseif T <= 0 and since then
					td[c] = tdry
				end
			end
			c = c + 1
		end
	end
	return dried * g.a * g.a
end

------------------------------------------------------------------------------------------
-- The ground under the lattice
------------------------------------------------------------------------------------------
-- (U0, V0): the pool's origin on the plane's axes (the pinning is fixed in the world).
-- (tu, tv): the fall of the surface per unit along u and v. rl / rcv: traced floor relief on the
-- (rcv.G + 1)^2 grid of the canvas rcv (cl_pools.lua), or nil.
function PS.SetGround(g, U0, V0, tu, tv, rl, rcv)
	local n, a = g.n, g.a
	-- (the floor is laid anew: no cell carries a body's step until PS.SetBody gives it one again)
	g.stepOn = nil
	local zt, zf, hc, k, s = g.zt, g.zf, g.hc, g.k, g.s
	local film, amp = g.film, g.amp
	local rG, ru0, rv0, rk
	if rl and rcv then
		rG = rcv.G
		ru0, rv0, rk = rcv.cu - rcv.H, rcv.cv - rcv.H, rG / (2 * rcv.H)
	end
	local Pin, Relief = PS.Pin, PS.Relief
	-- (phase 22: the floor's own unevenness, C.P22.relief: cl_pools.lua sets g.micro)
	local mic, mr = g.micro or 0, g.mr
	for j = 0, n - 1 do
		local v = (g.j0 + j + 0.5) * a
		local c = j * n + 1
		for i = 0, n - 1 do
			local u = (g.i0 + i + 0.5) * a
			if hc[c] < 0 then hc[c] = film * (1 + amp * Pin(U0 + u, V0 + v)) end
			local z = 0
			if mic > 0 then
				local r = mr[c]
				if r == -99 then
					r = Relief(U0 + u, V0 + v, a)
					mr[c] = r
				end
				z = mic * r
			end
			if rG then
				local fx, fy = (u - ru0) * rk, (v - rv0) * rk
				if fx < 0 then fx = 0 elseif fx > rG then fx = rG end
				if fy < 0 then fy = 0 elseif fy > rG then fy = rG end
				local ii, jj = floor(fx), floor(fy)
				if ii > rG - 1 then ii = rG - 1 end
				if jj > rG - 1 then jj = rG - 1 end
				local tx, ty = fx - ii, fy - jj
				local q = jj * (rG + 1) + ii + 1
				local z00, z10, z01, z11 = rl[q] or 0, rl[q + 1] or 0, rl[q + rG + 1] or 0, rl[q + rG + 2] or 0
				z = z + z00 + (z10 - z00) * tx + (z01 - z00) * ty + (z00 - z10 - z01 + z11) * tx * ty
			end
			z = z - (u * tu + v * tv)
			zt[c] = z
			zf[c] = z + k[c] + s[c] * DEPK
			c = c + 1
		end
	end
	PS.WakeAll(g)
end

-- Walls, ledges and the start of a stream: the cells beyond a clip's line (cl_pools.lua: a
-- point (u, v) on the line and the direction (mu, mv) across it) are closed (a wall), have no
-- floor (a ledge: clip.ledge) or hand the blood to a stream (clip.exit). Liquid that got behind
-- a wall before it was found goes back to the nearest open cell on this side; liquid found past
-- an edge has crossed it. Returns what was shut in with nowhere to go (cubic units).
function PS.SetClips(g, clips, extra)
	local n, a = g.n, g.a
	local blk, bq, h, k, s, ab, w = g.blk, g.bq, g.h, g.k, g.s, g.ab, g.w
	local nc = #clips
	-- (the open cells change: what was found nearest goes; a body's cells are laid again after this,
	-- PS.SetBody)
	if g.nfMemo then g.nfMemo = {} end
	local back
	local aa = a * a
	local out = g.out
	local floorOK = g.floor
	-- (what has crossed an edge keeps its cell only while that cell is still that edge)
	for c, x in pairs(out) do
		out[c] = nil
		g.outVol = g.outVol - x
		g.outLoose = g.outLoose + x
	end
	g.outVol = 0
	for j = 0, n - 1 do
		local v = (g.j0 + j + 0.5) * a
		local c = j * n + 1
		for i = 0, n - 1 do
			local u = (g.i0 + i + 0.5) * a
			local b, bi = 0, 0
			for q = 1, nc + (extra and 1 or 0) do
				local cl = clips[q] or extra
				if (u - cl.u) * cl.mu + (v - cl.v) * cl.mv > 0 then
					local kind = cl.ledge and 2 or (cl.exit and 3 or 1)
					-- (a cell that was found to have floor is no ledge, whatever the line says)
					if kind == 2 and floorOK[(g.i0 + i) * 65536 + g.j0 + j] then kind = 0 end
					-- (a wall counts before an edge)
					if kind ~= 0 and (b == 0 or kind == 1) then b, bi = kind, q end
					if kind == 1 then break end
				end
			end
			if b ~= 0 and w[c] ~= 0 then
				local T = h[c] + k[c]
				if T > 0 then
					if b == 1 then
						back = back or {}
						back[#back + 1] = { i, j, h[c], k[c], g.tb[c] }
					else
						out[c] = (out[c] or 0) + T * aa
						g.outVol = g.outVol + T * aa
					end
				end
				h[c], k[c], s[c], ab[c], w[c] = 0, 0, 0, 0, 0
				g.wetN = g.wetN - 1
				g.ver = g.ver + 1
			end
			blk[c], bq[c] = b, bi
			c = c + 1
		end
	end
	local lost = 0
	if back then
		for q = 1, #back do
			local e = back[q]
			local ii, jj = NearestFree(g, e[1], e[2])
			if ii then
				Put(g, ii, jj, e[3] + e[4], e[5])
			else
				lost = lost + e[3] + e[4]
			end
		end
	end
	PS.WakeAll(g)
	return lost * aa
end

------------------------------------------------------------------------------------------
-- The lattice window
------------------------------------------------------------------------------------------
local COPY = { "h", "k", "s", "ab", "tb", "td", "sh", "hc", "mu", "cf", "mr" }

-- What has crossed an edge loses its cell when the lattice changes (it is still handed on).
local function LooseOut(g)
	for c, x in pairs(g.out) do
		g.out[c] = nil
		g.outLoose = g.outLoose + x
	end
	g.outVol = 0
end

-- The same lattice, another window of it: n2 cells a side from lattice cell (i02, j02).
function PS.Reshape(g, n2, i02, j02)
	local n = g.n
	local di, dj = i02 - g.i0, j02 - g.j0
	local old = {}
	for q = 1, #COPY do old[q] = g[COPY[q]] end
	local oh, ok, ow, otb = g.h, g.k, g.w, g.tb
	local had = g.bx1 >= g.bx0
	local a = g.a
	local oi0, oj0 = g.i0, g.j0
	LooseOut(g)
	-- (no cell is under a body in the new window until the body is laid on it again: cl_pools.lua)
	g.nfMemo, g.reach, g.bodyN, g.stepOn = nil, nil, 0, nil
	Arrays(g, n2)
	g.n, g.i0, g.j0 = n2, i02, j02
	g.bx0, g.bx1, g.by0, g.by1 = n2, -1, n2, -1
	g.ax0, g.ax1, g.ay0, g.ay1 = n2, -1, n2, -1
	g.wetN = 0
	local new = {}
	for q = 1, #COPY do new[q] = g[COPY[q]] end
	local out
	for j = 0, n - 1 do
		local J = j - dj
		for i = 0, n - 1 do
			local c = j * n + i + 1
			local I = i - di
			if I >= 0 and I < n2 and J >= 0 and J < n2 then
				local q = J * n2 + I + 1
				for f = 1, #COPY do new[f][q] = old[f][c] end
				if ow[c] ~= 0 then Wet(g, q, I, J) end
			elseif oh[c] + ok[c] > 0 then
				-- (wet blood outside the new window: the caller keeps it inside, this is the net under it)
				out = out or {}
				out[#out + 1] = { (oi0 + i + 0.5) * a, (oj0 + j + 0.5) * a, (oh[c] + ok[c]) * a * a, otb[c] }
			end
		end
	end
	if out then
		for q = 1, #out do
			g.outLoose = g.outLoose + PS.Splat(g, out[q][1], out[q][2], out[q][3], out[q][4])
		end
	end
	if had then PS.WakeAll(g) end
	g.ver = g.ver + 1
end

-- One cell of every 2 x 2: twice the cell size, the same blood.
function PS.Coarsen(g)
	local n = g.n
	local oh, ok, os, oab, otb, otd, ow, osh = g.h, g.k, g.s, g.ab, g.tb, g.td, g.w, g.sh
	local oi0, oj0 = g.i0, g.j0
	local i0c, j0c = floor(oi0 / 2), floor(oj0 / 2)
	local nc = max(floor((oi0 + n - 1) / 2) - i0c, floor((oj0 + n - 1) / 2) - j0c) + 1
	LooseOut(g)
	g.nfMemo, g.reach, g.bodyN, g.stepOn = nil, nil, 0, nil
	Arrays(g, nc)
	g.floor = {}
	g.a, g.n, g.i0, g.j0 = g.a * 2, nc, i0c, j0c
	g.bx0, g.bx1, g.by0, g.by1 = nc, -1, nc, -1
	g.ax0, g.ax1, g.ay0, g.ay1 = nc, -1, nc, -1
	g.wetN = 0
	local h, k, s, ab, tb, td, sh, mu = g.h, g.k, g.s, g.ab, g.tb, g.td, g.sh, g.mu
	for j = 0, n - 1 do
		local J = floor((oj0 + j) / 2) - j0c
		for i = 0, n - 1 do
			local c = j * n + i + 1
			if ow[c] ~= 0 then
				local I = floor((oi0 + i) / 2) - i0c
				local q = J * nc + I + 1
				local x = oh[c] * 0.25
				if x > 0 then
					tb[q] = (tb[q] * h[q] + otb[c] * x) / (h[q] + x)
					h[q] = h[q] + x
				end
				k[q], s[q], ab[q] = k[q] + ok[c] * 0.25, s[q] + os[c] * 0.25, ab[q] + oab[c] * 0.25
				if otd[c] ~= 0 and (td[q] == 0 or otd[c] > td[q]) then td[q] = otd[c] end
				if osh[c] > sh[q] then sh[q] = osh[c] end
				if g.w[q] == 0 then Wet(g, q, I, J) end
			end
		end
	end
	for q = 1, nc * nc do
		local x = sh[q]
		if x > 0 then mu[q] = 1 + 15.23 * (1 + 10.976 * x * x) ^ -0.3216 end
		if h[q] + k[q] > 0 then td[q] = 0 end
	end
	PS.WakeAll(g)
	g.ver = g.ver + 1
end

-- Would everything that has been wet, and the rectangle u0..v1 of the pool's frame, fit into
-- the largest lattice (nMax cells a side at the coarsest cell)?
function PS.CanFit(g, nMax, u0, v0, u1, v1)
	local a = g.a
	if g.bx1 >= g.bx0 then
		u0, u1 = min(u0, (g.i0 + g.bx0) * a), max(u1, (g.i0 + g.bx1 + 1) * a)
		v0, v1 = min(v0, (g.j0 + g.by0) * a), max(v1, (g.j0 + g.by1 + 1) * a)
	end
	return max(u1 - u0, v1 - v0) < (nMax - 8) * PS.A_MAX
end

-- Would PS.Fit go over to coarser cells now (the same test as below, for what has been wet, and the
-- rectangle u0..v1 of the pool's frame, if given)?
function PS.FitCoarsens(g, nMax, u0, v0, u1, v1)
	local x0, x1, y0, y1 = g.bx0, g.bx1, g.by0, g.by1
	if u0 then
		local a = g.a
		x0, x1 = min(x0, floor(u0 / a) - g.i0), max(x1, floor(u1 / a) - g.i0)
		y0, y1 = min(y0, floor(v0 / a) - g.j0), max(y1, floor(v1 / a) - g.j0)
	end
	if x1 < x0 or y1 < y0 then return false end
	local n = g.n
	if x0 >= 2 and y0 >= 2 and x1 <= n - 3 and y1 <= n - 3 then return false end
	local span = max(x1 - x0, y1 - y0) + 1
	local want = span + 2 * max(3, ceil(span * 0.15))
	want = want + want % 2
	return want > nMax and g.a < PS.A_MAX
end

-- Keep everything that has been wet (and the rectangle u0..v1 of the pool's frame, if given)
-- inside the window with room to spread into: more cells while the lattice may grow (nMax a
-- side), coarser cells beyond that. Returns true when the lattice changed (the ground under it
-- has to be set again).
function PS.Fit(g, nMax, u0, v0, u1, v1)
	local x0, x1, y0, y1 = g.bx0, g.bx1, g.by0, g.by1
	if u0 then
		local a = g.a
		x0, x1 = min(x0, floor(u0 / a) - g.i0), max(x1, floor(u1 / a) - g.i0)
		y0, y1 = min(y0, floor(v0 / a) - g.j0), max(y1, floor(v1 / a) - g.j0)
	end
	if x1 < x0 or y1 < y0 then return false end
	local n = g.n
	if x0 >= 2 and y0 >= 2 and x1 <= n - 3 and y1 <= n - 3 then return false end
	-- (in lattice cells from here on: they survive a coarsening)
	local X0, X1, Y0, Y1 = g.i0 + x0, g.i0 + x1, g.j0 + y0, g.j0 + y1
	while true do
		local span = max(X1 - X0, Y1 - Y0) + 1
		local want = span + 2 * max(3, ceil(span * 0.15))
		want = want + want % 2
		if want <= nMax or g.a >= PS.A_MAX then
			want = min(max(want, 12), nMax)
			PS.Reshape(g, want, X0 - floor((want - (X1 - X0 + 1)) / 2), Y0 - floor((want - (Y1 - Y0 + 1)) / 2))
			return true
		end
		PS.Coarsen(g)
		X0, X1, Y0, Y1 = floor(X0 / 2), floor(X1 / 2), floor(Y0 / 2), floor(Y1 / 2)
	end
end

------------------------------------------------------------------------------------------
-- Where the pool is
------------------------------------------------------------------------------------------
-- Is (u, v) on a cell that holds blood worth the name (a tenth of a film, in any state), or
-- within margin of one (the cell's own reach counted)?
function PS.Covers(g, u, v, margin)
	local a, n = g.a, g.n
	local i, j = floor(u / a) - g.i0, floor(v / a) - g.j0
	local r = margin > 0 and ceil(margin / a) or 0
	-- (blood that is on its way in counts where it will land)
	local pour = g.pour
	if pour[1] then
		local lm = (margin + a) ^ 2
		for q = 1, #pour do
			local it = pour[q]
			if (it.u - u) ^ 2 + (it.v - v) ^ 2 < lm then return true end
		end
	end
	local bx0, bx1 = g.bx0, g.bx1
	if i + r < bx0 or i - r > bx1 or j + r < g.by0 or j - r > g.by1 then return false end
	local h, k, s, ab = g.h, g.k, g.s, g.ab
	local sub = g.film * 0.1
	local lim = r > 0 and (margin + a * 0.71) ^ 2 or math.huge
	local ia, ib = max(i - r, bx0), min(i + r, bx1)
	for jj = max(j - r, g.by0), min(j + r, g.by1) do
		local c = jj * n + 1
		local dv = (g.j0 + jj + 0.5) * a - v
		for ii = ia, ib do
			local q = c + ii
			if h[q] + k[q] + s[q] + ab[q] > sub then
				local du = (g.i0 + ii + 0.5) * a - u
				if du * du + dv * dv < lim then return true end
			end
		end
	end
	return false
end

-- (phase 21) Does the pool's picture show its layer at (u, v)? Its outline follows the potential of
-- the cells smoothed over a cell either way (cl_poolcanvas.lua, Taps), and a lone wet cell, or one
-- that is wet only as a trace, stays under it. Taken as: the cell holds wet blood half a film deep at
-- least, and three of its four sides hold blood too.
function PS.Shown(g, u, v)
	local a, n = g.a, g.n
	local i, j = floor(u / a) - g.i0, floor(v / a) - g.j0
	if i < 1 or j < 1 or i > n - 2 or j > n - 2 then return false end
	local c = j * n + i + 1
	local h, k = g.h, g.k
	local film = g.film
	if h[c] + k[c] < film * 0.5 then return false end
	local lim, s = film * 0.2, 0
	if h[c - 1] + k[c - 1] >= lim then s = s + 1 end
	if h[c + 1] + k[c + 1] >= lim then s = s + 1 end
	if h[c - n] + k[c - n] >= lim then s = s + 1 end
	if h[c + n] + k[c + n] >= lim then s = s + 1 end
	return s >= 3
end

-- The outermost wet cell of every row and every column (their centres, pool frame): what any
-- question about the pool's reach needs. Rebuilt when the set of wet cells has changed.
function PS.Hull(g)
	if g.hullVer == g.ver then return g.hu, g.hv, g.hn end
	local hu, hv, cnt = g.hu or {}, g.hv or {}, 0
	local n, a, w = g.n, g.a, g.w
	local bx0, bx1, by0, by1 = g.bx0, g.bx1, g.by0, g.by1
	for j = by0, by1 do
		local c = j * n + 1
		local v = (g.j0 + j + 0.5) * a
		for i = bx0, bx1 do
			if w[c + i] ~= 0 then cnt = cnt + 1 hu[cnt], hv[cnt] = (g.i0 + i + 0.5) * a, v break end
		end
		for i = bx1, bx0, -1 do
			if w[c + i] ~= 0 then cnt = cnt + 1 hu[cnt], hv[cnt] = (g.i0 + i + 0.5) * a, v break end
		end
	end
	for i = bx0, bx1 do
		local u = (g.i0 + i + 0.5) * a
		for j = by0, by1 do
			if w[j * n + i + 1] ~= 0 then cnt = cnt + 1 hu[cnt], hv[cnt] = u, (g.j0 + j + 0.5) * a break end
		end
		for j = by1, by0, -1 do
			if w[j * n + i + 1] ~= 0 then cnt = cnt + 1 hu[cnt], hv[cnt] = u, (g.j0 + j + 0.5) * a break end
		end
	end
	g.hu, g.hv, g.hn, g.hullVer = hu, hv, cnt, g.ver
	return hu, hv, cnt
end

-- How far the pool reaches from its origin in direction (du, dv).
function PS.Extent(g, du, dv)
	local hu, hv, cnt = PS.Hull(g)
	if cnt == 0 then return 0 end
	local e = -math.huge
	for q = 1, cnt do
		local x = hu[q] * du + hv[q] * dv
		if x > e then e = x end
	end
	return max(e + g.a * 0.5, 0)
end

------------------------------------------------------------------------------------------
-- A pool that has spread already (a snapshot of an old one, the gallery): vol (cubic units)
-- laid out one film thick around the origin, the cells taken in the order the contact line
-- would reach them (nearer first, held back where the surface pins). The lattice must have room.
------------------------------------------------------------------------------------------
function PS.Presettle(g, vol, U0, V0, t)
	local n, a = g.n, g.a
	local want = max(1, floor(vol / (g.film * a * a) + 0.5))
	local keys, idx = {}, {}
	local cnt = 0
	local blk = g.blk
	for j = 0, n - 1 do
		local v = (g.j0 + j + 0.5) * a
		for i = 0, n - 1 do
			local c = j * n + i + 1
			if blk[c] == 0 then
				local u = (g.i0 + i + 0.5) * a
				local nz = 0.5 * (Noise((U0 + u) * 0.23 + 7.1, (V0 + v) * 0.23 + 3.3) + Noise((U0 + u) * 0.62, (V0 + v) * 0.62))
				cnt = cnt + 1
				idx[cnt] = c
				keys[c] = sqrt(u * u + v * v) / (0.75 + 0.5 * nz)
			end
		end
	end
	table.sort(idx, function(p, q) return keys[p] < keys[q] end)
	if want > cnt then want = cnt end
	if want < 1 then return end
	local hh = vol / (want * a * a)
	for q = 1, want do
		local c = idx[q]
		Put(g, (c - 1) % n, floor((c - 1) / n), hh, t)
	end
	PS.WakeAll(g)
end

------------------------------------------------------------------------------------------
-- Figures for the developer overlay: the mean and the greatest layer, speed and age of what
-- is still liquid (units, units/s, s), and the cells in each state.
------------------------------------------------------------------------------------------
function PS.Stats(g, now)
	local r = { hMean = 0, hMax = 0, uMean = 0, uMax = 0, age = 0, liquid = 0, set = 0, dry = 0, soaked = 0 }
	if g.bx1 < g.bx0 then return r end
	local n = g.n
	local h, k, s, ab, sh, tb, w = g.h, g.k, g.s, g.ab, g.sh, g.tb, g.w
	local hs, us, as, cnt = 0, 0, 0, 0
	for j = g.by0, g.by1 do
		local c = j * n + g.bx0 + 1
		for _ = g.bx0, g.bx1 do
			if w[c] ~= 0 then
				local hh = h[c]
				if hh > 0 then
					local u = sh[c] * hh / 3
					hs, us, as, cnt = hs + hh, us + u * hh, as + (now - tb[c]) * hh, cnt + 1
					if hh > r.hMax then r.hMax = hh end
					if u > r.uMax then r.uMax = u end
					r.liquid = r.liquid + 1
				elseif k[c] > 0 then
					r.set = r.set + 1
				elseif s[c] > 0 then
					r.dry = r.dry + 1
				elseif ab[c] > 0 then
					r.soaked = r.soaked + 1
				end
			end
			c = c + 1
		end
	end
	if cnt > 0 then r.hMean, r.uMean, r.age = hs / cnt, us / hs, as / hs end
	return r
end

-- The cells under a body that lies on the floor (cl_pools.lua, BodyMask): mask[c] true for each.
-- Nothing arrives in such a cell (PS.BODY): what lands there goes to the nearest open cell, as far
-- off as the body reaches (g.reach), at the body's edge. The liquid itself may go under the body,
-- but only where it stands deeper beside it than step (units): the floor of such a cell is taken to
-- be that much higher. A body lying in its blood seals the floor where it rests on it, and a puddle
-- that fills a pocket between an arm and the trunk seeps on under the arm once it is deep enough.
-- (As a wall, the cells under the body held a pool in such a pocket for good: it went on getting
-- deeper, to 12 mm, and covered no more floor for two minutes of bleeding: run p18e, scene
-- acc_long.) Wet blood that stood in a cell the body has come to cover (the body settled, the
-- lattice grew under it) is pushed out to the nearest open cell, as blood behind a wall is
-- (PS.SetClips): the body displaces it. What has dried or soaked in there stays. A cell the body has
-- left is open again. Returns how many cells are under a body.
function PS.SetBody(g, mask, reach, step)
	local blk, n, h, k, tb, zt, zf = g.blk, g.n, g.h, g.k, g.tb, g.zt, g.zf
	step = step or 0
	-- (the step each cell's floor carries now: PS.SetGround lays the floor anew without it)
	local on = g.stepOn
	if not on then on = {} g.stepOn = on end
	local cnt = 0
	local push
	for c = 1, n * n do
		local b = blk[c]
		if mask and mask[c] then
			if b == 0 then
				blk[c] = 4
				b = 4
				local T = h[c] + k[c]
				if T > 0 then
					push = push or {}
					push[#push + 1] = { (c - 1) % n, floor((c - 1) / n), T, tb[c] }
					h[c], k[c] = 0, 0
				end
			end
			if b == 4 then
				cnt = cnt + 1
				local was = on[c] or 0
				if was ~= step then
					zt[c], zf[c] = zt[c] + step - was, zf[c] + step - was
					on[c] = step
				end
			end
		elseif b == 4 then
			blk[c] = 0
		end
		-- (a cell that is under no body any more has its own floor again)
		if blk[c] ~= 4 and on[c] then
			zt[c], zf[c] = zt[c] - on[c], zf[c] - on[c]
			on[c] = nil
		end
	end
	g.bodyN = cnt
	if cnt > 0 then
		g.nfMemo, g.reach = {}, reach or 40
	else
		g.nfMemo, g.reach = nil, nil
	end
	local kept = 0
	if push then
		for q = 1, #push do
			local e = push[q]
			local ii, jj = NearestFree(g, e[1], e[2])
			if ii then
				Put(g, ii, jj, e[3], e[4])
			else
				-- (nowhere to go: it stays where it was, under the body)
				local c = e[2] * n + e[1] + 1
				h[c] = h[c] + e[3]
				kept = kept + 1
			end
		end
		g.pushed = (g.pushed or 0) + #push - kept
	end
	PS.WakeAll(g)
	g.ver = g.ver + 1
	return cnt
end

-- A cell past a ledge's line has been looked under. floor: there is floor (the cell is opened
-- again, and what had crossed into it is back on it) or there is none (it stays an edge).
function PS.Looked(g, c, floor, t)
	local n = g.n
	local i, j = (c - 1) % n, math.floor((c - 1) / n)
	g.floor[(g.i0 + i) * 65536 + g.j0 + j] = floor
	if not floor then return end
	local x = g.out[c]
	g.out[c] = nil
	g.blk[c], g.bq[c] = 0, 0
	if g.nfMemo then g.nfMemo = {} end
	if x and x > 0 then
		g.outVol = g.outVol - x
		Put(g, i, j, x / (g.a * g.a), t)
	end
	Wake(g, i - 1, j - 1, i + 1, j + 1)
end

-- Set, dried and absorbed blood (cubic units), and liquid hv that left the vessel at tb, onto
-- the cell (u, v) lies in, or the open cell nearest to it: what a pool that joins this one
-- brings along, cell for cell. td: when it went dry. Returns the wet blood that found no cell,
-- and the cell.
function PS.AddAt(g, u, v, kv, sv, abv, td, hv, tb)
	local a, n = g.a, g.n
	local i, j = floor(u / a) - g.i0, floor(v / a) - g.j0
	i, j = min(max(i, 0), n - 1), min(max(j, 0), n - 1)
	if g.blk[j * n + i + 1] ~= 0 then
		i, j = NearestFree(g, i, j)
		if not i then return kv + (hv or 0) end
	end
	local c = j * n + i + 1
	local aa = a * a
	if hv and hv > 0 then
		Put(g, i, j, hv / aa, tb)
		Wake(g, i - 1, j - 1, i + 1, j + 1)
	elseif g.w[c] == 0 then
		Wet(g, c, i, j)
	end
	g.k[c], g.s[c], g.ab[c] = g.k[c] + kv / aa, g.s[c] + sv / aa, g.ab[c] + abv / aa
	if g.h[c] + g.k[c] <= 0 and td ~= 0 and (g.td[c] == 0 or td > g.td[c]) then g.td[c] = td end
	g.zf[c] = g.zt[c] + g.k[c] + g.s[c] * DEPK
	return 0, c
end
