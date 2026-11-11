-- Blood film: blood on a body as a layer that covers its surface.
--
-- The flow core (cl_flowcore.lua) follows a stream along the one path it took: a row of nodes with a
-- width. Whatever is done to that width, what is drawn of it is a line from the wound. Here blood
-- is where it lies. Every cell of the body's surface (cl_filmchart.lua: a grid in each material's
-- texture space, cells of about 7 mm) holds what is on it, as a thickness:
--   h    liquid that can still run           k    blood that has set (a gel: wet, but it stays)
--   sd   blood that has dried there          ab   blood the cloth has taken up
-- and the film is what those add up to, cell by cell: a wet patch at the wound, a run below it that
-- is narrow where it falls freely and full where it is held up, a bead at its tip, a sheet where
-- much comes, a stain where it soaked in or dried. No shape is drawn; every shape is the state. It is the liquid of the ground pools (cl_poolsim.lua) on another surface and moves by the
-- same law:
--   * Liquid crosses the face between two cells from the higher free surface to the lower one, by
--     the flow core's law for a thin layer (mean speed kFlow x slope x h^2 / mu) with blood's shear
--     thinning and clotting. The height of a cell is where its place on the body is in the world
--     right now, against the world's gravity: read from the pose at every step, so the film runs
--     down whatever is down for that part of that body at that moment. Nothing says "below the
--     wound".
--   * The contact line: liquid enters a dry cell only when the head over it is more than what the
--     surface there holds back (a pinning value fixed to the body, so the outline follows the body
--     and not the grid; more at the tip of a finger than in a bay; far less where it has been wet
--     before), and a cell never drains below a residual film. A large flow therefore spreads into a
--     sheet, a small one stays a rivulet, and both leave what they wetted behind them.
--   * Cloth drinks from the layer standing on it until it is full (little: a wound's blood runs
--     over cloth far more than it stays in it), and blood creeps on from there to drier cloth
--     beside it, a few cells at the most and unevenly as cloth is uneven: the soaked margin of a
--     run, wide here and narrow there. Bare skin drinks nothing, but its furrows hold a little:
--     the margin of blood on skin is narrow, and stays as a stain.
--   * What is too much for a place leaves the body there: what hangs under a place that faces
--     down, what reaches an edge of the mesh with nothing across it (a cuff, the rim of what can be
--     painted), part of what crosses a gap between two pieces of clothing (a hem over trousers),
--     more than stands on a steep place, and part of what is on a bone that takes a blow (FM.Shake).
--     It leaves as drops that start where it left, with the velocity of that place, or straight
--     into the pool under a body that lies in it (ABL.Flow.GroundSeep). That is the only way blood
--     gets from a body to the ground: what lies on the ground is what fell there.
--   * Time: liquid older than the clotting time sets, every wet cell dries from its surface (the
--     thin margin first), and what has dried or soaked in stays where it is.
-- Cells are made where blood first comes (a body has tens of thousands, a film a few hundred to a
-- few thousand), and only cells that hold liquid above their residual film are stepped. Faces
-- across a texture seam or a gap between two pieces of clothing are faces like any other.
-- A cell is asked to be painted again (Touch: cl_filmdraw.lua paints it) when what is shown of it
-- has changed: at once when blood first comes to it or the last of it dries, now and then while it
-- only runs, soaks or dries on.
--
-- This is the flow of a thin layer under gravity with a contact line, on a grid a few
-- millimetres wide and with no inertia: an approximation that conserves what it is given, not a
-- solution of the fluid's equations. The books of all blood are the flow core's (FC.Books).

ABL.NoJIT()
ABL.Film = ABL.Film or {}
local FM = ABL.Film
local C, L, BM, CH = ABL.Config, ABL.LOD, ABL.BodyMesh, ABL.FilmChart
local K, KF = C.Film, C.Flow
local ML = C.ML_PER_CU
local FC = ABL.FlowCore
local ClotF = FC.ClotF
local MU0 = FC.ShearF(0)
local sqrt, min, max, floor, exp = math.sqrt, math.min, math.max, math.floor, math.exp
local F, Drops, WS, Pin      -- (modules loaded after this one: looked up at first use)

FM.cv = CreateClientConVar("abl_body_film", "1", true, false, "Blood on bodies as a film that covers their surface (1), or as the streams of the flow core (0).", 0, 1)
FM.cvCells = CreateClientConVar("abl_max_film_cells", "40000", true, false, "Hard cap: cells of blood film on bodies (all characters).", 2000, 400000)
FM.cells = FM.cells or 0
-- profiling accumulators (ms / counts since the last reset; read by the test harness)
FM.prof = FM.prof or { step = 0, steps = 0, looked = 0, moved = 0, age = 0, aged = 0, left = 0 }
local prof = FM.prof

local DEPK = 0.5         -- how much of its liquid thickness dried blood still stands (the floor for later blood)
local SH_REST = 0.02     -- 1/s: below this shear memory a cell counts as at rest
local GEL_TAU = 4        -- s over which liquid past its clotting time sets
local QEPS = 1e-7        -- units: less than this does not cross a face

------------------------------------------------------------------------------------------
-- Which bodies have a film
------------------------------------------------------------------------------------------
-- Film or flow core for this character? True also while its surface model or its chart is not there
-- yet (nothing is laid on the body until then). A body most of whose surface cannot be painted
-- stays with the flow core.
function FM.Uses(src)
	if not FM.cv:GetBool() then return false end
	local key = src.key
	-- (one character kept on the older models, for comparing them side by side: abl_dev_compare)
	if IsValid(key) and (key.ablFlowLegacy or key.ablNoFilm) then return false end
	local m = src.mesh
	if not m then return true end
	local ch = m.chart
	if not ch then
		CH.Get(m)
		return true
	end
	if ch.failed then return false end
	if ch.ready then return ch.ok end
	return true
end

------------------------------------------------------------------------------------------
-- State of one body
------------------------------------------------------------------------------------------
local NAMES = { "mk", "ci", "tt", "bu", "bv", "nb1", "nb2", "nb3", "nb4", "h", "k", "sd", "ab", "tb", "td", "w", "fed",
	"zt", "zf", "nz", "hs", "hc", "rs", "rl", "wk", "abc", "mt", "wi", "sk", "pt", "ar", "mu", "sh", "gn", "cf", "on", "idle", "mv", "dq",
	"lw", "wg", "ws", "gp", "wr", "fx", "fy", "dx", "dy", "sp", "ds", "rn", "opn", "bg", "wp", "lp", "lt", "wo" }

-- Value noise in space (0 .. 1), for what is fixed to a place of the body whatever texture it lies in.
local sin = math.sin
local function Hash3(ix, iy, iz)
	local s = sin(ix * 127.1 + iy * 311.7 + iz * 74.7) * 43758.5453
	return s - floor(s)
end
local function Noise3(x, y, z)
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local fx, fy, fz = x - ix, y - iy, z - iz
	fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
	local a = Hash3(ix, iy, iz)
	local b = Hash3(ix + 1, iy, iz)
	local c = Hash3(ix, iy + 1, iz)
	local d = Hash3(ix + 1, iy + 1, iz)
	local e = Hash3(ix, iy, iz + 1)
	local f = Hash3(ix + 1, iy, iz + 1)
	local g = Hash3(ix, iy + 1, iz + 1)
	local h = Hash3(ix + 1, iy + 1, iz + 1)
	local lo = a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
	local hi = e + (f - e) * fx + (g - e) * fy + (e - f - g + h) * fx * fy
	return lo + (hi - lo) * fz
end

local function State(src, ch)
	local s = src.film
	if s and s.ch == ch then return s end
	if s then FM.FreeSource(src) end
	-- Where the body's unevenness begins: two bodies of one model do not bleed alike. By the
	-- character's number in the game, which is the same for everybody who sees it: no two players'
	-- games lay the same wound's blood over different folds.
	local key = src.key
	local id = IsValid(key) and key:EntIndex() or src.seed
	s = { src = src, ch = ch, m = ch.m, n = 0, lut = {}, act = {}, na = 0, out = {}, outT = {}, feeds = {},
		queue = {}, qn = 0, uq = {}, un = 0, inq = {}, wetN = 0, stamp = 1, rot = 0, stepNo = 0, agePos = 1, ageRound = 0, now = CurTime(),
		tha = {}, thb = {}, thc = {}, thn = {}, ths = {}, wacc = {},
		ux = 0, uy = 0, uz = 1,
		pu = (id % 977) * 0.37, pv = (id % 613) * 0.53,
		-- this body's own books (ml): what was fed onto it, what is still wet on it, what its cloth
		-- took up, what dried on it, and what left it again
		bk = { fed = 0, surface = 0, absorbed = 0, dried = 0, left = 0 } }
	for i = 1, #NAMES do s[NAMES[i]] = {} end
	for k = 1, #ch.mats do s.lut[k] = {} end
	src.film = s
	return s
end

-- Wet blood a body's film holds (liquid and gel, and what has left its cells but not yet the body), ml.
function FM.Held(s)
	local t = 0
	local h, k, ar = s.h, s.k, s.ar
	for c = 1, s.n do t = t + (h[c] + k[c]) * ar[c] end
	t = t * ML
	for _, v in pairs(s.out) do t = t + v end
	return t
end

function FM.Active(src)
	local s = src.film
	return s ~= nil and (s.wetN > 0 or #s.feeds > 0)
end

-- What a wound has given since the last step and that is not on the body yet: it is on its way
-- there all the same. Booked when the film goes before its next step, so that what the wounds
-- released and what the books hold stay the same amount.
local function TakeFeeds(s)
	local t = 0
	for i = 1, #s.feeds do
		local wd = s.feeds[i]
		t = t + (wd.fin or 0)
		wd.fin, wd.fq = nil, nil
	end
	s.feeds = {}
	if t > 0 then
		FC.Release("surface", t)
		s.bk.fed, s.bk.surface = s.bk.fed + t, s.bk.surface + t
		WS = WS or ABL.Wounds
		if WS and IsValid(s.src.key) then WS.Ledger(s.src, "onBody", t) end
	end
	return t
end

function FM.FreeSource(src)
	local s = src.film
	if not s then return end
	-- (blood still wet in a film that is being dropped is written off)
	local t = TakeFeeds(s) + FM.Held(s)
	if t > 0 then
		FC.Move("surface", "lost", t)
		s.bk.surface = s.bk.surface - t
	end
	FM.cells = FM.cells - s.n
	if ABL.FilmDraw then ABL.FilmDraw.Release(s) end
	for _, wd in pairs(src.wounds or {}) do wd.fcell, wd.fstate = nil, nil end
	s.dead = true
	src.film = nil
end

-- Everything on one body goes over to another source of the same character (player -> corpse).
function FM.MoveSource(from, to)
	local s = from.film
	if not s then return end
	FM.FreeSource(to)
	s.src = to
	to.film = s
	from.film = nil
end

------------------------------------------------------------------------------------------
-- Cells
------------------------------------------------------------------------------------------
-- Where the three corners of triangle t are in the world right now, as heights against gravity, and
-- how the triangle faces (the cosine between its outward normal and up).
local function TriHeights(s, t)
	local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = s.src.pose:Tri(t)
	local ux, uy, uz = s.ux, s.uy, s.uz
	s.tha[t] = ax * ux + ay * uy + az * uz
	s.thb[t] = bx * ux + by * uy + bz * uz
	s.thc[t] = cx * ux + cy * uy + cz * uz
	s.thn[t] = nx * ux + ny * uy + nz * uz
	s.ths[t] = s.stamp
end

-- The body's surface is drawn rounded: its light turns evenly from corner to corner of each
-- triangle. What blood ran on was the triangles themselves, flat, with an edge between each two:
-- on a part that faces up (the chest of a body that lies) it ran straight across a facet, turned
-- at the facet's edge and ran straight again, and the rim of a sheet of it was a row of straight
-- lines with corners. So each place lies as far off its flat triangle as the rounded surface does
-- there: the surface that goes through the triangle's corners and stands, at each corner, square
-- to that corner's own normal (the mean of the triangles that meet there). Worked out once for a
-- place, in the body's own pose at rest (how round a part is changes little as it moves), as a
-- distance along the triangle's normal: on a part that stands upright it changes no height, as
-- it should not.
local function VertexNormals(m)
	local nx, ny, nz = {}, {}, {}
	for i = 1, m.nv do nx[i], ny[i], nz[i] = 0, 0, 0 end
	local vx, vy, vz, t1, t2, t3, tsg = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3, m.tsg
	for t = 1, m.nt do
		local a, b, c = t1[t], t2[t], t3[t]
		local ex, ey, ez = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
		local fx, fy, fz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
		-- (by the triangle's area: the cross product as it comes)
		local g = tsg[t]
		local x, y, z = (ey * fz - ez * fy) * g, (ez * fx - ex * fz) * g, (ex * fy - ey * fx) * g
		nx[a], ny[a], nz[a] = nx[a] + x, ny[a] + y, nz[a] + z
		nx[b], ny[b], nz[b] = nx[b] + x, ny[b] + y, nz[b] + z
		nx[c], ny[c], nz[c] = nx[c] + x, ny[c] + y, nz[c] + z
	end
	for i = 1, m.nv do
		local l = sqrt(nx[i] * nx[i] + ny[i] * ny[i] + nz[i] * nz[i])
		if l > 1e-9 then nx[i], ny[i], nz[i] = nx[i] / l, ny[i] / l, nz[i] / l end
	end
	m.vnx, m.vny, m.vnz = nx, ny, nz
end

-- How far the rounded surface stands off triangle t at (bu, bv), along the triangle's normal (units).
local function Bulge(m, t, bu, bv)
	local k = K.round
	if k <= 0 then return 0 end
	if not m.vnx then VertexNormals(m) end
	local vx, vy, vz, wx, wy, wz = m.vx, m.vy, m.vz, m.vnx, m.vny, m.vnz
	local a, b, c = m.t1[t], m.t2[t], m.t3[t]
	local w0 = 1 - bu - bv
	local px, py, pz = vx[a] * w0 + vx[b] * bu + vx[c] * bv, vy[a] * w0 + vy[b] * bu + vy[c] * bv, vz[a] * w0 + vz[b] * bu + vz[c] * bv
	local fx, fy, fz = BM.BindNormal(m, t)
	-- (each corner's plane, as far as the place lies under or over it, by the corner's share)
	local da = (vx[a] - px) * wx[a] + (vy[a] - py) * wy[a] + (vz[a] - pz) * wz[a]
	local db = (vx[b] - px) * wx[b] + (vy[b] - py) * wy[b] + (vz[b] - pz) * wz[b]
	local dc = (vx[c] - px) * wx[c] + (vy[c] - py) * wy[c] + (vz[c] - pz) * wz[c]
	local d = w0 * da * (wx[a] * fx + wy[a] * fy + wz[a] * fz) + bu * db * (wx[b] * fx + wy[b] * fy + wz[b] * fz) + bv * dc * (wx[c] * fx + wy[c] * fy + wz[c] * fz)
	d = d * k
	local most = K.roundMax
	return d > most and most or (d < -most and -most or d)
end

-- The height of cell c in this pose (zt), the floor liquid runs on there (zf: what has set or dried
-- is part of it) and how the surface faces.
local function Height(s, c)
	local t = s.tt[c]
	if s.ths[t] ~= s.stamp then TriHeights(s, t) end
	local a = s.tha[t]
	local up = s.thn[t]
	-- (with the relief of the place: folds the mesh does not have. They steer what runs down a
	-- steep place; on a level one they would be basins as deep as they are high, and a body that
	-- lies would keep its blood in a few of them: there they count for less)
	local z = a + s.bu[c] * (s.thb[t] - a) + s.bv[c] * (s.thc[t] - a) + s.rl[c] * (1 - K.reliefLevel * (up < 0 and -up or up)) + s.bg[c] * up
	s.zt[c] = z
	s.zf[c] = z + s.k[c] + s.sd[c] * DEPK
	s.nz[c] = up
	s.hs[c] = s.stamp
end

local DX, DY = { -1, 1, 0, 0 }, { 0, 0, -1, 1 }
local OPP = { "nb2", "nb1", "nb4", "nb3" }
local NB = { "nb1", "nb2", "nb3", "nb4" }
local GBIT = { 1, 2, 4, 8 }
local bor, band = bit.bor, bit.band

-- What stood on each cell (h + k) when it was last asked to be painted for what had changed on it,
-- and at which step (s.lp, s.lt: phase 19, touchByChange). A film made before these were kept (the
-- file was loaded again while it lay on a body) has none yet: they are made when first asked for.
local function LastPainted(s)
	local lp = s.lp
	if not lp then
		lp = {}
		s.lp, s.lt = lp, {}
	end
	return lp, s.lt
end

-- Where the blood in each cell's cloth comes from: the cell where liquid stands or stood that it
-- crept from by the shortest way (s.wo; the cell itself where liquid has stood; 0: not known). Kept
-- whatever phase 19's reachRun is, so that the switch can be turned on over blood that is already
-- there. A film made before it was kept has none yet: made when first asked for, as not known.
local function Origins(s)
	local wo = s.wo
	if not wo then
		wo = {}
		for c = 1, s.n do wo[c] = 0 end
		s.wo = wo
	end
	return wo
end

-- The film's cell at (x, y) of map mp: the one that is there, or a new one. nil where the map has
-- no cell, and when no more cells may be made (then also true: the place is there, but the film
-- is full).
local function CellAt(s, mp, x, y)
	local W = mp.W
	if x < 0 or y < 0 or x >= W or y >= mp.H then return nil end
	local ci = y * W + x
	local lut = s.lut[mp.k]
	local c = lut[ci]
	if c then return c end
	local t, bu, bv, px, py, pz = CH.Place(s.ch, mp, x, y)
	if not t then return nil end
	if s.n >= K.maxCells or FM.cells >= L.Cap(FM.cvCells) then
		s.full = true
		return nil, true
	end
	Pin = Pin or ABL.PoolSim.Pin
	c = s.n + 1
	s.n = c
	FM.cells = FM.cells + 1
	lut[ci] = c
	s.mk[c], s.ci[c], s.tt[c], s.bu[c], s.bv[c] = mp.k, ci, t, bu, bv
	s.h[c], s.k[c], s.sd[c], s.ab[c], s.tb[c], s.td[c], s.w[c], s.fed[c] = 0, 0, 0, 0, 0, 0, 0, 0
	-- what the place holds back, by what it is (skin or cloth) and by the body's unevenness there
	local a = mp.cell
	local film = mp.skin and K.filmSkin or K.filmCloth
	s.hc[c] = film * (1 + K.pinAmp * Pin(s.pu + x * a * K.pinScale, s.pv + y * a * K.pinScale))
	s.rs[c] = film * K.res
	-- the relief of the place: folds and creases, by where it is on the body
	-- (folds run along the body more than across it, as cloth hangs: the relief is drawn out that way,
	-- so that it turns what runs down aside into its hollows and seldom dams it)
	local kr = 1 / K.reliefScale
	-- (Phase 19, foldWarp: and a fold does not hang as a ruled line, it wanders to either side as it
	-- goes down, by about foldWarp units over foldWarpLen of the body's height. Drawn out along the
	-- body alone, the relief's hollows ran straight down, and a run that followed one of them down
	-- (steer) was as straight as they were: measured on the bench, 2026-10-17, the floor's fall at the
	-- cells of a standing chest's run was turned 11 to 20 degrees to the side at a third of them, to
	-- either side of the hollow it lay in.)
	local fx0, fy0 = px, py
	local fw = s.v19fw
	if fw == nil then fw = C.V19On("foldWarp") end
	if fw then
		local V = C.V19
		local A, kw = V.foldWarp or 0, 1 / (V.foldWarpLen or 6)
		fx0 = px + A * (Noise3(px * kw * 0.5 + s.pv + 3.7, py * kw * 0.5 + 1.3, pz * kw + s.pu) - 0.5)
		fy0 = py + A * (Noise3(px * kw * 0.5 + 8.1, py * kw * 0.5 + s.pu + 5.9, pz * kw + s.pv) - 0.5)
	end
	local qx, qy, qz = fx0 * kr + s.pu, fy0 * kr + s.pv, pz * kr * K.reliefTall
	local fine = Noise3(qx * 3 + 11.3, qy * 3 + 5.7, qz * 3 + 2.9)
	s.rl[c] = (mp.skin and K.reliefSkin or K.reliefCloth) * 2 * ((Noise3(qx, qy, qz) - 0.5) * (1 - K.reliefFine) + (fine - 0.5) * K.reliefFine)
		+ K.grain * 2 * (Hash3(x + s.pu, y + s.pv, mp.k) - 0.5)
	-- how readily the cloth there passes blood on to the cloth beside it: in patches (how it lies on
	-- the body, where it is stretched) and finer within them (its weave)
	local kp = 1 / K.wickPatch
	local wl = Noise3(px * kp + s.pv + 3.1, py * kp + s.pu + 8.4, pz * kp + 6.6)
	-- (value noise keeps to the middle of its range: spread out, or every patch is about the mean)
	wl = wl < 0.25 and 0 or (wl > 0.75 and 1 or (wl - 0.25) * 2)
	wl = wl * wl * (3 - 2 * wl)
	local wf = Noise3(qx * 2.6 + 3.1, qy * 2.6 + 8.4, qz * 2.6 + 6.6)
	wf = wf < 0.25 and 0 or (wf > 0.75 and 1 or (wf - 0.25) * 2)
	s.wk[c] = (1 + K.wickUneven * 2 * ((wl - 0.5) * 0.5 + (wf - 0.5) * 0.5)) * (mp.skin and K.wickSkin or 1)
	-- ... and how far it lets blood creep from where liquid stands (cells): by the patch, so that
	-- the soaked margin of a stream is wide along one stretch and narrow along the next
	local rf = s.v19rf
	if rf == nil then rf = C.V19On("reachField") end
	if rf then
		-- (Phase 19, reachField: from a field of its own, at two scales, that goes on evenly between
		-- reachLo and reachHi times the reach and is clamped only at its ends. By the patch field wl,
		-- which is clamped to two flat levels, the reach was a third of a cell or four cells: along a
		-- low patch the stain was the liquid's own path, along a high one a block with sides parallel
		-- to the run, and the two met within a unit or two. The width of the margin followed wl at
		-- 0.96 to 0.97 on four standing cases. With this field (reachLo 0.25, reachHi 1.1) and
		-- reachRun (AgeCell), on male_06 and female_03 standing (2 ml/s on three seeds, 5 ml/s on
		-- one; 20 and 40 s) the narrowest row of the stain below the wound was 4 to 9 cells wide and
		-- no row was the liquid's path alone; before it was 1 to 4 cells, and 2 to 21 rows were. How
		-- fast blood creeps, s.wk, still goes by wl. Measured on the bench, 2026-10-17.)
		local V = C.V19
		local kq = 1 / (K.wickPatch * (V.reachPatch or 0.5))
		-- (Three scales, each read in a frame of its own turned against the body's axes. Read along the
		-- body's height a run that goes straight down crossed the noise's lattice at even steps, and the
		-- margin of its stain bulged at even steps, a string of beads: run p19d, 2026-10-17. Turned, a
		-- line straight down crosses the lattice at steps that do not repeat, and the finer scales,
		-- at ratios that do not divide, break up what is left.)
		local k1, k2, k3 = kq, kq * 2.31, kq * 5.13
		local r1 = Noise3((0.8746 * px - 0.4848 * py) * k1 + s.pv + 7.7, (0.3872 * px + 0.6985 * py - 0.6018 * pz) * k1 + s.pu + 1.9, (0.2918 * px + 0.5263 * py + 0.7986 * pz) * k1 + 4.4)
		local r2 = Noise3((0.6831 * px + 0.2900 * py - 0.6703 * pz) * k2 + s.pu + 2.3, (-0.3907 * px + 0.9205 * py) * k2 + s.pv + 9.1, (0.6170 * px + 0.2619 * py + 0.7422 * pz) * k2 + 5.5)
		local r3 = Noise3((0.9135 * px + 0.4067 * pz) * k3 + s.pv + 3.3, (0.2611 * px + 0.7660 * py - 0.5866 * pz) * k3 + s.pu + 6.1, (-0.3115 * px + 0.6428 * py + 0.6997 * pz) * k3 + 8.8)
		local rn = 0.5 + (0.55 * r1 + 0.30 * r2 + 0.15 * r3 - 0.5) * (V.reachContrast or 1.5)
		rn = rn < 0 and 0 or (rn > 1 and 1 or rn)
		local lo = V.reachLo or 0.4
		s.wr[c] = (mp.skin and K.wickReachSkin or K.wickReach) * (lo + ((V.reachHi or 1.6) - lo) * rn)
	else
		s.wr[c] = (mp.skin and K.wickReachSkin or K.wickReach) * (0.15 + 1.7 * wl)
	end
	s.sk[c] = mp.skin and 1 or 0
	-- ... and how much of it the cloth there takes up
	s.abc[c] = K.soakDepth * (mp.absorb or 0) * (1 + K.soakUneven * 2 * (fine - 0.5))
	-- (what is fixed to the place and tells it from the places beside it in the picture: cl_filmdraw.lua)
	s.mt[c] = wl * 0.6 + wf * 0.4
	s.wi[c] = 0
	s.pt[c] = 0
	-- lw: liquid has stood here (the contact line holds less at such a place); wg: how far the blood
	-- in its cloth has crept from where liquid stood (cells); ws: since when liquid has stood at the
	-- place it creeps from (0: never yet); gp: its faces that lie across a gap between two pieces of
	-- the mesh (bits 1, 2, 4, 8: toward -x, +x, -y, +y)
	s.lw[c], s.wg[c], s.ws[c], s.gp[c] = 0, 0, 0, 0
	-- (wo: where the blood in its cloth comes from, Origins)
	Origins(s)[c] = 0
	-- What is shown of the flow (cl_filmdraw.lua). fx, fy: what crossed its faces in this step, along
	-- its grid's x and y; dx, dy: the way blood runs over it, as that has been of late (a vector of
	-- length one at the most, 0 where none has run); sp: how fast, cells a second; ds: how far the
	-- blood on it has run since it left the wound, cells (it is carried with the blood, as the time
	-- it left the vessel is); rn: a number of its own (0 .. 1).
	-- (wp: how far the liquid on it has run while it ran, cells: what its waves travel by)
	s.fx[c], s.fy[c], s.dx[c], s.dy[c], s.sp[c], s.ds[c], s.wp[c] = 0, 0, 0, 0, 0, 0, 0
	s.rn[c] = Hash3(x + s.pu + 17.3, y + s.pv + 5.1, mp.k + 3)
	s.ar[c] = a * a
	s.bg[c] = Bulge(s.m, t, bu, bv)
	s.mu[c], s.sh[c], s.gn[c], s.cf[c] = MU0, 0, 0, 1
	s.on[c], s.idle[c], s.mv[c], s.dq[c] = 0, 0, -1, 0
	local lp, lt = LastPainted(s)
	lp[c], lt[c] = 0, 0
	s.hs[c] = 0
	Height(s, c)
	-- its neighbours in the grid that are there already
	for d = 1, 4 do
		local xx, yy = x + DX[d], y + DY[d]
		local q = (xx >= 0 and yy >= 0 and xx < W and yy < mp.H) and lut[yy * W + xx] or nil
		s[NB[d]][c] = q or 0
		if q then s[OPP[d]][q] = c end
	end
	return c
end

-- The cell across face d of cell c (1 .. 4: toward -x, +x, -y, +y of its map's grid): made when it
-- is not there yet. Beyond the rim of the map the surface may go on across a texture seam or a gap
-- (CH.Link). -1: nothing there, an edge the blood leaves the body at.
-- (Phase 19, fullIsWall: -2 where the surface goes on but the film may make no more cells. That is a
-- wall: nothing crosses it and nothing leaves the body there, Flow; it is no hem and no edge of the
-- surface, AgeCell. As -1 it was an edge, and a body that had all the cells it may have dripped from
-- the fronts of its runs as from a hem. -2 is never kept in nb1 .. nb4: it is asked again, and is a
-- cell once there is room. Faces off the grid are looked up across the seam whether the film is full
-- or not: a cell there that is already made is found without making one.)
local function Neighbour(s, c, d)
	local mp = s.ch.mats[s.mk[c]]
	local ci = s.ci[c]
	local x = ci % mp.W
	local y = (ci - x) / mp.W
	if s.v19w then
		local q, capped = CellAt(s, mp, x + DX[d], y + DY[d])
		if not q and not capped then
			local mp2, x2, y2, gap = CH.Link(s.ch, mp, x, y, DX[d], DY[d])
			if mp2 then
				q, capped = CellAt(s, mp2, x2, y2)
				if q then s.gp[c] = bor(s.gp[c], gap and GBIT[d] * 17 or GBIT[d] * 16) end
			end
		end
		if not q and capped then
			prof.wall = (prof.wall or 0) + 1
			return -2
		end
		s[NB[d]][c] = q or -1
		return q or -1
	end
	local q = CellAt(s, mp, x + DX[d], y + DY[d])
	if not q and not s.full then
		local mp2, x2, y2, gap = CH.Link(s.ch, mp, x, y, DX[d], DY[d])
		if mp2 then
			q = CellAt(s, mp2, x2, y2)
			-- (bits 16 .. 128: the face leads off its map's grid, where x and y may run another way)
			if q then s.gp[c] = bor(s.gp[c], gap and GBIT[d] * 17 or GBIT[d] * 16) end
		end
	end
	-- (no more cells may be made: asked again when there is room, not an edge for good)
	if not q and s.full then return -1 end
	s[NB[d]][c] = q or -1
	return q or -1
end

-- Cell c is to be painted again (cl_filmdraw.lua, PaintFilm). first: blood has only just come to
-- it, or the last of it has gone: where the film's outline lies changes there, and that is painted
-- before anything else (a run is on the body before the drop that falls from its tip is in the
-- air, however much else waits to be painted). s.dq: 0 it does not wait, 1 it waits its turn, 2 it
-- waits among the first.
-- (s.inq: it stands in the list of those that wait their turn. A cell that waited its turn, was
-- then asked for among the first, was painted from there and asked for again stood in that list
-- twice, and so on without end: on a film that had bled for two minutes the list held 72,570
-- entries for 3,262 cells, and each painting carried all of them along. Measured: scene
-- cont_long, run fl2_first. A cell stands in it once.)
local function Touch(s, c, first)
	local d = s.dq[c]
	if first then
		if d ~= 2 then
			s.dq[c] = 2
			local n = s.un + 1
			s.un = n
			s.uq[n] = c
		end
	elseif d == 0 then
		s.dq[c] = 1
		if not s.inq[c] then
			s.inq[c] = true
			local n = s.qn + 1
			s.qn = n
			s.queue[n] = c
		end
	end
end
FM.Touch = Touch

-- Phase 19: what asks for a cell to be painted again besides the clock (C.V19; s.v19c, s.v19e and
-- s.v19p are read once a frame, Advance).
-- The liquid on cell c (T = h + k) has come up to, or gone down under, the least that shows as
-- liquid (K.topLo): the liquid's own outline moves there, and that is painted before anything else,
-- as where blood first comes is (touchLiquidEdge). (It waited its turn: a second pulse of a wound
-- running down the first's trail showed its liquid late and in pieces.)
local function EdgeTouch(s, c, T)
	Touch(s, c, true)
	local lp, lt = LastPainted(s)
	lp[c], lt[c] = T, s.stepNo
	prof.touchE = (prof.touchE or 0) + 1
end

-- Cell c holds T (h + k) now. Painted again when that is not what it was when it was last asked to
-- be: before anything else where the liquid's outline moved, else in its turn when it has changed
-- by more than shows (C.V19.touchAbs units, or touchRel of what stands there), at most every fourth
-- step, and only while not much of the film waits to be painted (K.paintBusy: then the clock alone
-- asks, as before). It moves as the blood on it does, not on a clock of its own a second long that
-- every cell beside it keeps out of step with: a run's width, colour and highlight changed in small
-- hops, cell by cell (touchByChange). A cell that waits to be painted is shown as it is when it is:
-- what it holds then is what was last asked for. (lp, lt: LastPainted)
local function Changed(s, c, T, byChange, edge, lp, lt)
	local l = lp[c]
	local stepNo = s.stepNo
	if l == nil then
		lp[c], lt[c] = T, stepNo
	elseif edge and (l < K.topLo) ~= (T < K.topLo) then
		EdgeTouch(s, c, T)
	elseif s.dq[c] ~= 0 then
		lp[c] = T
	elseif byChange and stepNo - lt[c] >= 4 and s.qn <= K.paintBusy then
		local dv, tol = T - l, T * (C.V19.touchRel or 0.12)
		local least = C.V19.touchAbs or 0.0012
		if tol < least then tol = least end
		if dv > tol or dv < -tol then
			Touch(s, c)
			lp[c], lt[c] = T, stepNo
			prof.touchC = (prof.touchC or 0) + 1
			return true
		end
	end
	return false
end

-- v ml has just been added to what waits at cell c to drop (s.out): the film swells there as that
-- grows (cl_filmdraw.lua, pendPaint), and the cell is painted again at each third of a drop's worth.
local function PendTouch(s, c, v)
	local o1 = s.out[c]
	local k3 = 3 / (K.dropVol * (s.dropK or 1) * (s.dropBig or 1))
	local n0 = floor((o1 - v) * k3)
	if n0 < 3 and floor(o1 * k3) > n0 then
		Touch(s, c)
		prof.touchP = (prof.touchP or 0) + 1
	end
end

local function Wake(s, c)
	if s.on[c] == 0 then
		s.on[c] = 1
		local n = s.na + 1
		s.na = n
		s.act[n] = c
	end
	s.idle[c] = 0
end

-- x (units of thickness on cell c) of liquid that left the vessel at time t onto cell c.
local function Put(s, c, x, t)
	local h = s.h[c]
	s.tb[c] = h > 0 and (s.tb[c] * h + t * x) / (h + x) or t
	s.ds[c] = h > 0 and s.ds[c] * h / (h + x) or 0
	-- (phase 19, steer: and it starts on a line of its own, through the place it came to, Flow)
	local dv = s.dv
	if dv then dv[c] = h > 0 and (dv[c] or 0) * h / (h + x) or 0 end
	s.h[c] = h + x
	s.td[c] = 0
	s.fed[c] = t
	s.lw[c] = 1
	local first = s.w[c] == 0
	if first then
		s.w[c] = 1
		s.wetN = s.wetN + 1
	end
	s.rest = false
	Wake(s, c)
	Touch(s, c, first)
	-- (phase 19: liquid has come here, EdgeTouch. Where blood comes for the first time it is asked
	-- for first already.)
	if s.v19e and not first then
		local kk = s.k[c]
		local T = h + x + kk
		if h + kk < K.topLo and T >= K.topLo then EdgeTouch(s, c, T) end
	end
end

------------------------------------------------------------------------------------------
-- Blood arriving
------------------------------------------------------------------------------------------
-- What stands in cell c beyond what an opening holds (K.source) runs over its rim where the rim
-- is lowest. The four places beside it are filled from the lowest up, as one vessel: each takes
-- what brings its surface level with the next, no further than the opening's own level. Round
-- an opening in a level place that is all sides alike; on a slope it is the side that lies down
-- it, and a place that lies higher than the opening gets none. What they cannot take stays in
-- the opening and stands higher there, from where it flows as any other blood does (Flow).
-- (Before, a quarter of it was laid on each of the four whatever way they faced: a round patch
-- with the wound in its middle, on a wall as on a floor.)
local SPJ, SPE = {}, {}
local function Spill(s, c, t)
	local over = s.h[c] - K.source
	if over <= 0 then return end
	local stamp, hs, zf, h, ar = s.stamp, s.hs, s.zf, s.h, s.ar
	if hs[c] ~= stamp then Height(s, c) end
	local top = zf[c] + K.source
	local n = 0
	for d = 1, 4 do
		local j = s[NB[d]][c]
		if j == 0 then j = Neighbour(s, c, d) end
		if j > 0 then
			if hs[j] ~= stamp then Height(s, j) end
			local e = zf[j] + h[j]
			if e < top then
				n = n + 1
				local i = n
				while i > 1 and SPE[i - 1] > e do
					SPJ[i], SPE[i] = SPJ[i - 1], SPE[i - 1]
					i = i - 1
				end
				SPJ[i], SPE[i] = j, e
			end
		end
	end
	if n == 0 then return end
	local a = ar[c]
	local vol = over * a
	local L, area, used, k = SPE[1], 0, 0, 0
	while k < n do
		k = k + 1
		area = area + ar[SPJ[k]]
		local to = k < n and SPE[k + 1] or top
		local need = (to - L) * area
		if used + need >= vol then
			L = L + (vol - used) / area
			break
		end
		used = used + need
		L = to
	end
	local gave = 0
	local trk = s.trk
	for i = 1, k do
		local j = SPJ[i]
		local x = L - SPE[i]
		if x > 1e-9 then
			Put(s, j, x, t)
			gave = gave + x * ar[j]
			if trk then
				local ra, rb = s.rid[c] or 0, s.rid[j] or 0
				if ra ~= rb then
					local v = x * ar[j] * ML
					trk.xout[ra] = (trk.xout[ra] or 0) + v
					trk.xin[rb] = (trk.xin[rb] or 0) + v
				end
			end
		end
	end
	h[c] = h[c] - gave / a
end

-- vol (ml) at cell c (a wound's opening, or where a drop fell): it holds only so much, and what
-- wells up beyond that runs over its rim (Spill), from where it runs, soaks in or drops off like
-- any other blood.
local function Deposit(s, c, vol, t)
	local x = vol / (ML * s.ar[c])
	-- (counted where it arrives, while what gathers where is measured: cl_accum.lua)
	local trk = s.trk
	if trk then local r = s.rid[c] or 0 trk.ein[r] = (trk.ein[r] or 0) + vol end
	Put(s, c, x, t)
	if s.h[c] > K.source then Spill(s, c, t) end
end

-- How far a wound's opening reaches from its middle (units): the visible wound's own, where it has
-- one (cl_woundfx.lua: the mark's opening), else the smallest there is. Not by how hard it bleeds:
-- a wound that bleeds hard is no wider for it, its blood comes out of the same hole faster.
local function OpenRadius(wd)
	local mk = wd.mark
	local cav = mk and mk.cav
	local r = cav and cav.R0 or K.openMin
	if not (r >= K.openMin) then r = K.openMin end
	return r < K.openMax and r or K.openMax
end
FM.OpenRadius = OpenRadius

-- The cells of a wound's opening: the cell it lies in and those whose middle lies within `r` units
-- of that cell's along the grid (a hole a cell wide is one cell; a wide exit or a gash is a few).
local function Opening(s, c, r)
	local list = { c }
	local mp = s.ch.mats[s.mk[c]]
	local rc = r / mp.cell
	local n = floor(rc)
	if n < 1 then return list end
	local ci = s.ci[c]
	local x = ci % mp.W
	local y = (ci - x) / mp.W
	local r2 = rc * rc
	for dy = -n, n do
		for dx = -n, n do
			if (dx ~= 0 or dy ~= 0) and dx * dx + dy * dy <= r2 then
				local q = CellAt(s, mp, x + dx, y + dy)
				if q then list[#list + 1] = q end
			end
		end
	end
	return list
end

-- Seeped blood arriving at a wound (cl_emission.lua, through ABL.Flow.Feed). It comes onto the body
-- with the film's next step (Inflow): the wound is asked several times between two steps.
function FM.Feed(src, wd, vol)
	if not ABL.GoodVol(vol) then return end
	local m = src.mesh
	local ch = m and CH.Get(m)
	if not ch or not wd.tri or wd.tri > m.nt then
		-- no surface to lay it on yet: the wound drips directly instead
		wd.dripAcc = wd.dripAcc + vol
		return
	end
	local s = State(src, ch)
	local c = wd.fcell
	-- (the wound's own opening, as wide as it is seen to be: a wound gets its mark a moment after
	-- it is there, and its opening is known from then)
	local r = OpenRadius(wd)
	if c == nil or wd.fstate ~= s or wd.ftri ~= wd.tri or wd.fopenR ~= r then
		local mp, x, y = CH.CellOf(ch, wd.tri, wd.u, wd.v)
		c = mp and CellAt(s, mp, x, y) or false
		wd.fcell, wd.fstate, wd.ftri, wd.fopenR = c, s, wd.tri, r
		wd.fopen = c and Opening(s, c, r) or nil
		-- (the wound's mark is told where in the film its opening lies: what is seen in the
		-- opening is the blood that lies over it, cl_woundfx.lua)
		local mk = wd.mark
		if mk then mk.fcell, mk.fstate = c or nil, s end
	end
	if not c then
		-- (a place that carries no film: a hand, the inside of the mouth)
		wd.dripAcc = wd.dripAcc + vol
		return
	end
	wd.fin = (wd.fin or 0) + vol
	if not wd.fq then
		wd.fq = true
		s.feeds[#s.feeds + 1] = wd
	end
end

-- The film's cell at a place of the body (triangle t at u, v), if blood has ever come there: the
-- film's state and the cell, or nothing. (A wound's mark asks, to know whether blood lies over
-- its opening: one that does not bleed any more, or bleeds on another client's word, is told of
-- no cell by FM.Feed.) No cell is made for the asking.
function FM.CellOf(src, t, u, v)
	local s, m = src.film, src.mesh
	if not s or not m or s.m ~= m or s.dead or not t or t > m.nt then return nil end
	local mp, x, y = CH.CellOf(s.ch, t, u, v)
	if not mp then return nil end
	local c = s.lut[mp.k][y * mp.W + x]
	if not c then return nil end
	return s, c
end

local function Inflow(s, t)
	local feeds = s.feeds
	local n = #feeds
	if n == 0 then return end
	WS = WS or ABL.Wounds
	local src = s.src
	local w = 0
	for i = 1, n do
		local wd = feeds[i]
		local vol = wd.fin or 0
		wd.fin = 0
		if vol > 0 and wd.fcell and wd.fstate == s then
			local open = wd.fopen
			local share = vol / #open
			local opn = s.opn
			for q = 1, #open do
				local c = open[q]
				-- (a place blood comes out at: what is shown of the film reaches round all of the
				-- opening there, cl_filmdraw.lua)
				if not opn[c] then
					opn[c] = true
					Touch(s, c, true)
				end
				Deposit(s, c, share, t)
			end
			FC.Release("surface", vol)
			s.bk.fed, s.bk.surface = s.bk.fed + vol, s.bk.surface + vol
			WS.Ledger(src, "onBody", vol)
		end
		-- (a wound that has closed gives no more: it leaves the list)
		if wd.removed or wd.fstate ~= s then
			wd.fq = nil
		else
			w = w + 1
			feeds[w] = wd
		end
	end
	for i = w + 1, n do feeds[i] = nil end
end

-- A drop that landed on a body (its own, or another character's): into the film where it fell.
-- Returns false when no film can lie there (the caller books the drop and leaves a stain).
function FM.AddAt(src, bone, x, y, z, vol, vx, vy, vz, owner)
	local m = src.mesh
	if not m or not ABL.GoodVol(vol) or not ABL.InWorld(x, y, z) then return false end
	local ch = CH.Get(m)
	if not ch then return false end
	local tri, u, v = BM.Anchor(src.pose, bone, x, y, z, 6)
	if not tri then return false end
	local s = State(src, ch)
	local mp, cx, cy = CH.CellOf(ch, tri, u, v)
	local c = mp and CellAt(s, mp, cx, cy)
	if not c then return false end
	Deposit(s, c, vol, CurTime())
	FC.Move("airborne", "surface", vol)
	s.bk.fed, s.bk.surface = s.bk.fed + vol, s.bk.surface + vol
	if FM.onEvent then FM.onEvent("landed", x, y, z, vol, s) end
	return true
end

------------------------------------------------------------------------------------------
-- The step
------------------------------------------------------------------------------------------
-- Every cell that holds liquid above its residual film gives across its four faces to what lies
-- lower. In place: what leaves a cell is in its neighbour at once, so nothing is made or lost and
-- no cell gives more than it holds; the order of the cells and of the faces turns from step to step.
local function Flow(s, dt)
	local h, zf, zt, w, hc, rs, mu, cf, tb = s.h, s.zf, s.zt, s.w, s.hc, s.rs, s.mu, s.cf, s.tb
	local ar, gn, hs, nz, mv, idle, on, td, fed = s.ar, s.gn, s.hs, s.nz, s.mv, s.idle, s.on, s.td, s.fed
	local nb1, nb2, nb3, nb4 = s.nb1, s.nb2, s.nb3, s.nb4
	local lw, gp = s.lw, s.gp
	local fx, fy, ds = s.fx, s.fy, s.ds
	local act, out, outT = s.act, s.out, s.outT
	local na = s.na
	local stamp, stepNo, now = s.stamp, s.stepNo, s.now
	local kf = KF.kFlow * dt / K.visc
	local LIM, memK, tens, levelK, IDLE, slopeK = K.lim, K.memory, K.tension, K.level, K.idleSteps, K.slope
	local LIMR = K.limRun
	local EDGE = K.edgeHold
	local DOWN = K.downFirst ~= 0
	local gapDrip, filmMax = K.gapDrip, K.filmMax
	-- (what crosses from one region of the film to another, and what leaves it: counted while what
	-- gathers where is measured, cl_accum.lua. nil otherwise: nothing is counted.)
	local trk, rid = s.trk, s.rid
	-- (phase 19: where liquid comes to a place, EdgeTouch; what waits to drop, PendTouch)
	local edge, pend, gel, topLo = s.v19e, s.v19p, s.k, K.topLo
	-- (phase 19, steer: how far the line its liquid follows lies off each cell, s.dv)
	local steer, dv, stMin, stW = s.v19st, s.dv, s.stMin, s.stW
	local rot = s.rot
	s.rot = (rot + 1) % 4
	-- (now and then every cell that could run is looked at, also those that have not for a while:
	-- the body has turned, or what dammed them has given way)
	local all = stepNo % 20 == 0
	local i0, i1, di = 1, na, 1
	if rot >= 2 and K.sweep == 0 then i0, i1, di = na, 1, -1 end
	local moved, looked = 0, 0
	for ii = i0, i1, di do
		local c = act[ii]
		local hu = h[c] - rs[c]
		if hu > 0 and (all or idle[c] < IDLE or (stepNo + c) % 8 == 0) then
			looked = looked + 1
			if hs[c] ~= stamp then Height(s, c) end
			local a2 = ar[c]
			local la = sqrt(a2)
			local kq = kf / a2
			local kS = 3 * la / dt
			local gpc = gp[c]
			-- Down the steepest way first: what gravity takes of a layer goes before anything of
			-- it is pushed to the sides. (The faces took turns at being first. A place a wound's
			-- blood passes through holds a step's worth of it for a moment, far more than stands
			-- there from one step to the next: every other step that was offered to a side
			-- first, deep enough to cross any contact line, and a run fanned out to ten cells
			-- just below the wound. Measured: scene bleed_origin, run bo5.) Where no side lies
			-- lower the turns are as they were.
			local first, turn = rot, 1
			-- (the floor of the cells on either side along the grid's x and y, for steer below)
			local zl, zr, zu, zd
			if DOWN or steer then
				local best = 0
				local zc = zf[c]
				for d0 = 0, 3 do
					local j0
					if d0 == 0 then j0 = nb1[c] elseif d0 == 1 then j0 = nb2[c] elseif d0 == 2 then j0 = nb3[c] else j0 = nb4[c] end
					if j0 == 0 then j0 = Neighbour(s, c, d0 + 1) end
					if j0 > 0 then
						if hs[j0] ~= stamp then Height(s, j0) end
						local z0 = zf[j0]
						local drop = zc - z0 - h[j0]
						if DOWN and drop > best then best, first = drop, d0 end
						if d0 == 0 then zl = z0 elseif d0 == 1 then zr = z0 elseif d0 == 2 then zu = z0 else zd = z0 end
					end
				end
				-- (the two sides after it in one order at one step and the other at the next)
				if best > 0 and rot % 2 == 1 then turn = 3 end
			end
			-- Phase 19, steer: the way down the floor here, as the floor falls across the cells on
			-- either side (sdx, sdy along the grid's x and y; sG, how steep), and how far off this
			-- cell the line lies that its liquid follows down it (sD, cells, across that way). A
			-- front that gravity drives on goes the way the floor falls, wherever the grid's lines
			-- go: it is held only in the cells the line passes within stW of, the cells of a
			-- narrow run that goes down that way; and the line is carried on with the liquid, cell
			-- by cell, as far as each step takes it off it (as the transversal deviation of D8-LTD
			-- flow routing, Orlandini et al. 2003). Before, of the four cells round a place the
			-- one that lay lowest was given to first and a front was helped on by how far each
			-- lay lower: down a wall whose grid stands upright that is the cell below, by a whole
			-- cell's fall, against a fold's fall of a fifth of that to the side, and a run went
			-- straight down its column of cells, whatever the folds and the body's shape round it
			-- turned it toward (the user's picture of 2026-10-17: a stripe straight from the
			-- wound to the hem). Where the floor is near level (less than stMin) there is no way
			-- down to follow, and the front goes as before.
			local sG, sdx, sdy, sD
			if steer then
				local zc = zf[c]
				local gx = zl and (zr and (zl - zr) * 0.5 or zl - zc) or (zr and zc - zr or 0)
				local gy = zu and (zd and (zu - zd) * 0.5 or zu - zc) or (zd and zc - zd or 0)
				local g = sqrt(gx * gx + gy * gy)
				if g > stMin * la then
					sdx, sdy = gx / g, gy / g
					sG = g / la
					if sG > 1 then sG = 1 end
					sD = dv[c] or 0
				end
			end
			for f = 0, 3 do
				local d = (first + f * turn) % 4
				local j
				if d == 0 then j = nb1[c] elseif d == 1 then j = nb2[c] elseif d == 2 then j = nb3[c] else j = nb4[c] end
				if j == 0 then j = Neighbour(s, c, d + 1) end
				local q = 0
				-- (steer: how far off the line the cell across this face lies, and whether the face
				-- leads down the way the floor falls)
				local sJ, sOn
				if sG then
					local un, ud
					if d == 0 then un, ud = -sdy, -sdx elseif d == 1 then un, ud = sdy, sdx elseif d == 2 then un, ud = sdx, -sdy else un, ud = -sdx, sdy end
					sJ = sD - un
					sOn = ud > 0 and (sJ < 0 and -sJ or sJ) <= stW
				end
				if j > 0 then
					if hs[j] ~= stamp then Height(s, j) end
					local hj = h[j]
					local dh = zf[c] + h[c] - zf[j] - hj
					if dh > 0 then
						local go = true
						if hj <= 0 then
							-- A dry cell ahead: the contact line holds until the head over it is more than
							-- the surface there holds back (more where it faces up and gravity presses the
							-- layer on), by the line's shape there. The head is no more than the layer
							-- itself: down a steep place the drop to the next cell is many times the
							-- layer's depth, and counted in full it would let any trace of blood run on
							-- over dry cloth. The front has to stand deep enough before it advances, so it
							-- advances first where the surface holds it least, and what follows runs in
							-- what is already wet: fingers and rivulets, not one even edge.
							-- (Gravity does help it on: by as much as the cell ahead lies lower, the layer counts
							-- for more. A front runs on downhill sooner than it spreads sideways, and far sooner
							-- than uphill.)
							local head = h[c]
							local fall
							-- (steer: by the floor's fall along the line in the cells it passes through,
							-- by none in the others: these it spreads into as it would on a level place)
							if sG then fall = sOn and sG or 0 else fall = (zf[c] - zf[j]) / la end
							if fall > 0 then head = head * (1 + slopeK * (fall < 1 and fall or 1)) end
							if dh < head then head = dh end
							local up = nz[j]
							-- (a place where liquid has stood before holds the line far less; cloth that has
							-- only drawn blood in from beside it holds it as dry cloth does, or the liquid
							-- would follow the stain sideways and the stain the liquid, without end)
							local thr = lw[j] ~= 0 and hc[j] * memK or hc[j]
							if up > 0 then thr = thr * (1 + levelK * up * up) end
							if tens > 0 and head > thr * 0.5 then
								local nw = 0
								local a1, a2n, a3, a4 = nb1[j], nb2[j], nb3[j], nb4[j]
								if a1 > 0 then
									if h[a1] > 0 then nw = nw + 1 end
									local e = nb3[a1]
									if e > 0 and h[e] > 0 then nw = nw + 1 end
									e = nb4[a1]
									if e > 0 and h[e] > 0 then nw = nw + 1 end
								end
								if a2n > 0 then
									if h[a2n] > 0 then nw = nw + 1 end
									local e = nb3[a2n]
									if e > 0 and h[e] > 0 then nw = nw + 1 end
									e = nb4[a2n]
									if e > 0 and h[e] > 0 then nw = nw + 1 end
								end
								if a3 > 0 and h[a3] > 0 then nw = nw + 1 end
								if a4 > 0 and h[a4] > 0 then nw = nw + 1 end
								-- (a straight front has three wet cells behind it, along the grid or across it)
								local fk = 1 + tens * (3 - nw) / 3
								thr = thr * (fk > 0.5 and fk or 0.5)
							end
							-- (no place holds back more than a puddle's depth: on a level place a layer that
							-- deep spreads, whatever the surface is)
							if thr > filmMax then thr = filmMax end
							go = head > thr
						end
						-- Across a gap between two pieces of clothing only what stands above what an edge
						-- holds goes: blood that comes down to a hem gathers along it first (it stands
						-- deeper there than in the run above, so it spreads to the places beside it and
						-- soaks them), and crosses or drops where it has gathered.
						local hq = hu
						if go and gpc ~= 0 and band(gpc, GBIT[d + 1]) ~= 0 then
							hq = hu - EDGE
							if hq <= 0 then go = false end
						end
						if go then
							q = kq * dh * hq * hq * hq / (mu[c] * cf[c])
							-- (no more than brings the two surfaces level, and no more than the layer
							-- has: where the place ahead lies far lower than the layer is deep, down a
							-- steep place, nothing pushes back and most of the layer may go in one step)
							local lim = hq * LIMR
							local l2 = dh * LIM
							if l2 < lim then lim = l2 end
							if q > lim then q = lim end
							if q > QEPS then
								h[c] = h[c] - q
								-- (which way it went: what is shown of the flow goes by that)
								if d < 2 then fx[c] = fx[c] + (d == 0 and -q or q) else fy[c] = fy[c] + (d == 2 and -q or q) end
								local qc = q
								if gpc ~= 0 and band(gpc, GBIT[d + 1]) ~= 0 then
									-- Across a gap between two pieces of clothing (a hem over trousers, a
									-- cuff): part of it does not get across but hangs at the edge and drops.
									local x = q * gapDrip
									qc = q - x
									out[c] = (out[c] or 0) + x * a2 * ML
									if pend then PendTouch(s, c, x * a2 * ML) end
									if not outT[c] then outT[c] = now end
									if trk then local r = rid[c] or 0 trk.eout[r] = (trk.eout[r] or 0) + x * a2 * ML end
								end
								if trk and qc > 0 then
									local ra, rb = rid[c] or 0, rid[j] or 0
									if ra ~= rb then
										local v = qc * a2 * ML
										trk.xout[ra] = (trk.xout[ra] or 0) + v
										trk.xin[rb] = (trk.xin[rb] or 0) + v
									end
								end
								if qc > 0 then
									local qj = qc * a2 / ar[j]
									tb[j] = hj > 0 and (tb[j] * hj + tb[c] * qj) / (hj + qj) or tb[c]
									-- (it has run a cell further; and where the place it comes to lies in the
									-- same grid, that place runs the same way)
									ds[j] = hj > 0 and (ds[j] * hj + (ds[c] + 1) * qj) / (hj + qj) or ds[c] + 1
									local same = gpc < 16 or band(gpc, GBIT[d + 1] * 16) == 0
									if same then
										if d < 2 then fx[j] = fx[j] + (d == 0 and -qj or qj) else fy[j] = fy[j] + (d == 2 and -qj or qj) end
									end
									-- (steer: and it is as far off its line there as the step took it; in
									-- another grid, or where the floor is near level, on a line of its own)
									if steer then
										local dj = (sG and same) and sJ or 0
										dv[j] = hj > 0 and ((dv[j] or 0) * hj + dj * qj) / (hj + qj) or dj
									end
									h[j] = hj + qj
									if edge then
										local kj = gel[j]
										if hj + kj < topLo and hj + qj + kj >= topLo then EdgeTouch(s, j, hj + qj + kj) end
									end
									td[j], fed[j], lw[j] = 0, now, 1
									if w[j] == 0 then
										w[j] = 1
										s.wetN = s.wetN + 1
									end
									if on[j] == 0 then
										on[j] = 1
										na = na + 1
										act[na] = j
									end
									idle[j], mv[j] = 0, stepNo
								end
							else
								q = 0
							end
						end
					end
				elseif j == -1 then
					-- an edge of the mesh with nothing across it: the surface is taken to go on as it
					-- came (by the cell on the other side of this one), and what crosses is off the body
					local o
					if d == 0 then o = nb2[c] elseif d == 1 then o = nb1[c] elseif d == 2 then o = nb4[c] else o = nb3[c] end
					local dh = hu * 0.5
					if o > 0 then
						if hs[o] ~= stamp then Height(s, o) end
						dh = dh + zt[o] - zt[c]
					end
					-- (an edge holds a layer back as the rim of anything does: what leaves is what
					-- stands above that. Blood that comes down to a hem or a cuff gathers along it,
					-- and drops from where it has gathered: before, a run went over an edge as if
					-- the surface went on, in one place, at the run's own width)
					local he = hu - EDGE
					if dh > 0 and he > 0 then
						q = kq * dh * he * he * he / (mu[c] * cf[c])
						local lim = (he < dh and he or dh) * LIM
						if q > lim then q = lim end
						if q > QEPS then
							h[c] = h[c] - q
							if d < 2 then fx[c] = fx[c] + (d == 0 and -q or q) else fy[c] = fy[c] + (d == 2 and -q or q) end
							out[c] = (out[c] or 0) + q * a2 * ML
							if pend then PendTouch(s, c, q * a2 * ML) end
							if not outT[c] then outT[c] = now end
							if trk then local r = rid[c] or 0 trk.eout[r] = (trk.eout[r] or 0) + q * a2 * ML end
						else
							q = 0
						end
					end
				end
				if q > 0 then
					moved = moved + q * a2
					mv[c] = stepNo
					-- (the shear of this move: 3 u / h with u = q a / (h dt))
					local sr = kS * q / (hu * hu)
					if sr > gn[c] then gn[c] = sr end
					hu = h[c] - rs[c]
					if hu <= 0 then break end
				end
			end
		end
	end
	s.na = na
	prof.looked, prof.moved = prof.looked + looked, prof.moved + moved
	return moved
end

-- After the faces: blood that moved is thinner for a while, a place holds only so much, and cells
-- that hold no more than their residual film are no longer stepped.
local function Settle(s, dt)
	local h, rs, mu, sh, gn, nz, mv, idle, on, ar = s.h, s.rs, s.mu, s.sh, s.gn, s.nz, s.mv, s.idle, s.on, s.ar
	local act, out, outT = s.act, s.out, s.outT
	local stepNo, now = s.stepNo, s.now
	local kr = min(1, dt / KF.shearTau)
	local hold, holdUp, holdDown, rate = K.hold, K.holdUp, K.holdDown, K.shedRate
	local pt, paintSteps = s.pt, s.qn > K.paintBusy and K.paintSteps * 2 or K.paintSteps
	local fx, fy, dx, dy, sp, wp = s.fx, s.fy, s.dx, s.dy, s.sp, s.wp
	local ks, kd = min(1, dt / K.speedTau), min(1, dt / K.dirTau)
	-- (phase 19: painted again by what has changed on it, Changed; what waits to drop, PendTouch)
	local byChange, edge, pend, gel = s.v19c, s.v19e, s.v19p, s.k
	local v19 = byChange or edge
	local lp, lt
	if v19 then lp, lt = LastPainted(s) end
	local keep = 0
	for ii = 1, s.na do
		local c = act[ii]
		local sv, t = sh[c], gn[c]
		if t > 0 or sv > 0 then
			sv = sv + (t - sv) * kr
			if sv < SH_REST then
				sh[c], mu[c] = 0, MU0
			else
				sh[c] = sv
				mu[c] = 1 + 15.23 * (1 + 10.976 * sv * sv) ^ -0.3216
			end
			gn[c] = 0
		end
		local hh = h[c]
		-- what stands there at the most, by how the place faces
		local up = nz[c]
		local cap
		if up > 0 then cap = hold + (holdUp - hold) * (up < 0.6 and up / 0.6 or 1) else cap = hold + (holdDown - hold) * (up > -0.35 and -up / 0.35 or 1) end
		if hh > cap then
			local x = (hh - cap) * rate
			hh = hh - x
			h[c] = hh
			out[c] = (out[c] or 0) + x * ar[c] * ML
			if pend then PendTouch(s, c, x * ar[c] * ML) end
			if not outT[c] then outT[c] = now end
			mv[c] = stepNo
			local trk = s.trk
			if trk then local r = s.rid[c] or 0 trk.eout[r] = (trk.eout[r] or 0) + x * ar[c] * ML end
		end
		-- Which way blood crossed it in this step and how fast (cells a second: the share of its layer
		-- that went on to the next place): both follow over a moment, and a place blood no longer
		-- crosses keeps its direction (the streaks stay as they were laid) and loses its speed.
		local ax, ay = fx[c], fy[c]
		if ax ~= 0 or ay ~= 0 then
			fx[c], fy[c] = 0, 0
			local f = sqrt(ax * ax + ay * ay)
			sp[c] = sp[c] + (0.5 * f / ((hh + f) * dt) - sp[c]) * ks
			dx[c] = dx[c] + (ax / f - dx[c]) * kd
			dy[c] = dy[c] + (ay / f - dy[c]) * kd
		elseif sp[c] > 0 then
			local v = sp[c] * (1 - ks)
			sp[c] = v > 0.02 and v or 0
		end
		-- (the waves on it travel with what runs there, at its own pace, and stand where it stands:
		-- cl_filmdraw.lua, Wave)
		if sp[c] > 0 then wp[c] = wp[c] + sp[c] * dt end
		if mv[c] == stepNo then
			idle[c] = 0
			-- (what is shown of a place where blood runs changes a little at every step: it is
			-- painted again every second or so, less often the more of the film waits to be
			-- painted, and before anything else when blood has only just come to it)
			local last = pt[c]
			if last == 0 then
				pt[c] = stepNo
				Touch(s, c, true)
			elseif stepNo - last >= paintSteps then
				pt[c] = stepNo
				Touch(s, c)
			end
		else
			idle[c] = idle[c] + 1
		end
		if hh > rs[c] then
			keep = keep + 1
			act[keep] = c
		else
			on[c] = 0
			sh[c], mu[c] = 0, MU0
			-- (nothing runs on it any more: its waves are gone, and it is shown without them)
			if sp[c] > 0 then
				sp[c] = 0
				Touch(s, c)
			end
		end
		-- (phase 19: and when what stands on it has changed by more than shows. The clock above stays
		-- for what changes by less, counted from the last time it was asked for either way.)
		if v19 and Changed(s, c, hh + gel[c], byChange, edge, lp, lt) and pt[c] ~= 0 then pt[c] = stepNo end
	end
	for ii = keep + 1, s.na do act[ii] = nil end
	s.na = keep
end

------------------------------------------------------------------------------------------
-- Time: soaking in, creeping through cloth, setting, drying
------------------------------------------------------------------------------------------
-- Blood in the cloth of cell c creeps on into the drier cloth of cell j, and more of it downhill.
-- la: how far apart the two are; k: how readily across what they share (1: a side, 0.5: a corner);
-- cap: what c's cloth holds; from: how full it has to stay. True when some did.
local function Wick(s, c, j, k, la, cap, from, now, dt)
	local ab, abc = s.ab, s.abc
	local full = ab[c] / cap
	local fj = ab[j] / abc[j]
	if fj >= full then return false end
	-- Blood creeps only so far through cloth from where liquid stands on it, and slower the further
	-- it has come: a band along a stream, wider here and narrower there as the cloth is, not a
	-- patch that goes on growing for as long as the wound gives.
	-- (a hem, a cuff, a collar: the cloth is doubled there and draws blood along itself, whatever the
	-- cloth above it does: s.hemK, AgeCell)
	local reach = s.wr[j]
	local hk = s.hemK
	if hk > 1 then
		if reach < K.wickReach then reach = K.wickReach end
		reach = reach * hk
	end
	-- How far it creeps grows with the time liquid has stood at the place it comes from, as a front
	-- in cloth does: by the root of that time, up to a few times the first reach (s.growK: AgeCell
	-- works it out once for the place blood creeps from). A wound that goes on bleeding goes on
	-- soaking what its blood runs over, and the stain round a run is wider after a minute than
	-- after ten seconds. (With one reach for good, a body's blood looked the same after fifteen
	-- seconds and after a hundred and fifty: a run with a narrow margin, and all the rest of what
	-- the wound gave on the ground. Measured: scene cont_long, run fl1_diag.) Cloth only: skin
	-- holds what its furrows hold, and that does not travel.
	if s.sk[j] == 0 then reach = reach * s.growK end
	local step = k == 1 and 1 or 1.4142
	local far = s.wg[c] + step
	if far > reach then return false end
	-- (uphill a front in cloth comes less far than sideways or down: every place it climbs counts for
	-- more of its reach. As far up as down, the stain of a wound that went on bleeding stood a
	-- hand's width above the wound after two minutes: measured on the bench, case st2.)
	if s.hs[j] ~= s.stamp then Height(s, j) end
	local g = (s.zt[c] - s.zt[j]) / la
	g = g > 1 and 1 or (g < -1 and -1 or g)
	if g < 0 then
		far = s.wg[c] + step * (1 - K.wickUp * g)
		if far > reach then return false end
	end
	local t0 = s.ws[c]
	local rate = K.wickRate * s.wk[j] * (1 + K.wickDown * g) * dt * 2 * k * (1 - far / reach)
	-- (round the wound faster, AgeCell's s.rateK: by no more than a quarter of the difference across
	-- a side in a turn, or the two would swap which is the fuller)
	local rk = s.rateK
	if rk > 1 then
		local r2 = rate * rk
		if r2 > 0.25 then r2 = rate > 0.25 and rate or 0.25 end
		rate = r2
	end
	local x = (full - fj) * rate * cap
	local spare = ab[c] - from * cap
	if x > spare then x = spare end
	if x <= 1e-7 then return false end
	local xj = x * s.ar[c] / s.ar[j]
	if ab[j] + xj > abc[j] then
		xj = abc[j] - ab[j]
		x = xj * s.ar[j] / s.ar[c]
	end
	-- (While blood is only coming into it, it is painted as it fills, the patch's edge moves: at
	-- every twelfth of what it holds, up to where it counts as covered and a little beyond. At
	-- every coming, as it was, the front of a stain that crept for minutes asked for a painting
	-- twice a second for each of its places: painting cost half again as much as the film's own
	-- steps. Measured: scene cont_long, run fl3_second.)
	local a0 = ab[j]
	if a0 <= 0 then
		Touch(s, j, s.w[j] == 0)
	else
		local cj = abc[j]
		if a0 < cj * 0.6 and floor((a0 + xj) / cj * 12) ~= floor(a0 / cj * 12) then Touch(s, j) end
	end
	-- (how far its blood has come: by the shortest way it came, and from where; and since when liquid
	-- has stood where it came from: the earliest of the places it has it from)
	if ab[j] <= 0 or far < s.wg[j] then
		s.wg[j] = far
		s.wo[j] = s.wo[c]
	end
	if t0 > 0 and (s.ws[j] == 0 or t0 < s.ws[j]) then s.ws[j] = t0 end
	ab[c], ab[j] = ab[c] - x, ab[j] + xj
	s.fed[j] = now
	-- (what it has been given it may pass on in its turn)
	s.wi[j] = 0
	if s.w[j] == 0 then
		s.w[j] = 1
		s.wetN = s.wetN + 1
	end
	return true
end

-- (the four cells across a cell's corners: one step along the grid's x, then one along its y)
local DIAG1, DIAG2 = { 1, 1, 2, 2 }, { 3, 4, 3, 4 }

-- dt seconds have passed for cell c. Returns what dried and what the cloth took up (ml).
local function AgeCell(s, c, now, dt, e0, clotT)
	local h, k, sd, ab, abc = s.h, s.k, s.sd, s.ab, s.abc
	local hh, kk = h[c], k[c]
	local T = hh + kk
	local vol = s.ar[c] * ML
	local dried, soaked = 0, 0
	local changed = false
	-- (wet blood has only just come to it, or the last of its wet blood dries in this turn: what is
	-- shown of it changes now. Cloth that holds only a trace it has drawn in from beside it is no
	-- such place: its outline moves as slowly as the blood creeps, and it is painted as that
	-- comes, Wick. Counted in, every place along the front of a stain asked to be painted before
	-- anything else at each of its turns, for as long as the front crept.)
	local fresh = T > 0 and T + sd[c] + ab[c] < K.showMin * 3
	if T > 0 then
		-- (wet blood stands on it: whatever its cloth holds, from here blood creeps on, and has since
		-- it first stood here)
		s.wg[c] = 0
		s.wo[c] = c
		if s.ws[c] == 0 then s.ws[c] = now end
		-- the cloth drinks
		local room = abc[c] - ab[c]
		if room > 1e-7 then
			local x = room * min(1, dt / K.soakTau)
			if x > T then x = T end
			local f = 1 - x / T
			hh, kk, T = hh * f, kk * f, T - x
			ab[c] = ab[c] + x
			soaked = x * vol
		end
		-- blood that has been out of the vessel for the clotting time sets
		if hh > 0 then
			local cc = (now - s.tb[c]) / clotT
			if cc >= 1 then
				local x = hh * min(1, dt / GEL_TAU)
				if hh - x < s.rs[c] * 0.25 then x = hh end
				hh, kk = hh - x, kk + x
				s.cf[c] = 1e4
			else
				s.cf[c] = ClotF(cc)
			end
		end
		-- and it dries from its surface: faster the more of the cells around it hold no wet blood
		local nd = 0
		for d = 1, 4 do
			local j = s[NB[d]][c]
			if j <= 0 or h[j] + k[j] <= 0 then nd = nd + 1 end
		end
		local e = e0 * (1 + K.dryEdge * nd)
		if e >= T then
			sd[c] = sd[c] + T
			dried = T * vol
			hh, kk, T = 0, 0, 0
			s.td[c] = now
			fresh = true
		elseif e > 0 then
			local f = 1 - e / T
			sd[c] = sd[c] + e
			dried = e * vol
			hh, kk, T = hh * f, kk * f, T - e
		end
		h[c], k[c] = hh, kk
		s.zf[c] = s.zt[c] + kk + sd[c] * DEPK
		if T > 0 then s.fed[c] = now end
		changed = true
	end
	-- Blood creeps on through cloth that is more than half full, to drier cloth beside it, and more
	-- of it downhill. What has soaked in is in the books as taken up: this only moves it.
	local cap = abc[c]
	local from = s.sk[c] == 1 and K.wickFromSkin or K.wickFrom
	local wi = s.wi
	-- (cloth that has just drunk has something to pass on again)
	if soaked > 0 then wi[c] = 0 end
	-- Cloth that found none of the cloth round it drier at its last two looks is asked only now and
	-- then: the inside of a soaked patch has nowhere to pass blood on to, and most of a patch is inside.
	-- (Blood that has been in the cloth for a while without more coming has set there, and creeps
	-- no further: K.wickWet.)
	if cap > 0 and ab[c] > from * cap and (wi[c] < 2 or (s.ageRound + c) % 4 == 0) and now - s.fed[c] <= s.wetStop then
		if s.hs[c] ~= s.stamp then Height(s, c) end
		local la = sqrt(s.ar[c])
		local any = false
		-- (how many times its first reach the blood from here has by now: by the root of the time
		-- liquid has stood where it comes from, Wick)
		local gk = 1
		local t0 = s.ws[c]
		if t0 > 0 and K.wickGrow > 0 and now > t0 then
			gk = 1 + K.wickGrow * sqrt((now - t0) / K.wickGrowTau)
			if gk > K.wickGrowMax then gk = K.wickGrowMax end
		end
		-- (Phase 19, reachRun: and by how far the blood that feeds it had run from the wound, ds of the
		-- place it comes from, s.wo. The cloth further down a run has more soaked cloth above it that
		-- drains into it, and the cloth round the opening has drunk from it from the first: the stain
		-- is fuller round the wound and widens down the run, one shape with it. Not known where it
		-- comes from: as before. Advance reads the numbers, C.V19. With reachRunGrow 0.9 over 30 cells
		-- and reachNear 1.0 over 8, on a standing chest wound at 40 s the stain grew wider down the run
		-- by 0.3 to 1.4 cells every ten rows, where it had by -1.3 to 0.7, and the six rows below the
		-- wound were two cells wider than with reachNear 0; the stain painted was 14 to 43 % larger
		-- than before (lying, case su2: 2 to 3 %; a forearm: 26 to 37 %). Round the wound the reach
		-- holds little back: reachNear 3 gave another 1.5 to 2 cells, how fast the cloth passes blood
		-- on holds the rest. Measured on the bench, 2026-10-17.)
		local rk = 1
		if s.v19rr then
			local o = s.wo[c]
			if o > 0 then
				local d = s.ds[o]
				local near = exp(-d * s.rrNearK)
				gk = gk * (1 + s.rrGrow * (1 - exp(-d * s.rrK)) + s.rrNear * near)
				-- (and round the wound the cloth is given blood faster: blood that comes out of a wound
				-- under clothing spreads between the skin and the cloth and is drunk by the cloth over
				-- all of that, not only through the hole the film is fed at. reachNearRate 0: as before.)
				rk = 1 + s.rrNearRate * near
			end
		end
		s.growK, s.rateK = gk, rk
		-- (is it at an edge of the surface, or at a gap between two pieces of clothing: a hem, a cuff,
		-- a collar? From there blood creeps further, and so along the edge: the places beside it are
		-- at the edge too)
		local hem = false
		for d = 1, 4 do
			local j = s[NB[d]][c]
			if j == 0 then j = Neighbour(s, c, d) end
			if j == -1 then hem = true end
		end
		if not hem and band(s.gp[c], 15) ~= 0 then hem = true end
		s.hemK = (hem and s.sk[c] == 0) and K.hemReach or 1
		for d = 1, 4 do
			local j = s[NB[d]][c]
			if j > 0 and abc[j] > 0 and Wick(s, c, j, 1, la, cap, from, now, dt) then any = true end
		end
		-- (and across its corners: with the sides alone a patch grows as a diamond on the grid)
		local ld = la * 1.4142
		for d = 1, 4 do
			local i1 = s[NB[DIAG1[d]]][c]
			if i1 > 0 then
				local d2 = DIAG2[d]
				local j = s[NB[d2]][i1]
				if j == 0 then j = Neighbour(s, i1, d2) end
				if j > 0 and j ~= c and abc[j] > 0 and Wick(s, c, j, 0.5, ld, cap, from, now, dt) then any = true end
			end
		end
		if any then
			wi[c] = 0
			changed = true
		else
			wi[c] = wi[c] + 1
		end
	end
	-- What is shown of it changes as it dries and soaks, with or without anything moving, but
	-- slowly: it is painted again every few of its turns (half as often while much of the film
	-- waits to be painted).
	local live = changed or now - s.fed[c] < K.wetTime * 3
	if live then
		if fresh then
			Touch(s, c, true)
		elseif (s.ageRound + c) % (s.qn > K.paintBusy and K.paintTurns * 2 or K.paintTurns) == 0 then
			Touch(s, c)
		end
	end
	-- (phase 19: and when it has dried or soaked by more than shows since it was last asked for, or
	-- its liquid has gone, Changed)
	if changed and (s.v19c or s.v19e) then
		local lp, lt = LastPainted(s)
		Changed(s, c, h[c] + k[c], s.v19c, s.v19e, lp, lt)
	end
	return dried, soaked, live
end

-- A slice of the body's cells is aged at every step, so that each cell's turn comes every half
-- second and no step ages them all.
local SLICES = 10
local function Age(s, now)
	local n = s.n
	if n == 0 then return end
	local dry = C.sv.drying:GetFloat()
	local dt = K.step * SLICES
	-- (how long blood in cloth goes on creeping after the last of it came: Wick)
	s.wetStop = K.wickWet * dry
	local e0 = K.dryRate / dry * dt
	local clotT = KF.clotTime * dry
	local count = math.ceil(n / SLICES)
	local c = s.agePos
	local w, h, k, ab, ar, fed, tt = s.w, s.h, s.k, s.ab, s.ar, s.fed, s.tt
	local tbone, wacc = s.m.tb, s.wacc
	local wetT = K.wetTime * dry
	-- (a place with nothing wet on it whose blood came last longer ago than any of these: AgeCell
	-- would find nothing to do there, and it is not asked)
	local settled = max(K.wetTime * 3, s.wetStop, wetT)
	local dried, soaked = 0, 0
	for _ = 1, count do
		if c > n then
			-- (once round all cells: was anything of it still wet, or still changing as it dries?)
			c = 1
			s.rest = not s.live
			s.live = false
			s.ageRound = s.ageRound + 1
			-- How wet each part of the body is (ml of wet blood on it): what it leaves on what it
			-- touches goes by that (cl_transfer.lua).
			local wet = s.src.wet
			for bone, v in pairs(wacc) do
				if v > (wet[bone] or 0) then wet[bone] = v < 4 and v or 4 end
				wacc[bone] = nil
			end
		end
		if w[c] ~= 0 and (h[c] + k[c] > 0 or now - fed[c] <= settled) then
			local d, so, live = AgeCell(s, c, now, dt, e0, clotT)
			dried, soaked = dried + d, soaked + so
			local trk = s.trk
			if trk and (d > 0 or so > 0) then
				local r = s.rid[c] or 0
				trk.dry[r], trk.soak[r] = (trk.dry[r] or 0) + d, (trk.soak[r] or 0) + so
			end
			if live then s.live = true end
			local T = h[c] + k[c]
			if now - fed[c] < wetT then T = T + ab[c] * 0.5 end
			if T > 0 then
				local bone = tbone[tt[c]]
				wacc[bone] = (wacc[bone] or 0) + T * ar[c] * ML
			end
		end
		c = c + 1
	end
	s.agePos = c
	if dried > 0 then
		FC.Move("surface", "dried", dried)
		s.bk.surface, s.bk.dried = s.bk.surface - dried, s.bk.dried + dried
	end
	if soaked > 0 then
		FC.Move("surface", "absorbed", soaked)
		s.bk.surface, s.bk.absorbed = s.bk.surface - soaked, s.bk.absorbed + soaked
	end
	prof.aged = prof.aged + count
end

------------------------------------------------------------------------------------------
-- Leaving the body
------------------------------------------------------------------------------------------
-- vol (ml) leaves the body at cell c: into the pool under a body that lies in its blood, else as a
-- drop that falls from there.
-- Returns true when it did not leave yet (no trace was to be had to know whether the place touches
-- the floor: it waits for the next step).
local function Leave(s, c, vol)
	F = F or ABL.Flow
	Drops = Drops or ABL.Drops
	WS = WS or ABL.Wounds
	local src = s.src
	local pose = src.pose
	local t = s.tt[c]
	local px, py, pz, nx, ny, nz = pose:Point(t, s.bu[c], s.bv[c])
	if not ABL.InWorld(px, py, pz) then
		s.bk.surface, s.bk.left = s.bk.surface - vol, s.bk.left + vol
		prof.left = prof.left + vol
		FC.Move("surface", "lost", vol)
		return
	end
	local seeped, busy = F.GroundSeep(vol, px, py, pz, nx, ny, nz, src.key)
	-- (No trace left in this frame: whether this place touches the floor is asked at the next step.
	-- Let go as a drop, blood on the underside of a body lying on the floor started inside the floor
	-- and was written off: 1.5 of 268 ml in run p18f, scene acc_long, all of it at cl_droplets.lua,
	-- "emitted inside solid", on frames where the shared trace budget had run out.)
	if busy then return true end
	s.bk.surface, s.bk.left = s.bk.surface - vol, s.bk.left + vol
	prof.left = prof.left + vol
	if seeped then
		FC.Move("surface", "pool", vol)
		-- (what leaves where, for the developer's view of what gathers where: cl_accum.lua)
		if FM.onEvent then FM.onEvent("seep", px, py, pz, vol, s) end
		return
	end
	local bvx, bvy, bvz = pose:BoneVel(s.m.tb[t])
	-- (Phase 19, pendSpawn: the drop starts where it was seen to hang from the body before it let go,
	-- with that place's velocity: cl_filmpendant.lua, which knows where it drew it. Where it knows
	-- nothing of it, from the place as before. It appeared about a centimetre off the end of a run.)
	local d, hung = nil, false
	local FP = C.V19On("pendSpawn") and ABL.FilmPendant
	if FP and FP.SpawnAt then
		local ok, x, y, z, vx, vy, vz = pcall(FP.SpawnAt, s, c, vol, px, py, pz, nx, ny, nz, bvx, bvy, bvz)
		if ok then
			if x and y and z and vx and vy and vz and ABL.InWorld(x, y, z) and ABL.Finite3(vx, vy, vz) then
				d = Drops.Spawn(x, y, z, vx, vy, vz, vol, src, 0, 0, "surface", src.key)
				hung = true
			end
		elseif not FM.spawnErr then
			-- (a fault there is said once; the drop leaves from the place, as before)
			FM.spawnErr = true
			local say = ErrorNoHalt or print
			say("[AdvancedBlood] FilmPendant.SpawnAt: " .. tostring(x) .. "\n")
		end
	end
	if not hung then
		local lag = min(FrameTime(), 0.05)
		local gx, gy, gz, gmag = ABL.Gravity()
		-- (it leaves off the surface and a little below the point: clear of the body it runs down)
		local ox, oy, oz = nx * 0.3 + gx / gmag * 0.3, ny * 0.3 + gy / gmag * 0.3, nz * 0.3 + gz / gmag * 0.3
		d = Drops.Spawn(px + ox + bvx * lag, py + oy + bvy * lag, pz + oz + bvz * lag, bvx + nx * 2, bvy + ny * 2, bvz + nz * 2, vol, src, 0, 0, "surface", src.key)
	end
	-- (drops that leave one place in quick succession are one stream: cl_droplets.lua draws them so)
	Drops.Link(d, s, c)
	WS.Ledger(src, "offBody", vol)
	if FM.onEvent then FM.onEvent("drop", px, py, pz, vol, s) end
end

-- What has left its cells is still on the body until it has gathered into a drop (or has waited
-- long enough for one, however small).
local function Drip(s, now)
	local out, outT = s.out, s.outT
	local rng = s.src.rng
	-- (when much leaves at once it leaves as larger drops, not as more of them: about K.dropRate a
	-- second from one body, as far as their size can make up for it)
	local big = s.dropBig or 1
	local left = 0
	local least = K.dropVol * K.dropLeast
	local waitAgain
	for c, v in pairs(out) do
		local waited = now - (outT[c] or now)
		if v >= K.dropVol * (s.dropK or 1) * big or (waited > K.dropWait and v >= least) then
			local t0 = outT[c]
			out[c], outT[c] = nil, nil
			if Leave(s, c, v) then
				-- (it waits for the next step: put back after this loop, not while it runs)
				waitAgain = waitAgain or {}
				waitAgain[#waitAgain + 1] = { c, v, t0 }
			else
				s.dropK = rng:Range(0.75, 1.3)
				left = left + 1
				-- (phase 19: the swelling it made in the film goes with it, at once: pendPaint)
				if s.v19p then Touch(s, c, true) end
			end
			-- (a few a step: the rest waits, and grows)
			if left >= 5 then break end
		elseif waited > K.dropWait * 3 then
			-- (too little for a drop of its own, and no more has come: it stays on the body)
			out[c], outT[c] = nil, nil
			s.h[c] = s.h[c] + v / (s.ar[c] * ML)
			Wake(s, c)
			if s.v19p then Touch(s, c, true) end
			local trk = s.trk
			if trk then local r = s.rid[c] or 0 trk.ein[r] = (trk.ein[r] or 0) + v end
		end
	end
	if waitAgain then
		for i = 1, #waitAgain do
			local e = waitAgain[i]
			out[e[1]] = (out[e[1]] or 0) + e[2]
			if not outT[e[1]] then outT[e[1]] = e[3] or now end
		end
	end
	s.dropN = (s.dropN or 0) + left
	local t0 = s.dropT0
	if not t0 or now - t0 > 3 then
		s.dropT0, s.dropN = now, 0
	elseif now - t0 >= 0.5 then
		local want = big * s.dropN / (now - t0) / K.dropRate
		if want < 1 then want = 1 elseif want > K.dropBigMax then want = K.dropBigMax end
		s.dropBig = big + (want - big) * 0.5
		s.dropT0, s.dropN = now, 0
	end
end

------------------------------------------------------------------------------------------
-- Step
------------------------------------------------------------------------------------------
-- One body's film up to the game's time `now`: whole steps on a grid of that time (every K.step from
-- zero, whatever the frames are), at most maxSteps of them. A body that could not be stepped for a
-- while goes on from now: it does not catch up in a burst. Returns the steps run.
local function Advance(s, now, maxSteps)
	local STEP = K.step
	local tS = s.tS
	-- Nothing runs, nothing arrives, nothing is on its way off, and the last look at all its cells
	-- found none that is still wet or still changing: the film is at rest and costs nothing.
	if s.rest and s.na == 0 and #s.feeds == 0 and next(s.out) == nil then
		s.tS = nil
		return 0
	end
	if not tS or now - tS > STEP * 6 then tS = (floor(now / STEP) - 1) * STEP end
	if tS + STEP > now then return 0 end
	local src = s.src
	local gx, gy, gz, gmag = ABL.Gravity()
	s.ux, s.uy, s.uz = -gx / gmag, -gy / gmag, -gz / gmag
	s.full = false
	-- (which parts of phase 19 are on, read once a frame for all its steps: sh_config.lua, C.V19)
	local wasC, wasE = s.v19c, s.v19e
	s.v19c, s.v19e = C.V19On("touchByChange"), C.V19On("touchLiquidEdge")
	s.v19p, s.v19w = C.V19On("pendPaint"), C.V19On("fullIsWall")
	-- (how far blood creeps through cloth: the reach a new cell is given, CellAt, and how it grows
	-- along a run, AgeCell. A length of 0 or less turns its part off.)
	s.v19rf, s.v19rr = C.V19On("reachField"), C.V19On("reachRun")
	Origins(s)
	if s.v19rr then
		local V = C.V19
		local len, near = V.reachRunLen or 30, V.reachNearLen or 6
		s.rrGrow, s.rrK = len > 0 and (V.reachRunGrow or 0.9) or 0, len > 0 and 1 / len or 0
		s.rrNear, s.rrNearK = near > 0 and (V.reachNear or 0.8) or 0, near > 0 and 1 / near or 0
		s.rrNearRate = near > 0 and (V.reachNearRate or 0) or 0
	end
	-- (the line liquid follows down the floor, Flow: what s.dv holds is from while it was on. Just
	-- switched on, or a film made before it was kept: none yet, and the liquid on it starts a line
	-- of its own where it stands)
	local wasS = s.v19st
	s.v19st = C.V19On("steer")
	-- (and whether the folds of cells made from now on wander as they hang, CellAt)
	s.v19fw = C.V19On("foldWarp")
	if s.v19st then
		if not s.dv or wasS == false then s.dv = {} end
		local V = C.V19
		s.stMin, s.stW = V.steerMin or 0.25, V.steerHalf or 0.75
	end
	-- (a part that asks by what was last painted has just been switched on: what lp/lt hold is from
	-- before, forget it)
	if (s.v19c and wasC == false) or (s.v19e and wasE == false) then s.lp, s.lt = nil, nil end
	-- The body's pose is what it was drawn in last: one reading serves all steps of this frame. (A
	-- body that lies still is read every few frames.)
	s.turn = (s.turn or 0) + 1
	local still = src.isRagdoll and IsValid(src.body) and src.body:GetVelocity():LengthSqr() < 4
	if not still or s.turn % 5 == 0 then s.stamp = s.stamp + 1 end
	local n = 0
	while tS + STEP <= now and n < maxSteps do
		tS = tS + STEP
		n = n + 1
		s.stepNo = s.stepNo + 1
		s.now = tS
		Inflow(s, tS)
		if s.na > 0 then
			Flow(s, STEP)
			Settle(s, STEP)
		end
		Age(s, tS)
	end
	s.tS = tS
	if next(s.out) ~= nil then Drip(s, now) end
	return n
end
FM.Advance = Advance

local order = {}
local function MoreUrgent(a, b) return a.fmPrio > b.fmPrio end

-- All bodies, once per frame. The most important is stepped first; the others while there is time
-- left in the films' share of the budget (their steps are made up for, up to a few).
function FM.Step()
	local now = CurTime()
	local list = ABL.Sources.list
	local n = 0
	for i = 1, #list do
		local src = list[i]
		local s = src.film
		if s then
			-- (by the body's distance alone, cl_lod.lua: a body out of view goes on as one in view)
			if L.FlowOn(src) and src.mesh == s.m and IsValid(src.body) then
				n = n + 1
				order[n] = src
				src.fmPrio = (src.importance or 0) + (now - (s.tS or now)) * 4
			end
		end
	end
	for i = n + 1, #order do order[i] = nil end
	if n == 0 then return end
	if n > 1 then table.sort(order, MoreUrgent) end
	local t0 = SysTime()
	local budget = C.cl.budget:GetFloat() * K.stepShare / 1000
	for i = 1, n do
		local src = order[i]
		prof.steps = prof.steps + Advance(src.film, now, K.maxSteps)
		if SysTime() - t0 > budget then break end
	end
	prof.step = prof.step + (SysTime() - t0) * 1000
end

-- An impulse on a bone (a ragdoll hitting something): part of the liquid on that bone is flung off.
function FM.Shake(src, bone, speed, nx, ny, nz)
	local s = src.film
	if not s or s.na == 0 or speed < 120 then return end
	Drops = Drops or ABL.Drops
	WS = WS or ABL.Wounds
	local tbone = s.m.tb
	local share = min(0.6, speed / 900)
	local flung = 0
	for ii = 1, s.na do
		local c = s.act[ii]
		if tbone[s.tt[c]] == bone then
			local x = (s.h[c] - s.rs[c]) * share
			if x > 0 then
				s.h[c] = s.h[c] - x
				s.out[c] = (s.out[c] or 0) + x * s.ar[c] * ML
				s.outT[c] = -1e9
				local trk = s.trk
				if trk then local r = s.rid[c] or 0 trk.eout[r] = (trk.eout[r] or 0) + x * s.ar[c] * ML end
				Touch(s, c)
				flung = flung + 1
				if flung >= 6 then break end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- What is shown of a cell (cl_filmdraw.lua paints it)
------------------------------------------------------------------------------------------
-- Cell c at time now:
--   whether blood lies there (0 .. 1: 1 from the least that shows);
--   how full its cloth is of blood (0 .. 1; 0 on bare skin);
--   the layer standing on it that is still wet, liquid or set (units), and the layer that has dried;
--   how wet all of it still is (0 .. 1: liquid on it, or cloth that was soaked a moment ago).
function FM.Look(s, c, now)
	local dw = s.h[c] + s.k[c]
	local dd = s.sd[c]
	local soak = s.ab[c]
	local T = dw + dd + soak
	if T <= 0 then return 0, 0, 0, 0, 0 end
	local cap = s.abc[c]
	-- (Cloth no blood has stood on, that has only drawn some in from beside it, is covered by as
	-- much as it has drawn in: the rim of a soaked patch lies where the cloth is half way to
	-- being full of it, and moves on through a cell as blood creeps on, where it stood at the far
	-- side of every cell that held a trace: a rim that kept to the grid and went on a cell at a
	-- time.)
	local ref = K.showMin
	if dw <= 0 and dd <= 0 and cap * K.coverSoak > ref then ref = cap * K.coverSoak end
	local cov = T < ref and T / ref or 1
	local sat = cap > 0 and soak / cap or 0
	if sat > 1 then sat = 1 end
	-- wet: by the liquid on it, and for a while after by the blood in the cloth
	local wet = dw / (T * 0.5)
	if wet > 1 then wet = 1 end
	if soak > 0 then
		local age = (now - s.fed[c]) / (K.wetTime * C.sv.drying:GetFloat())
		local ws = age < 0 and 1 or exp(-age)
		if ws > wet then wet = ws end
	end
	return cov, sat, dw, dd, wet
end

------------------------------------------------------------------------------------------
-- Measurements (developer profiler, test harness)
------------------------------------------------------------------------------------------
-- Totals over all characters: films, their cells, cells that are wet, cells that are stepped.
function FM.Counts()
	local films, cells, wet, act = 0, 0, 0, 0
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s then
			films, cells, wet, act = films + 1, cells + s.n, wet + s.wetN, act + s.na
		end
	end
	return films, cells, wet, act
end

-- The extent of one film: cells with blood, the area they cover (units^2), the widest it is across
-- and how far down it reaches from its highest cell (units, in the pose it has now), by material.
function FM.Measure(s)
	local res = { cells = 0, area = 0, liquid = 0, soaked = 0, dried = 0, maps = {} }
	local h, k, sd, ab, ar = s.h, s.k, s.sd, s.ab, s.ar
	for c = 1, s.n do
		local T = h[c] + k[c] + sd[c] + ab[c]
		if T > K.showMin then
			res.cells = res.cells + 1
			res.area = res.area + ar[c]
			res.liquid = res.liquid + (h[c] + k[c]) * ar[c] * ML
			res.soaked = res.soaked + ab[c] * ar[c] * ML
			res.dried = res.dried + sd[c] * ar[c] * ML
			local mk = s.mk[c]
			local e = res.maps[mk]
			local mp = s.ch.mats[mk]
			local x = s.ci[c] % mp.W
			local y = (s.ci[c] - x) / mp.W
			if not e then
				e = { name = mp.name, cells = 0, x0 = x, x1 = x, y0 = y, y1 = y, cell = mp.cell, rows = {} }
				res.maps[mk] = e
			end
			e.cells = e.cells + 1
			if x < e.x0 then e.x0 = x end
			if x > e.x1 then e.x1 = x end
			if y < e.y0 then e.y0 = y end
			if y > e.y1 then e.y1 = y end
			e.rows[y] = (e.rows[y] or 0) + 1
		end
	end
	-- how even its width is, row by row (a line is as wide in every row; a film is not)
	for _, e in pairs(res.maps) do
		local sum, sq, n, wmax = 0, 0, 0, 0
		for _, cnt in pairs(e.rows) do
			sum, sq, n = sum + cnt, sq + cnt * cnt, n + 1
			if cnt > wmax then wmax = cnt end
		end
		e.rowsN = n
		e.wMean = n > 0 and sum / n * e.cell or 0
		e.wSd = n > 1 and sqrt(max(sq / n - (sum / n) ^ 2, 0)) * e.cell or 0
		e.wMax = wmax * e.cell
		e.rows = nil
	end
	return res
end

function FM.Clear()
	for _, src in ipairs(ABL.Sources and ABL.Sources.list or {}) do FM.FreeSource(src) end
	FM.cells = 0
	if ABL.FilmDraw then ABL.FilmDraw.Clear() end
end

-- Developer: the flow core's streams (1) or the film again (0) for the character under the
-- crosshair, to see the two side by side (needs abl_dev 1; what is already on the body stays).
concommand.Add("abl_film_streams", function(ply, _, args)
	if not C.sv.dev:GetBool() then print("abl_film_streams requires abl_dev 1") return end
	local ent = ply:GetEyeTrace().Entity
	local owner = IsValid(ent) and ABL.ZC.GetOwner(ent)
	if IsValid(owner) then ent = owner end
	if not IsValid(ent) then ent = ply end
	ent.ablNoFilm = args[1] ~= "0" and true or nil
	print("new blood on " .. tostring(ent) .. ": " .. (ent.ablNoFilm and "streams of the flow core" or "film"))
end)
