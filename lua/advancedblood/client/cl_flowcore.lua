-- Flow core: blood on a surface as a liquid with a state, and the books of all blood.
--
-- The older body flow (cl_bodyflow.lua) moves separate beads over the mesh, each leaving a streak
-- of fixed width. Here the liquid itself is simulated and what is drawn follows from it:
--   wound (source boundary) -> channel -> head.
-- A channel is the path a stream has taken over a surface: an ordered row of nodes. On a body a
-- node is a point of the body mesh (triangle + barycentrics, so it follows every pose); on a wall,
-- a slope or a ceiling it is a point of the world (cl_flowworld.lua finds the way there with
-- traces and hands the nodes in; the liquid in them is stepped and drawn by the same code).
-- A node holds what is there:
--   V      mobile blood (ml) in the stretch of the channel around it
--   F      the film wetting the surface under it (ml); it dries where no blood runs over it
--   S, D   blood soaked into the cloth there, and what has dried there (ml)
--   Cv     blood that has set as a clot there (ml)
--   w, h   width and height of the rivulet's cross-section (units)
--   age    how long the blood there has been out of the vessel (it travels with the blood)
--   T      how much warmer than the surface the blood there still is (it travels with the blood)
--   sh     the shear rate it has lately flowed at: blood thins under shear, and remembers
-- Every step blood moves between neighbouring nodes by the thin-film (lubrication) law
--   u = k g h^2 / mu * (gravity along the channel + the fall of the film's own height, where gravity
--       presses it onto the surface),
-- taken from the upstream node and limited to what that node holds, so transport neither makes nor
-- loses blood. mu is the effective viscosity: shear thinning (Carreau), cooling, clotting.
-- The head is the front of the stream: a bead that stays where it is until its weight along the
-- surface beats the adhesion of the contact line, then runs, laying down new nodes, wetting the
-- surface (film) and shrinking until the channel behind it has caught up. Where a head meets
-- another channel the two join and their flows add; at edges and on undersides it hangs and drips.
-- A channel can split: where gravity has turned against the path it took (the body moved), where a
-- fast stream overshoots a bend, where blood gathers on a level patch. A branch draws its share of
-- the flow from the node it left (parentCh, parentIdx, share), so splitting neither makes nor
-- loses blood either.
--
-- One manager steps everything (FC.Step for bodies, called from the simulation loop; the world
-- regions through FC.StepLiquid): no hook, timer or entity per stream.
--
-- This is a one-dimensional model on purpose. A body mesh has triangles of an inch or two and no
-- usable texture space of its own, so a two-dimensional film field cannot resolve a rivulet a few
-- millimetres wide; a network of channels with a cross-section can.
--
-- Books (FC.Books, millilitres): every volume of blood is in exactly one state, and every module
-- that moves blood from one state to another says so here. released = everything that has entered
-- the simulation; the states must add up to it.

ABL.NoJIT()
ABL.FlowCore = ABL.FlowCore or {}
local FC = ABL.FlowCore
local C, L, BM = ABL.Config, ABL.LOD, ABL.BodyMesh
local K, B = C.Flow, C.Body
local ML = C.ML_PER_CU
local sqrt, min, max, abs, floor, exp = math.sqrt, math.min, math.max, math.abs, math.floor, math.exp
local F, Drops, WS

FC.cv = CreateClientConVar("abl_flow_core", "1", true, false, "Body blood as a continuous liquid (1) or the older separate beads and streaks (0).", 0, 1)
FC.cvNodes = CreateClientConVar("abl_max_flow_nodes", "3200", true, false, "Hard cap: nodes of blood channels on bodies (all characters).", 200, 20000)

------------------------------------------------------------------------------------------
-- Books
------------------------------------------------------------------------------------------
local STATES = { "airborne", "surface", "pool", "absorbed", "clotted", "dried", "lost" }
FC.STATES = STATES
FC.Books = FC.Books or { released = 0, airborne = 0, surface = 0, pool = 0, absorbed = 0, clotted = 0, dried = 0, lost = 0 }
local BK = FC.Books

-- New blood entering the simulation in state `to`.
-- (the books take numbers only: one NaN booked would stay in every total for good)
function FC.Release(to, vol)
	if not (vol > -1e9 and vol < 1e9) then return end
	BK.released = BK.released + vol
	BK[to] = BK[to] + vol
end
function FC.Move(from, to, vol)
	if not (vol > -1e9 and vol < 1e9) then return end
	BK[from] = BK[from] - vol
	BK[to] = BK[to] + vol
	-- (blood written off, by the line that wrote it off, while what gathers where is measured:
	-- cl_accum.lua, FC.lostAt; read by the tests)
	if to == "lost" and FC.lostAt and vol > 0 then
		local info = debug.getinfo(2, "Sl")
		local key = info and (string.match(info.short_src or "?", "([^/\\]+)$") .. ":" .. tostring(info.currentline)) or "?"
		local e = FC.lostAt[key]
		if not e then e = { ml = 0, n = 0 } FC.lostAt[key] = e end
		e.ml, e.n = e.ml + vol, e.n + 1
	end
end
function FC.ResetBooks()
	BK.released = 0
	for i = 1, #STATES do BK[STATES[i]] = 0 end
end

-- What is booked against what is actually there. Returns the booked total error (released minus
-- the sum of the states), and per live state the booked amount minus the amount found in the
-- objects that hold it.
function FC.Audit()
	local sum = 0
	for i = 1, #STATES do sum = sum + BK[STATES[i]] end
	local air = 0
	local dl = ABL.Drops.list
	for i = 1, #dl do air = air + dl[i].vol end
	local surf = 0
	for _, src in ipairs(ABL.Sources.list) do
		for _, b in ipairs(src.blobs) do if not b.dead then surf = surf + b.vol end end
		local s = src.fc
		if s then surf = surf + FC.Held(s) end
		-- (and what is wet in the film on its surface: cl_film.lua)
		local fs = src.film
		if fs then surf = surf + ABL.Film.Held(fs) end
	end
	if ABL.Runoff.Volume then surf = surf + ABL.Runoff.Volume() end
	local pool = ABL.Pools.Volume and ABL.Pools.Volume() or 0
	return BK.released - sum, BK.airborne - air, BK.surface - surf - (FC.stainWet or 0), BK.pool - pool, air, surf, pool
end

-- Wet stains (impact stains on walls and floors, films left by rivulets on the world): one
-- aggregate volume that dries with one time constant. No stain carries its own volume.
FC.stainWet = FC.stainWet or 0
function FC.Land(vol, absorb, from)
	if not (vol > -1e9 and vol < 1e9) then return end
	local a = vol * (absorb or 0)
	from = from or "airborne"
	BK[from] = BK[from] - vol
	BK.absorbed = BK.absorbed + a
	BK.surface = BK.surface + (vol - a)
	FC.stainWet = FC.stainWet + (vol - a)
end

------------------------------------------------------------------------------------------
-- Rheology
------------------------------------------------------------------------------------------
-- Whole blood thins under shear. Carreau model with the constants of Cho and Kensey (1991):
-- mu = muInf + (mu0 - muInf) (1 + (lambda g)^2)^((n - 1) / 2), mu0 = 56 mPa s, muInf = 3.45 mPa s,
-- lambda = 3.313 s, n = 0.3568. Returned relative to muInf (the flow constant kFlow is for muInf).
local function ShearF(g)
	return 1 + 15.23 * (1 + 10.976 * g * g) ^ -0.3216
end
FC.ShearF = ShearF

-- Clotting: little change for most of the clotting time, then steeply up to a gel (c = age / time).
local function ClotF(c)
	if c <= 0 then return 1 end
	if c >= 1 then return 1e4 end
	local c2 = c * c
	return 1 + K.clotVisc * c2 * c2 * c2 / (1.02 - c)
end
FC.ClotF = ClotF

-- Height and width (units) of the liquid with cross-section a (units^2): a parabola of width
-- aspect x height, no taller than hMax while it can still widen; at the widest a stream gets on a
-- body (wCap) it stands higher instead, a bulge that runs down the stream (a bead that has joined
-- it, a surge from the wound), up to the height of a drop.
local KA = 2 / 3 * K.aspect
local HMAX, WCAP, HBEAD, WSHEET = K.hMax, K.wCap, K.hBead, K.wSheet
local function Geo(a)
	local h0 = sqrt(a / KA)
	local h = h0 / sqrt(1 + (h0 / HMAX) * (h0 / HMAX))
	local w = 1.5 * a / h
	if w > WCAP then
		w = WCAP
		h = 1.5 * a / w
		if h > HBEAD then
			h = HBEAD
			w = 1.5 * a / h
			-- (a sheet at the widest; what is held back in a fold or a hollow stands higher instead,
			-- until it runs over the rim)
			if w > WSHEET then
				w = WSHEET
				h = 1.5 * a / w
			end
		end
	end
	return h, w
end

-- What a unit length of channel holds at most (ml): a sheet as wide as a stream gets and as high as a
-- drop. More than that does not stay on a steep surface (StepChannel sheds it as drops), and the
-- wound's opening takes no more (FC.Feed).
local CAPV = 2 / 3 * WSHEET * HBEAD * ML
-- units: the stretch between two nodes of a stream on the world (laid where a trace has verified the
-- surface, cl_flowworld.lua)
local WSTEP = C.Runoff.checkDist
-- ml: what a channel holds less of than this, all in all, does not count as running (StepLiquid);
-- no less than that arriving from outside wakes it
local WAKE = 1e-4

-- Drawn width of a rivulet of simulated width w: skin and cloth spread a thin trickle wider than a
-- clean rivulet, a wide stream is drawn nearer its own width.
local GAIN_W, GAIN_ADD, GAIN_REF = K.widthWide, (K.widthGain - K.widthWide) * K.widthRef * 1.6, K.widthRef
function FC.Wide(w)
	return w * GAIN_W + GAIN_ADD * (1 - exp(-w / GAIN_REF))
end

------------------------------------------------------------------------------------------
-- Per-character state, channels, nodes
------------------------------------------------------------------------------------------
FC.nodes = FC.nodes or 0        -- nodes alive (all characters)
FC.heads = FC.heads or 0
local headPool = ABL.NewPool(function() return {} end)
-- profiling accumulators (ms / counts since the last reset; read by the test harness)
FC.prof = FC.prof or { head = 0, heads = 0, chan = 0, chans = 0, nodeSteps = 0, joins = 0, breaks = 0, branches = 0 }
local prof = FC.prof

function FC.Uses(src)
	local key = src.key
	return FC.cv:GetBool() and not (IsValid(key) and key.ablFlowLegacy)
end

local function State(src)
	local s = src.fc
	if not s then
		s = { chans = {}, cells = {}, nodes = 0, nextId = 0, acc = (src.seed % 5) * 0.001, stamp = 0,
			-- this body's own books (ml): what was fed onto it, what is still liquid on it, what it
			-- took up, what set and dried on it, and what left it again
			bk = { fed = 0, surface = 0, absorbed = 0, clotted = 0, dried = 0, left = 0 } }
		src.fc = s
	end
	return s
end
FC.State = State

-- Liquid blood a character's channels hold right now (mobile blood, heads, wet film).
function FC.Held(s)
	local t = 0
	local chans = s.chans
	for c = 1, #chans do
		local ch = chans[c]
		local V, Fm = ch.V, ch.F
		for i = 1, ch.n do t = t + V[i] + Fm[i] end
		if ch.head then t = t + ch.head.vol + ch.head.film end
	end
	return t
end

local CELL = 0.6
local function CellOf(x, y, z)
	return ((floor(x / CELL) + 32768) * 65536 + (floor(y / CELL) + 32768)) * 65536 + (floor(z / CELL) + 32768)
end

local ARRAYS = { "an", "V", "F", "S", "D", "Cv", "age", "T", "ts", "sh", "mu", "h", "w", "ph", "pw", "wmax", "wet", "fed", "us",
	"qv", "dr", "L", "Lc", "hold", "born", "ab", "tx", "ty", "tz", "dist", "gap" }

local NewChannel, AddNode, SpawnHead
function NewChannel(src, s, wd)
	s.nextId = s.nextId + 1
	local ch = { id = s.nextId, src = src, wd = wd, n = 0, t0 = CurTime(), fedT = CurTime(), lt = ABL.Sim.t, sd = 0.02,
		qTip = 0, moved = 0, idleT = 0 }
	for i = 1, #ARRAYS do ch[ARRAYS[i]] = {} end
	ch.rng = ABL.RNG(src.seed + s.nextId * 7919 + (wd and ABL.Hash(tostring(wd.id)) or 0))
	s.chans[#s.chans + 1] = ch
	return ch
end

FC.NewChannel = NewChannel

-- A new node, the end of channel ch. a: its anchor, with its position and normal in the space the
-- channel lives in (a.px .. a.nz: the bind space of a body mesh, or the world).
local function InitNode(ch, s, a, absorb, warm, now)
	local n = ch.n + 1
	ch.an[n] = a
	ch.V[n], ch.F[n], ch.S[n], ch.D[n], ch.Cv[n] = 0, 0, 0, 0, 0
	ch.age[n], ch.T[n], ch.sh[n], ch.mu[n], ch.us[n], ch.qv[n], ch.dr[n] = 0, 0, 0, 1, 0, 0, 0
	ch.h[n], ch.w[n], ch.ph[n], ch.pw[n], ch.wmax[n] = 0, 0, 0, 0, 0
	ch.wet[n], ch.fed[n], ch.L[n], ch.Lc[n], ch.hold[n], ch.born[n] = 1, now, 0, K.minCell, 0, now
	ch.gap[n] = false
	ch.ab[n], ch.ts[n] = absorb, warm
	if n > 1 then
		local p = ch.an[n - 1]
		local dx, dy, dz = a.px - p.px, a.py - p.py, a.pz - p.pz
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		if l < 1e-3 then l, dx = 1e-3, 1e-3 end
		ch.L[n - 1] = l
		ch.tx[n - 1], ch.ty[n - 1], ch.tz[n - 1] = dx / l, dy / l, dz / l
		ch.dist[n] = ch.dist[n - 1] + l
	else
		ch.dist[1] = 0
	end
	ch.tx[n], ch.ty[n], ch.tz[n] = 0, 0, 0
	ch.n = n
	ch.meshDirty = true
	local key = CellOf(a.px, a.py, a.pz)
	local l = s.cells[key]
	if not l then l = {} s.cells[key] = l end
	l[#l + 1] = ch
	l[#l + 1] = n
	s.nodes = s.nodes + 1
	FC.nodes = FC.nodes + 1
	return n
end

-- A node at (tri, u, v) of body mesh m.
function AddNode(ch, s, tri, u, v, m, now)
	local a = { tri, u, v, m }
	BM.PrepareAnchor(m, a)
	-- cloth takes blood up, bare skin does not; fresh blood is warmer than either
	local skin = F.OnSkin(ch.src, tri)
	return InitNode(ch, s, a, skin and 0 or (m.tabs[tri] or 1), skin and K.warmSkin or K.warmCloth, now)
end

-- A node at a point of the world (walls, floors, props: cl_flowworld.lua). Its anchor is the point.
FC.WORLD = FC.WORLD or { nt = math.huge, world = true }
function FC.AddWorldNode(ch, s, x, y, z, nx, ny, nz, absorb, now)
	return InitNode(ch, s, { 0, 0, 0, FC.WORLD, px = x, py = y, pz = z, nx = nx, ny = ny, nz = nz, b1 = 0, rigid = 0, ready = true }, absorb, K.warmCloth, now)
end

-- The node of another channel nearest to point p (in the channels' space) within r (own: the
-- asking channel, whose nodes do not count).
local function Near(s, px, py, pz, r, own)
	local best, bi, bd = nil, 0, r * r
	-- (a point that is nowhere has nothing near it; and the cell loops below end)
	if not ABL.InWorld(px, py, pz) then return nil, 0, bd end
	local cells = s.cells
	local x0, x1 = floor((px - r) / CELL), floor((px + r) / CELL)
	local y0, y1 = floor((py - r) / CELL), floor((py + r) / CELL)
	local z0, z1 = floor((pz - r) / CELL), floor((pz + r) / CELL)
	for gx = x0, x1 do
		for gy = y0, y1 do
			for gz = z0, z1 do
				local l = cells[((gx + 32768) * 65536 + (gy + 32768)) * 65536 + (gz + 32768)]
				if l then
					for k = 1, #l, 2 do
						local ch = l[k]
						if ch ~= own and not ch.dead then
							local a = ch.an[l[k + 1]]
							local dx, dy, dz = a.px - px, a.py - py, a.pz - pz
							local d = dx * dx + dy * dy + dz * dz
							if d < bd then best, bi, bd = ch, l[k + 1], d end
						end
					end
				end
			end
		end
	end
	return best, bi, bd
end

local function FreeHead(hd)
	if hd.dead then return end
	hd.dead = true
	local ch = hd.chan
	if ch and ch.head == hd then ch.head = nil end
	hd.chan = nil
	FC.heads = FC.heads - 1
	headPool:Put(hd)
end

FC.AddNode = AddNode

function SpawnHead(ch, tri, u, v, vol)
	local hd = headPool:Get()
	hd.dead = false
	hd.chan = ch
	hd.tri, hd.u, hd.v, hd.vol = tri, u, v, vol
	hd.vx, hd.vy, hd.vz = 0, 0, 0
	hd.age, hd.dist, hd.travel, hd.moving, hd.atEdge = 0, 0, 0, false, false
	hd.wx, hd.wy, hd.wz, hd.nx, hd.ny, hd.nz = 0, 0, 0, 0, 0, 1
	hd.ix, hd.iy, hd.iz, hd.gt, hd.pn = 0, 0, -1, 0, 0
	hd.hang, hd.hangK, hd.stuckT, hd.mz, hd.lastDrip, hd.lastSpill = 0, 0, 0, 0, 0, -1
	hd.trapT, hd.sampT, hd.sampTravel, hd.sx, hd.sy, hd.sz = 0, 0, 0, 0, 0, 0
	hd.bridgeTri, hd.bridgeT = nil, 0
	hd.film, hd.chk, hd.bage, hd.markR, hd.idle, hd.spillT = 0, 0, 0, 0, 0, 0
	hd.sdx, hd.sdy, hd.sdz, hd.freezeT = 0, 0, 0, 0
	hd.ptri, hd.pu, hd.pv = tri, u, v
	hd.lt, hd.sd = ABL.Sim.t, 0.02
	hd.pendMul = ch.rng:Range(0.85, 1.2)
	hd.rot = ch.rng:Next() * 6.2831853
	hd.placed = false
	hd.pdx = nil
	ch.clotBead = nil
	ch.head = hd
	FC.heads = FC.heads + 1
	return hd
end

FC.SpawnHead = SpawnHead

local function FreeChannel(ch, s)
	if ch.dead then return end
	ch.dead = true
	if ch.head then FreeHead(ch.head) end
	if ch.wd and ch.wd.chan == ch then ch.wd.chan = nil end
	if ch.bake and ABL.FlowDraw then ABL.FlowDraw.FreeBake(ch) end
	if ch.landed then s.landed = max((s.landed or 1) - 1, 0) end
	s.nodes = s.nodes - ch.n
	FC.nodes = FC.nodes - ch.n
end

-- The spatial index holds nodes of freed channels until it is rebuilt.
local function Reindex(s)
	local cells = {}
	s.cells = cells
	for c = 1, #s.chans do
		local ch = s.chans[c]
		for i = 1, ch.n do
			local a = ch.an[i]
			local key = CellOf(a.px, a.py, a.pz)
			local l = cells[key]
			if not l then l = {} cells[key] = l end
			l[#l + 1] = ch
			l[#l + 1] = i
		end
	end
end

-- Blood still liquid in a channel that is being dropped is written off (books).
-- What a channel's wound has given it since its last step (FC.Feed) and that has not come into
-- it yet: it is on the body all the same. Booked here when the channel goes before its next step,
-- so that what the wound released and what the books hold stay the same amount.
local function TakeInflow(ch, s)
	local v = ch.inflow
	if not v or v <= 0 then return 0 end
	ch.inflow = nil
	FC.Release("surface", v)
	s.bk.fed, s.bk.surface = s.bk.fed + v, s.bk.surface + v
	if WS then WS.Ledger(ch.src, "onBody", v) end
	return v
end

local function WriteOff(ch, s)
	local t = TakeInflow(ch, s)
	for i = 1, ch.n do t = t + ch.V[i] + ch.F[i] end
	if ch.head then t = t + ch.head.vol + ch.head.film end
	if t > 0 then
		FC.Move("surface", "lost", t)
		s.bk.surface = s.bk.surface - t
	end
end

function FC.FreeSource(src)
	local s = src.fc
	if not s then return end
	for c = #s.chans, 1, -1 do
		WriteOff(s.chans[c], s)
		FreeChannel(s.chans[c], s)
	end
	src.fc = nil
end

-- Everything on one body goes over to another source of the same character (player -> corpse).
function FC.MoveSource(from, to)
	local s = from.fc
	if not s then return end
	FC.FreeSource(to)
	for c = 1, #s.chans do s.chans[c].src = to end
	to.fc = s
	from.fc = nil
end

function FC.Active(src)
	local s = src.fc
	return s ~= nil and #s.chans > 0
end

-- What is still liquid in a channel dries where it lies (books): nothing in it will run again, or
-- the channel is being dropped.
local function Settle(ch, s)
	local V, Fm, Dr, hold = ch.V, ch.F, ch.D, ch.hold
	-- (what the wound gave last dries at the wound)
	local t = TakeInflow(ch, s)
	if t > 0 and ch.n >= 1 then Dr[1] = Dr[1] + t end
	for i = 1, ch.n do
		local v = V[i] + Fm[i]
		t = t + v
		Dr[i] = Dr[i] + v
		V[i], Fm[i], hold[i] = 0, 0, 0
	end
	local hd = ch.head
	if hd then
		t = t + hd.vol + hd.film
		hd.vol, hd.film = 0, 0
	end
	if t > 0 then
		FC.Move("surface", "dried", t)
		s.bk.surface, s.bk.dried = s.bk.surface - t, s.bk.dried + t
	end
end

-- Room for more: for another node (caps on nodes) or another channel (cap on channels). A channel
-- makes way in which nothing runs any more and into which no running stream leads: short of nodes,
-- the oldest that is dry; with too many channels, the shortest. What it still holds dries (books).
-- keep: the channel that asks (it never makes way for itself).
local roomStamp = 0
local function MakeRoom(src, s, keep)
	local cap = L.Cap(FC.cvNodes)
	local chans = s.chans
	-- (all nodes in use: before a body's own stream is refused or dropped, dry streams on the walls
	-- make way, cl_flowworld.lua)
	if FC.nodes >= cap and not src.world and ABL.FlowWorld then ABL.FlowWorld.MakeRoom(cap * 0.1) end
	local nodesFull = FC.nodes >= cap or s.nodes >= K.maxNodesSrc
	if not nodesFull and #chans < K.maxChans then return true end
	local freed = false
	for _ = 1, 4 do
		-- channels a running stream leads into, or branches from, stay
		roomStamp = roomStamp + 1
		for c = 1, #chans do
			local ch = chans[c]
			if ch.head or (ch.mobile or 0) > 1e-4 then
				if ch.joinCh then ch.joinCh.usedBy = roomStamp end
				if ch.parentCh then ch.parentCh.usedBy = roomStamp end
			end
		end
		local worst, wi, ws = nil, 0, -1e9
		for c = 1, #chans do
			local ch = chans[c]
			local hd = ch.head
			if ch ~= keep and ch.usedBy ~= roomStamp and not (hd and hd.moving) and (ch.mobile or 0) < 0.02 and not (ch.wd and ch.wd.chan == ch and not ch.done) then
				local sc
				if nodesFull then
					sc = (ch.done and 1e6 or 0) - ch.t0
				else
					sc = -ch.n - (hd and 50 or 0) + (ch.done and 0.5 or 0)
				end
				if sc > ws then worst, wi, ws = ch, c, sc end
			end
		end
		if not worst then break end
		Settle(worst, s)
		FreeChannel(worst, s)
		table.remove(chans, wi)
		freed = true
		nodesFull = FC.nodes >= cap or s.nodes >= K.maxNodesSrc
		if not nodesFull and #chans < K.maxChans then break end
	end
	if freed then
		-- (channels that joined one of them end where they are)
		for c = 1, #chans do
			local ch = chans[c]
			if ch.joinCh and ch.joinCh.dead then ch.joinCh = nil end
			if ch.parentCh and ch.parentCh.dead then ch.parentCh = nil end
		end
		Reindex(s)
	end
	return not nodesFull and #chans < K.maxChans
end

------------------------------------------------------------------------------------------
-- A small wound in its first seconds
------------------------------------------------------------------------------------------
-- A small wound does not well up as one bead. Blood stands at a few points along the cut; the beads
-- grow, touch, and become one, and that one runs. While this lasts the blood of the channel's head
-- is those beads: share[j] of it at off[j] units along the cut (ang: the cut's direction on the
-- skin, from the first edge of the wound's triangle). The head stays where it is and weighs as
-- much as its largest bead.
local function MakeCut(rng, wd)
	local n = rng:Next() < 0.45 and 2 or 3
	local len = K.cutLen + K.cutGrow * min(1, (wd.sev or 0.2) / 0.6)
	local cut = { n = n, ang = rng:Next() * 3.14159, off = {}, share = {} }
	local sum = 0
	for j = 1, n do
		cut.off[j] = ((j - 1) / (n - 1) - 0.5) * len * rng:Range(0.8, 1)
		cut.share[j] = rng:Range(0.6, 1.4)
		sum = sum + cut.share[j]
	end
	for j = 1, n do cut.share[j] = cut.share[j] / sum end
	return cut
end

-- Beads that touch become one (their blood adds, the new bead lies between them, by weight); the
-- last one settles onto the middle of the wound and is the head from then on. Returns the share
-- of the largest bead.
local function CutStep(ch, hd, dt)
	local cut = ch.cut
	local n = cut.n
	local off, share = cut.off, cut.share
	local vol = max(hd.vol, 0) / ML / 1.28
	local j = 1
	while j < n do
		local s1, s2 = share[j], share[j + 1]
		if off[j + 1] - off[j] < ((s1 * vol) ^ 0.3333 + (s2 * vol) ^ 0.3333) * 1.1 then
			off[j] = (off[j] * s1 + off[j + 1] * s2) / (s1 + s2)
			share[j] = s1 + s2
			table.remove(off, j + 1)
			table.remove(share, j + 1)
			n = n - 1
		else
			j = j + 1
		end
	end
	cut.n = n
	local big = 0
	for q = 1, n do if share[q] > big then big = share[q] end end
	if n == 1 then
		off[1] = off[1] * max(0, 1 - dt / 0.25)
		if abs(off[1]) < 0.01 then ch.cut = nil end
	end
	return big
end

------------------------------------------------------------------------------------------
-- Feeding
------------------------------------------------------------------------------------------
-- Seeped blood arriving at a wound: into the root of the wound's channel, fresh and warm.
function FC.Feed(src, wd, vol)
	if not ABL.GoodVol(vol) then return end
	F = F or ABL.Flow
	WS = WS or ABL.Wounds
	local s = State(src)
	local ch = wd.chan
	local now = CurTime()
	if not ch or ch.dead or ch.src ~= src then
		local m = src.mesh
		if not m or not wd.tri or wd.tri > m.nt or not MakeRoom(src, s) then
			-- no room: the wound drips directly instead
			wd.dripAcc = wd.dripAcc + vol
			return
		end
		ch = NewChannel(src, s, wd)
		AddNode(ch, s, wd.tri, wd.u, wd.v, m, now)
		ch.wmax[1] = 0.06
		SpawnHead(ch, wd.tri, wd.u, wd.v, 0)
		wd.chan = ch
		-- (by what the wound gives once its flow is established: every wound begins with little)
		if not wd.arterial and (wd.flowFull or wd.flow or 0) < K.cutFlow then ch.cut = MakeCut(ch.rng, wd) end
	end
	-- Cloth right at the wound takes blood up directly: a soaked patch that grows round the opening
	-- until the cloth there is full. It is drawn as part of the body's surface, like the marks of
	-- gunshot wounds (cl_woundfx.lua; a wound with such a mark has its own soaked cloth). Its state
	-- is the wound's, so it stays when the body changes (a player who falls becomes a ragdoll).
	local ab = ch.ab[1]
	if ab > 0 and not wd.mark then
		local cap = (K.woundSoak + K.woundSoakSev * min(1, (wd.sev or 0) / 2)) * ab
		local sk = wd.soak0 or 0
		if sk < cap then
			local take = vol * K.woundSoakShare * (1 - sk / cap)
			sk = sk + take
			wd.soak0 = sk
			vol = vol - take
			FC.Release("absorbed", take)
			s.bk.fed, s.bk.absorbed = s.bk.fed + take, s.bk.absorbed + take
			WS.Ledger(src, "onBody", take)
			local rec = wd.soakRec
			if not rec then
				rec = { soakOnly = true, wet = 1, clot = 0, dry = 0, bruise = 0, released = 0, soak = 0, cosI = 1 }
				wd.soakRec = rec
			end
			rec.soak, rec.fedT = sk / cap, now
			local mk = wd.soakMark
			if not mk or mk.gone or mk.m ~= src.mesh then
				wd.soakMark = ABL.WoundFX.PlaceSoak(src, wd, rec, sqrt(cap / (3.1416 * K.soakDepth * ML))) or nil
			end
		end
	end
	-- It comes into the channel with the channel's next steps (Inflow, from StepLiquid): the wound
	-- is a source that runs all the while. The wound is asked several times between two steps of the
	-- stream when frames are long; put in at once, that blood would find the opening full and pour
	-- off the body, the more the lower the frame rate.
	ch.inflow = (ch.inflow or 0) + vol
	ch.fedT = now
	-- (a wound that gives a trace does not wake a stream that has stopped: what it gives waits
	-- for the stream's next look at itself, twice a second, or until it amounts to something)
	if ch.inflow >= WAKE then ch.done, ch.idleT = false, 0 end
end

-- vol of the wound's blood into the root of its channel, fresh and warm (books: it is on the body
-- from here on).
local function Inflow(ch, s, src, pose, vol, now)
	local V = ch.V
	local v1 = V[1]
	-- The opening holds only so much. What wells out faster than the stream carries it away leaves
	-- the body right there: off a wound that faces sideways or down it pours (cl_emission.lua); on
	-- one that faces up it runs off the body to the ground under it.
	local room = CAPV * ch.Lc[1] - v1
	local wd = ch.wd
	if vol > room and wd then
		local over = room > 0 and vol - room or vol
		local _, _, _, nx, ny, nz = pose:SkinPoint(ch.an[1])
		local gx, gy, gz, gmag = ABL.Gravity()
		if -(nx * gx + ny * gy + nz * gz) > 0.5 * gmag then
			wd.deposit = wd.deposit + over
		else
			wd.pourAcc = (wd.pourAcc or 0) + over
		end
		vol = vol - over
		if vol <= 0 then return end
	end
	local tot = v1 + vol
	ch.age[1] = ch.age[1] * v1 / tot
	ch.T[1] = (ch.T[1] * v1 + ch.ts[1] * vol) / tot
	V[1] = tot
	ch.fedT = now
	FC.Release("surface", vol)
	s.bk.fed = s.bk.fed + vol
	s.bk.surface = s.bk.surface + vol
	WS.Ledger(src, "onBody", vol)
end

-- A drop that landed on its own body: into the stream it fell near, or a new head of its own if it
-- is heavy enough to run. Returns false when the body's flow does not take it: no surface there, a
-- drop too small to run on dry cloth (a spot), a stretch of stream that is full. (The caller books
-- it out of the air, and leaves a stain when this returns false.)
function FC.AddAt(src, bone, x, y, z, vol, vx, vy, vz, owner)
	F = F or ABL.Flow
	local m = src.mesh
	if not m or not ABL.GoodVol(vol) or not ABL.InWorld(x, y, z) then return false end
	local tri, u, v = BM.Anchor(src.pose, bone, x, y, z, 6)
	if not tri then return false end
	local s = State(src)
	local px, py, pz = BM.BindPoint(m, tri, u, v)
	local now = CurTime()
	local ch, i = Near(s, px, py, pz, K.landDist, nil)
	-- (a stretch that is full takes no more: there the drop is on its own)
	if ch and ch.V[i] > CAPV * ch.Lc[i] then ch = nil end
	if not ch then
		-- On dry cloth or skin a drop too small to run stays where it lands; the next one that lands
		-- there finds the place wet, and runs.
		local _, _, _, _, _, _, _, _, _, nx, ny, nz = src.pose:Tri(tri)
		local gx, gy, gz, gmag = ABL.Gravity()
		local gn = (gx * nx + gy * ny + gz * nz) / gmag
		local wet = src.wetTri[tri] or 0
		if vol ^ 0.6667 * sqrt(max(0, 1 - gn * gn)) <= B.adhesion * (wet > 0.01 and B.wetAdhesion or 1) then
			src.wetTri[tri] = min(wet + vol, 1)
			return false
		end
		-- so many streams begun by drops already: into the nearest channel, or a spot
		if (s.landed or 0) >= K.landChans or not MakeRoom(src, s) then
			ch, i = Near(s, px, py, pz, K.landFar, nil)
			if not ch or ch.V[i] > CAPV * ch.Lc[i] then return false end
		end
	end
	if ch then
		local V = ch.V
		-- (an old drop is as old as it is; it mixes with what is there)
		local tot = V[i] + vol
		ch.age[i] = ch.age[i] * V[i] / tot
		V[i] = tot
		ch.done, ch.idleT = false, 0
	else
		ch = NewChannel(src, s, nil)
		ch.landed = true
		-- (whose blood began this stream: what drips off it makes that character's pool)
		ch.owner = owner
		s.landed = (s.landed or 0) + 1
		AddNode(ch, s, tri, u, v, m, now)
		local hd = SpawnHead(ch, tri, u, v, vol)
		-- (a little of the drop's speed along the surface, and never more than a stream runs at:
		-- a jet at two hundred units a second used to start its stream at thirty)
		local hx, hy, hz = (vx or 0) * 0.15, (vy or 0) * 0.15, (vz or 0) * 0.15
		local hs = hx * hx + hy * hy + hz * hz
		if hs > K.maxSpeed * K.maxSpeed then
			local k = K.maxSpeed / sqrt(hs)
			hx, hy, hz = hx * k, hy * k, hz * k
		end
		hd.vx, hd.vy, hd.vz = hx, hy, hz
	end
	FC.Move("airborne", "surface", vol)
	s.bk.fed = s.bk.fed + vol
	s.bk.surface = s.bk.surface + vol
	return true
end

------------------------------------------------------------------------------------------
-- Leaving the body
------------------------------------------------------------------------------------------
-- down: the drop leaves below the surface point along gravity (a low point / fold of the mesh)
local function Detach(hd, s, src, vol, px, py, pz, nx, ny, nz, bvx, bvy, bvz, push, kind, down)
	vol = min(vol, hd.vol)
	if vol <= 0 then return end
	hd.vol = hd.vol - vol
	hd.lastDrip = CurTime()
	hd.pendMul = hd.chan.rng:Range(0.85, 1.2)
	s.bk.surface = s.bk.surface - vol
	s.bk.left = s.bk.left + vol
	-- gentle detachments (hanging drops, drops off an edge) right above the ground seep instead
	if push <= 3 and F.GroundSeep(vol, px, py, pz, nx, ny, nz, hd.chan.owner or src.key) then
		FC.Move("surface", "pool", vol)
		return
	end
	local lag = min(FrameTime(), 0.05)
	local ox, oy, oz = nx * 0.45, ny * 0.45, nz * 0.45
	if down then
		local gx, gy, gz, gmag = ABL.Gravity()
		ox, oy, oz = gx / gmag * 0.6 + nx * 0.1, gy / gmag * 0.6 + ny * 0.1, gz / gmag * 0.6 + nz * 0.1
		nx, ny, nz = 0, 0, 0
	end
	local d = Drops.Spawn(px + ox + bvx * lag, py + oy + bvy * lag, pz + oz + bvz * lag,
		bvx + hd.vx + nx * push, bvy + hd.vy + ny * push, bvz + hd.vz + nz * push, vol, src, 0, kind or 0, "surface", hd.chan.owner)
	-- (dripping fast, the drops are one stream: cl_droplets.lua draws linked drops as a ribbon)
	if kind == 1 then Drops.Link(d, hd.chan, "drip") end
	WS.Ledger(src, "offBody", vol)
end

-- More blood at node i than a stream on a steep surface holds: vol of it drops off there.
local function Shed(ch, s, src, pose, i, vol, now)
	local avail = ch.V[i] - ch.hold[i]
	if vol > avail then vol = avail end
	if vol <= 0 then return end
	local a = ch.an[i]
	local x, y, z, nx, ny, nz = pose:SkinPoint(a)
	local bvx, bvy, bvz = pose:BoneVel(a.b1)
	ch.V[i] = ch.V[i] - vol
	s.bk.surface = s.bk.surface - vol
	s.bk.left = s.bk.left + vol
	ch.shedT = now
	if F.GroundSeep(vol, x, y, z, nx, ny, nz, ch.owner or src.key) then
		FC.Move("surface", "pool", vol)
		return
	end
	local lag = min(FrameTime(), 0.05)
	local d = Drops.Spawn(x + nx * 0.45 + bvx * lag, y + ny * 0.45 + bvy * lag, z + nz * 0.45 + bvz * lag,
		bvx + nx * 3, bvy + ny * 3, bvz + nz * 3, vol, src, 0, 0, "surface", ch.owner)
	Drops.Link(d, ch, "shed")
	WS.Ledger(src, "offBody", vol)
end

------------------------------------------------------------------------------------------
-- The head
------------------------------------------------------------------------------------------
-- What a head leaves in node n that it has just laid: the film it spread since the last node, a
-- track as wide as itself, and a thin rivulet (behind the bead the stream is never broken off);
-- what it holds beyond a modest bead stays behind it as stream too.
function FC.Laid(hd, ch, n)
	ch.F[n] = hd.film
	hd.film = 0
	hd.dist = 0
	ch.wmax[n] = 2 * (min(max(hd.vol, 0), K.headShow) / ML / 1.28) ^ 0.3333 * K.headGain * K.trackK / K.widthGain
	local len = n > 1 and ch.L[n - 1] / K.spacing or 1
	if len < 1 then len = 1 end
	local give = min(hd.vol * 0.08, K.trailVol * len)
	-- (a head on the world whose stream carries what comes, C.P21.streamHead, keeps its bead, hd.bead: it
	-- lays down only what it holds beyond that, and the stream behind it fills the new stretch)
	local over = hd.vol - max(K.headFull, hd.bead or 0)
	if over > 0 then give = give + min(over * K.headShed, K.shedMax * len) end
	if give > 0 then
		ch.V[n] = give
		ch.age[n], ch.T[n] = hd.bage, 0
		hd.vol = hd.vol - give
	end
end

-- Lay a node where the head is now; the film it has spread since the last one goes to that node.
-- Returns false when none was laid, and true as second value when that was for want of room.
local function LayNode(hd, ch, s, m, now)
	-- A head that turns in a fold of the mesh comes back to where it has been: no new nodes there
	-- (its film goes to the node it is on).
	local n0 = ch.n
	if n0 >= 3 then
		local qx, qy, qz = BM.BindPoint(m, hd.tri, hd.u, hd.v)
		local lim = K.minSpacing * K.minSpacing * 0.5
		local an = ch.an
		for i = n0 - 1, max(1, n0 - 10), -1 do
			local a = an[i]
			local dx, dy, dz = a.px - qx, a.py - qy, a.pz - qz
			if dx * dx + dy * dy + dz * dz < lim then
				ch.F[n0] = ch.F[n0] + hd.film
				hd.film, hd.dist = 0, 0
				return false
			end
		end
	end
	if ch.n >= K.maxNodes or not MakeRoom(ch.src, s, ch) then return false, true end
	FC.Laid(hd, ch, AddNode(ch, s, hd.tri, hd.u, hd.v, m, now))
	return true
end

-- The head has run into another channel: its stream ends in that one, and their flows add.
local function Join(hd, ch, s, m, och, oi, now)
	-- (never in a circle)
	local c = och
	for _ = 1, 12 do
		if c == ch then return false end
		c = c.joinCh
		if not c then break end
	end
	if hd.dist > 0.05 then LayNode(hd, ch, s, m, now) end
	-- (the other channel may just have made way for that node)
	if och.dead then return false end
	local V = och.V
	local tot = V[oi] + hd.vol
	if tot > 0 then
		och.age[oi] = (och.age[oi] * V[oi] + hd.bage * hd.vol) / tot
		V[oi] = tot
	end
	och.F[oi] = och.F[oi] + hd.film
	och.done, och.idleT = false, 0
	ch.joinCh, ch.joinIdx = och, oi
	FreeHead(hd)
	prof.joins = prof.joins + 1
	if ch.parentCh and ch.n <= 4 then
		local tv, tf = 0, 0
		for i = 1, ch.n do
			tv, tf = tv + ch.V[i], tf + ch.F[i]
			ch.V[i], ch.F[i] = 0, 0
		end
		V[oi] = V[oi] + tv
		och.F[oi] = och.F[oi] + tf
		if not ch.parentCh.dead then ch.parentCh.kids = max((ch.parentCh.kids or 1) - 1, 0) end
		ch.dissolve = true
		s.sweep = true
	end
	return true
end

-- At an open edge: on to another mesh piece right across the gap, if there is one.
local function Bridge(hd, ch, s, src, pose, m, fx, fy, fz, gdx, gdy, gdz, now)
	if hd.bridgeTri == hd.tri and now < hd.bridgeT then return false end
	hd.bridgeTri, hd.bridgeT = hd.tri, now + 1
	local px, py, pz = pose:Point(hd.tri, hd.u, hd.v)
	local qx, qy, qz = px + fx * 0.3 + gdx * 0.2, py + fy * 0.3 + gdy * 0.2, pz + fz * 0.3 + gdz * 0.2
	local nt, nu, nv = BM.Bridge(pose, m.tb[hd.tri], qx, qy, qz, hd.tri, B.bridge)
	if not nt then return false end
	-- a node on the lip, the next on the other piece: across a wide gap nothing is drawn between them
	if hd.dist > 0.05 then LayNode(hd, ch, s, m, now) end
	local lip = ch.n
	hd.tri, hd.u, hd.v = nt, nu, nv
	hd.ptri, hd.pu, hd.pv = nt, nu, nv
	hd.atEdge = false
	hd.bridgeTri = nil
	if LayNode(hd, ch, s, m, now) and ch.L[lip] > K.gapDraw then ch.gap[lip] = true end
	return true
end

-- One step of a head. Returns false when it is gone (joined another channel).
local function StepHead(hd, ch, s, src, pose, m, dt, gx, gy, gz, gmag, now)
	hd.age = hd.age + dt
	hd.bage = hd.bage + dt
	local tri = hd.tri
	local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = pose:Tri(tri)
	local u, v = hd.u, hd.v
	local px = ax + u * (bx - ax) + v * (cx - ax)
	local py = ay + u * (by - ay) + v * (cy - ay)
	local pz = az + u * (bz - az) + v * (cz - az)
	hd.wx, hd.wy, hd.wz, hd.nx, hd.ny, hd.nz = px, py, pz, nx, ny, nz
	hd.placed = true

	local bone = m.tb[tri]
	local bvx, bvy, bvz, bax, bay, baz = pose:BoneVel(bone)
	-- what blood feels in the body's frame: gravity less the body part's own acceleration
	local ix, iy, iz = gx - bax * B.inertia, gy - bay * B.inertia, gz - baz * B.inertia
	local gn = ix * nx + iy * ny + iz * nz           -- > 0: pulled away from the surface
	local tx, ty, tz = ix - nx * gn, iy - ny * gn, iz - nz * gn
	local tmag = sqrt(tx * tx + ty * ty + tz * tz)
	hd.ix, hd.iy, hd.iz = ix, iy, iz
	hd.gt = tmag / gmag
	hd.pn = gn < 0 and -gn / gmag or 0
	local rng = ch.rng
	local n = ch.n

	-- violent acceleration (impact, whip) throws blood off
	if gn > B.flingAccel and hd.vol > 0.01 then
		Detach(hd, s, src, hd.vol * rng:Range(0.5, 0.9), px, py, pz, nx, ny, nz, bvx, bvy, bvz, 12)
	end

	-- on an underside the head hangs, swells and lets go as a drop
	hd.hangK = 0
	if gn > 0.3 * gmag then
		local vd = B.pendant * gmag / gn * hd.pendMul
		hd.hangK = hd.vol / vd
		if hd.vol > vd then
			hd.hang = hd.hang + dt
			-- a heavily fed drop lets go sooner and bigger: dripping turns into a stream
			if hd.hang > 0.08 * min(1, 2 * vd / hd.vol) then
				hd.hang = 0
				local dv = min(max(vd, (hd.vol - vd) * 0.6), 0.5)
				Detach(hd, s, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 2, dv > vd * 2 and 1 or 0)
			end
		end
	else
		hd.hang = max(0, hd.hang - dt * 0.5)
	end

	-- blood that has been out for a while is thicker: the head creeps, then sets
	local clot = ClotF(hd.bage / (K.clotTime * C.sv.drying:GetFloat()))

	-- stick / slip: the head stays until its weight along the surface beats the contact line
	local wet = src.wetTri[tri] or 0
	local thresh = B.adhesion * (wet > 0.01 and B.wetAdhesion or 1)
	local drive = (max(hd.vol, 0) ^ 0.6667) * tmag / gmag
	-- (a small wound in its first seconds: several beads, and the largest of them is what may run)
	if ch.cut then drive = drive * CutStep(ch, hd, dt) ^ 0.6667 end
	local k = min(1, dt / 0.12)
	local held = drive <= thresh or tmag < 1e-3 or now < hd.freezeT
	-- (a puddle that has run over: the head creeps away from it for a moment, whatever holds it)
	local spill = held and hd.spillT > 0 and clot < 50
	if spill then hd.spillT = hd.spillT - dt end
	if (held or clot > 50) and not spill then
		hd.vx, hd.vy, hd.vz = hd.vx * (1 - k), hd.vy * (1 - k), hd.vz * (1 - k)
		hd.moving = false
		hd.stuckT = hd.stuckT + dt
		-- a resting bead soaks into cloth (faster the larger its footprint). Skin takes nothing up:
		-- there it only creeps a little wider, stays a bead, and sets as a clot when its time has come
		local take
		if ch.ab[n] > 0 then
			take = min(hd.vol, dt * (0.0008 + B.soak * max(hd.vol, 0) ^ 0.6667 + (hd.vol < 0.05 and 0.002 or 0)))
		else
			take = min(hd.vol, dt * 0.0005)
		end
		if take > 0 and hd.stuckT > 0.6 then
			hd.vol = hd.vol - take
			if ch.ab[n] > 0 then
				ch.S[n] = ch.S[n] + take
				FC.Move("surface", "absorbed", take)
				s.bk.surface, s.bk.absorbed = s.bk.surface - take, s.bk.absorbed + take
			else
				ch.F[n] = ch.F[n] + take
			end
		end
		-- more than the spot can hold runs over its downhill rim (a random side when level): the
		-- puddle stays behind as a node that holds its fill, the head runs on with the rest
		local cap = (ch.wd and ch.wd.profile and ch.wd.profile.spreadCap) or B.spreadCap
		if hd.vol > cap and hd.age - hd.lastSpill > 0.6 and clot < 50 and now >= hd.freezeT then
			hd.lastSpill = hd.age
			local dx, dy, dz
			if tmag > gmag * 0.02 then
				dx, dy, dz = tx / tmag, ty / tmag, tz / tmag
			else
				local sx, sy, sz = ABL.Perp(nx, ny, nz)
				local qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
				local a = rng:Next() * 6.2831853
				local c, sn = math.cos(a), math.sin(a)
				dx, dy, dz = sx * c + qx * sn, sy * c + qy * sn, sz * c + qz * sn
			end
			-- (a puddle holds its fill only where the surface is level)
			local keep = cap * 0.6 * max(0, 1 - hd.gt / 0.4)
			if hd.dist > 0.05 or n == 1 then
				if hd.dist > 0.05 then LayNode(hd, ch, s, m, now) end
				n = ch.n
			end
			ch.V[n] = ch.V[n] + keep
			ch.hold[n] = ch.hold[n] + keep
			ch.age[n] = hd.bage
			hd.vol = hd.vol - keep
			hd.spillT = F.PuddleRadius(cap) * 1.3 / K.spillSpeed
			hd.sdx, hd.sdy, hd.sdz = dx, dy, dz
			prof.breaks = prof.breaks + 1
		end
	elseif spill then
		local dx, dy, dz = hd.sdx, hd.sdy, hd.sdz
		local sp = K.spillSpeed
		hd.vx = hd.vx + (dx * sp - hd.vx) * k
		hd.vy = hd.vy + (dy * sp - hd.vy) * k
		hd.vz = hd.vz + (dz * sp - hd.vz) * k
		hd.moving = true
		hd.stuckT = 0
	else
		local over = 1 - thresh / drive
		local sp = B.speed * (hd.vol ^ 0.3333) * (tmag / gmag) * over * (1 + min(wet * 20, 1)) / clot
		-- well supplied, the front runs as fast as the stream behind it
		if hd.vol > K.headFull then
			local us = ch.us[n] * min(1, (hd.vol - K.headFull) / K.headFull + 0.3) / clot
			if us > sp then sp = us end
		end
		-- A rivulet does not run straight down: its contact line catches on the weave, on folds, on the
		-- texture of skin. Its heading wanders off the fall line by an angle that changes with the
		-- distance run (not with time: a slow stream takes the same path as a fast one).
		local ds = sp * dt
		local ml = K.meanderLen
		hd.mz = hd.mz - hd.mz * min(1, ds / ml) + rng:Normal() * K.meanderAmp * sqrt(2 * min(ds / ml, 0.5))
		local cm, sm = math.cos(hd.mz), math.sin(hd.mz)
		local inv = sp / tmag
		local lx, ly, lz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
		hd.vx = hd.vx + ((tx * cm + lx * sm) * inv - hd.vx) * k
		hd.vy = hd.vy + ((ty * cm + ly * sm) * inv - hd.vy) * k
		hd.vz = hd.vz + ((tz * cm + lz * sm) * inv - hd.vz) * k
		hd.moving = true
		hd.stuckT = 0
	end

	-- keep velocity tangent to the (rotating) surface
	local vn = hd.vx * nx + hd.vy * ny + hd.vz * nz
	hd.vx, hd.vy, hd.vz = hd.vx - nx * vn, hd.vy - ny * vn, hd.vz - nz * vn
	-- No head runs faster than a stream does, whatever set its velocity (a jolt, a landing, a
	-- number that went wrong); one that is no number at all stands still.
	do
		local hs = hd.vx * hd.vx + hd.vy * hd.vy + hd.vz * hd.vz
		if not (hs < K.maxSpeed * K.maxSpeed * 1.0001) then
			if hs == hs and hs < 1e12 then
				local k = K.maxSpeed / sqrt(hs)
				hd.vx, hd.vy, hd.vz = hd.vx * k, hd.vy * k, hd.vz * k
			else
				hd.vx, hd.vy, hd.vz = 0, 0, 0
			end
		end
	end

	if hd.moving then
		ch.cut = nil
		-- (measure of the path: how much it has turned)
		local sp2 = sqrt(hd.vx * hd.vx + hd.vy * hd.vy + hd.vz * hd.vz)
		if sp2 > 1e-4 then
			local qx, qy, qz = hd.vx / sp2, hd.vy / sp2, hd.vz / sp2
			if hd.pdx then
				local cs = qx * hd.pdx + qy * hd.pdy + qz * hd.pdz
				ch.turn = (ch.turn or 0) + math.acos(cs > 1 and 1 or (cs < -1 and -1 or cs))
			end
			hd.pdx, hd.pdy, hd.pdz = qx, qy, qz
		end
		-- A long step (a slow frame, a fast stream) is walked in pieces no longer than the spacing of
		-- the nodes, so that nodes are laid along it and no other stream is stepped over.
		local coarse = s.coarse or 1
		local pieces = math.ceil(sp2 * dt / (K.spacing * 0.8 * coarse))
		if pieces < 1 then pieces = 1 elseif pieces > 6 then pieces = 6 end
		local pdt = dt / pieces
		local went = 0
		for _ = 1, pieces do
			local tri0 = hd.tri
			local d = F.Walk(hd, pose, m, hd.vx * pdt, hd.vy * pdt, hd.vz * pdt)
			if d > 0 then
				went = went + d
				-- the film it wets the surface with: less on a path that is already wet
				local loss = min(hd.vol, d * B.filmLoss * (wet > 0.01 and B.wetFilmLoss or 1))
				hd.vol = hd.vol - loss
				hd.film = hd.film + loss
				src.wet[bone] = min((src.wet[bone] or 0) + loss, 4)
				src.wetTri[hd.tri] = min((src.wetTri[hd.tri] or 0) + loss, 1)
				hd.dist = hd.dist + d
				hd.travel = hd.travel + d
				hd.chk = hd.chk + d
				ch.moved = ch.moved + d
				-- a node every so often, and where the path turns onto another triangle
				if hd.dist >= K.spacing * coarse or (hd.tri ~= tri0 and hd.dist >= K.minSpacing * coarse) then
					local _, full = LayNode(hd, ch, s, m, now)
					-- (no room for the channel to follow: the stream ends here for now, and drips)
					if full then
						hd.freezeT = now + 4
						hd.vx, hd.vy, hd.vz = 0, 0, 0
						break
					end
				end
				-- another stream in the way: join it
				if hd.chk >= K.checkEvery then
					hd.chk = 0
					local qx, qy, qz = BM.BindPoint(m, hd.tri, hd.u, hd.v)
					local och, oi, d2 = Near(s, qx, qy, qz, K.mergeMax, ch)
					if och then
						-- (they join where the bead's edge touches the other stream's edge)
						local reach = 0.75 * ((min(max(hd.vol, 0.001), K.headShow) / ML / 1.28) ^ 0.3333 * K.headGain + 0.5 * FC.Wide(och.wmax[oi]))
						if reach < K.mergeDist then reach = K.mergeDist elseif reach > K.mergeMax then reach = K.mergeMax end
						-- (a branch does not fall back into its parent right where it left it)
						if d2 < reach * reach and not (och == ch.parentCh and hd.travel < K.branchFree) and Join(hd, ch, s, m, och, oi, now) then return false end
					end
				end
			end
			if hd.atEdge or d <= 0 then break end
		end
		if went > (ch.maxStep or 0) then ch.maxStep = went end
		if hd.atEdge then
			-- the lip of a separate piece: on to the piece right across the gap if there is one
			local spd = sqrt(hd.vx * hd.vx + hd.vy * hd.vy + hd.vz * hd.vz)
			local fx, fy, fz
			if spd > 1e-3 then fx, fy, fz = hd.vx / spd, hd.vy / spd, hd.vz / spd
			elseif tmag > 1e-3 then fx, fy, fz = tx / tmag, ty / tmag, tz / tmag
			else fx, fy, fz = 0, 0, 0 end
			Bridge(hd, ch, s, src, pose, m, fx, fy, fz, gx / gmag, gy / gmag, gz / gmag, now)
		end
	end

	-- a runnel that keeps moving without getting anywhere is caught in a pit or fold of the mesh
	-- (a hem folding inward, the gap between two layers): that is a low point, and it drips there
	if hd.moving then
		if hd.age - hd.sampT >= 0.5 then
			local dx, dy, dz = px - hd.sx, py - hd.sy, pz - hd.sz
			local went = hd.travel - hd.sampTravel
			if went > 1 and dx * dx + dy * dy + dz * dz < (went * 0.3) ^ 2 then
				hd.trapT = hd.trapT + (hd.age - hd.sampT)
			else
				hd.trapT = 0
			end
			hd.sampT, hd.sampTravel, hd.sx, hd.sy, hd.sz = hd.age, hd.travel, px, py, pz
		end
	else
		hd.trapT = 0
	end
	if hd.trapT >= 1 then hd.freezeT = now + 2.5 end
	if now < hd.freezeT and hd.vol > B.edgePendant then
		hd.hangK = max(hd.hangK, 1)
		local since = now - hd.lastDrip
		if since > 0.06 then
			local dv = max(B.pendant, min(hd.vol * 0.5, 0.3))
			Detach(hd, s, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 1, since < 0.15 and 1 or 0, true)
		end
	end

	-- at an open edge (sleeve, hem, fingertip) a drop forms on the lip; strong inflow makes bigger,
	-- faster drops that join into a stream
	if hd.atEdge and hd.vol > B.edgePendant then
		hd.hangK = max(hd.hangK, hd.vol / (B.edgePendant * 1.6))
		local since = now - (hd.lastDrip or 0)
		if since > 0.06 then
			local dv = max(rng:Range(0.8, 1.2) * B.edgePendant, min(hd.vol * 0.5, 0.3))
			Detach(hd, s, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 3, since < 0.15 and 1 or 0)
		end
	end
	return true
end

------------------------------------------------------------------------------------------
-- The channel
------------------------------------------------------------------------------------------
-- Gravity as blood on bone b feels it (less the bone's own acceleration), in the mesh's bind space
-- and as a fraction of g: there the channel's directions and normals are constant.
local gbCache = {}
local WGRAV = { 0, 0, -1 }
local function GBind(pose, bone, gx, gy, gz, gmag, stamp)
	-- (channels on the world: gravity as it is)
	if not pose then
		WGRAV[1], WGRAV[2], WGRAV[3] = gx / gmag, gy / gmag, gz / gmag
		return WGRAV
	end
	local e = gbCache[bone]
	if e and e.s == stamp then return e end
	if not e then e = {} gbCache[bone] = e end
	e.s = stamp
	local sk = pose:Skin(bone)
	if not sk then e[1], e[2], e[3] = 0, 0, 0 return e end
	local _, _, _, bax, bay, baz = pose:BoneVel(bone)
	local ix, iy, iz = (gx - bax * B.inertia) / gmag, (gy - bay * B.inertia) / gmag, (gz - baz * B.inertia) / gmag
	e[1] = sk[1] * ix + sk[5] * iy + sk[9] * iz
	e[2] = sk[2] * ix + sk[6] * iy + sk[10] * iz
	e[3] = sk[3] * ix + sk[7] * iy + sk[11] * iz
	return e
end

local dVs, hN = {}, {}

-- Where a stream leaves its channel. Two causes, both looked for at nodes that hold more blood than
-- a stream leaves there:
--   the body has turned: gravity along the skin no longer points down the channel's line, and the
--     blood standing at the node goes where it points now (it takes all that arrives there);
--   a surge runs into a bend: fast blood overshoots the bend and a finger runs straight on with a
--     share of it, while the surge lasts.
-- The new head starts at the node; its channel is fed from the node (StepChannel).
local function Branch(ch, s, src, pose, m, now, gx, gy, gz, gmag, stamp)
	local n = ch.n
	if n < 4 or (ch.kids or 0) >= K.branchMax or now < (ch.branchT or 0) or FC.heads >= L.Cap(C.cl.maxBlobs) then return end
	-- (a channel that already feeds a branch where gravity turned keeps to that one)
	if ch.turned and not ch.turned.dead and (ch.turned.head or (ch.turned.mobile or 0) > 0.002) then return end
	local V, hold, an, us = ch.V, ch.hold, ch.an, ch.us
	local tx, ty, tz = ch.tx, ch.ty, ch.tz
	local rng = ch.rng
	local hh = ch.h
	local pudAt = ch.pudAt
	if not pudAt then pudAt = {} ch.pudAt = pudAt end
	local bi, bshare, d1, d2, d3, bpud
	local best = 0
	for i = 1, n - 1 do
		local ex = V[i] - hold[i]
		if ex > K.branchVol * 0.4 then
			local a = an[i]
			local g = GBind(pose, a.b1, gx, gy, gz, gmag, stamp)
			local gnn = g[1] * a.nx + g[2] * a.ny + g[3] * a.nz
			local t1, t2, t3 = g[1] - a.nx * gnn, g[2] - a.ny * gnn, g[3] - a.nz * gnn
			local tm = sqrt(t1 * t1 + t2 * t2 + t3 * t3)
			if tm > 0.25 then
				local along = (t1 * tx[i] + t2 * ty[i] + t3 * tz[i]) / tm
				if along < K.branchCos and ex > K.branchVol then
					-- (the first such node from the wound: what lies below it is fed through it)
					bi, bshare, d1, d2, d3, bpud = i, 1, t1 / tm, t2 / tm, t3 / tm, false
					break
				elseif i > 2 and ch.wd and us[i - 1] > K.branchSpeed then
					-- how sharply the channel turns here
					local bend = 1 - (tx[i - 1] * tx[i] + ty[i - 1] * ty[i] + tz[i - 1] * tz[i])
					if bend > K.branchBend then
						local score = ex * bend * 10
						if score > best and rng:Next() < K.branchChance then best, bi, bshare, d1, d2, d3, bpud = score, i, K.branchShare, tx[i - 1], ty[i - 1], tz[i - 1], false end
					end
				end
			elseif ex > K.branchVol * 2 and hh[i] > K.hMax and not pudAt[i] then
				-- level skin: it cannot run, and more stands here than a rivulet holds. It gathers into
				-- a puddle (a head that rests here, grows, and spills over its lowest rim).
				local score = ex * 3
				if score > best then best, bi, bshare, d1, d2, d3, bpud = score, i, 1, 0, 0, 0, true end
			end
		end
	end
	if not bi then return end
	local a = an[bi]
	local sk = pose:Skin(a.b1)
	if not sk or not (FC.nodes < L.Cap(FC.cvNodes) and s.nodes < K.maxNodesSrc) then return end
	local child = FC.NewChannel(src, s, nil)
	FC.AddNode(child, s, a[1], a[2], a[3], m, now)
	child.wmax[1] = ch.wmax[bi] * 0.6
	child.parentCh, child.parentIdx, child.share, child.pud = ch, bi, bshare, bpud
	if bshare >= 1 and not bpud then ch.turned = child end
	local take = (V[bi] - hold[bi]) * bshare * 0.8
	V[bi] = V[bi] - take
	local hd = FC.SpawnHead(child, a[1], a[2], a[3], take)
	hd.bage = ch.age[bi]
	if bpud then
		-- (one puddle per stretch of the channel)
		for q = max(1, bi - 4), min(n, bi + 4) do pudAt[q] = true end
	else
		-- its first heading: where gravity points now, or straight on past the bend (bind -> world)
		local wx = sk[1] * d1 + sk[2] * d2 + sk[3] * d3
		local wy = sk[5] * d1 + sk[6] * d2 + sk[7] * d3
		local wz = sk[9] * d1 + sk[10] * d2 + sk[11] * d3
		hd.vx, hd.vy, hd.vz = wx * 1.5, wy * 1.5, wz * 1.5
		hd.spillT = 0.5
		hd.sdx, hd.sdy, hd.sdz = wx, wy, wz
	end
	ch.kids = (ch.kids or 0) + 1
	ch.branchT = now + K.branchEvery
	prof.branches = (prof.branches or 0) + 1
end

-- One step of a channel's liquid. gscale: gravity relative to the map's normal 600 u/s^2.
local function StepChannel(ch, s, pose, dt, now, gx, gy, gz, gmag, stamp, gscale, tClot, tFilm, tWet)
	local n = ch.n
	local an, V, Ls, Lc, hold, mu, age, T = ch.an, ch.V, ch.L, ch.Lc, ch.hold, ch.mu, ch.age, ch.T
	local hh, ww, us, qv, dr = ch.h, ch.w, ch.us, ch.qv, ch.dr
	local KF, LEVEL, CAPIL, VMAX = K.kFlow * gscale, K.level, K.capillary, K.maxSpeed
	local bk = s.bk
	local rate = 0

	-- A branch draws on the node of its parent that it left from: all of what stands there while
	-- gravity pulls across the parent's line (the body has turned), its share while the parent still
	-- surges past (an overshoot at a bend).
	local pc = ch.parentCh
	if pc then
		if pc.dead then
			ch.parentCh = nil
		else
			local pi = ch.parentIdx
			local ex = pc.V[pi] - pc.hold[pi] - K.rootHold
			if ex > 0 then
				local k = ch.share
				if ch.pud then
					-- (a puddle takes what stands at its node, whatever way the parent runs)
				elseif k >= 1 then
					local a = pc.an[pi]
					local g = GBind(pose, a.b1, gx, gy, gz, gmag, stamp)
					local gnn = g[1] * a.nx + g[2] * a.ny + g[3] * a.nz
					local t1, t2, t3 = g[1] - a.nx * gnn, g[2] - a.ny * gnn, g[3] - a.nz * gnn
					local tm = sqrt(t1 * t1 + t2 * t2 + t3 * t3)
					-- (the parent's own line runs downhill again: it keeps its blood)
					if tm < 0.1 or (t1 * pc.tx[pi] + t2 * pc.ty[pi] + t3 * pc.tz[pi]) / tm > 0.92 then k = 0 end
				elseif pc.us[pi] < K.branchSpeed * 0.6 then
					k = 0
				end
				local d = ex * k * min(1, dt * K.branchRate)
				if d > 0 then
					local tot = V[1] + d
					age[1] = (age[1] * V[1] + pc.age[pi] * d) / tot
					T[1] = (T[1] * V[1] + pc.T[pi] * d) / tot
					V[1] = tot
					pc.V[pi] = pc.V[pi] - d
					ch.fedT = now
				end
			end
		end
	end

	-- heights of the free rivulet from the state before the step
	local prevL = 0
	local MINC = K.minCell
	for i = 1, n do
		local l = Ls[i]
		local lc = 0.5 * (prevL + l)
		if lc < MINC then lc = MINC end
		Lc[i] = lc
		prevL = l
		local vol = V[i] - hold[i]
		if vol > 1e-7 then
			-- (Geo written out, the height alone: a call a node a step is a third of the step)
			local ar = vol / (lc * ML)
			local h0 = sqrt(ar / KA)
			local h = h0 / sqrt(1 + (h0 / HMAX) * (h0 / HMAX))
			if 1.5 * ar / h > WCAP then
				h = 1.5 * ar / WCAP
				if h > HBEAD then
					h = HBEAD
					if 1.5 * ar / h > WSHEET then h = 1.5 * ar / WSHEET end
				end
			end
			hN[i] = h
		else
			hN[i] = 0
		end
		us[i] = 0
	end

	-- what moves between neighbours
	local tx, ty, tz = ch.tx, ch.ty, ch.tz
	local shedI, shedEx = 0, 0.03
	-- (gravity in the space of the bone the node hangs on: asked for when the bone changes, and
	-- most nodes of a stretch hang on the same one)
	local gB, g1, g2, g3
	for i = 1, n - 1 do
		local a1 = an[i]
		local b1 = a1.b1
		if b1 ~= gB or not g1 then
			local g = GBind(pose, b1, gx, gy, gz, gmag, stamp)
			gB, g1, g2, g3 = b1, g[1], g[2], g[3]
		end
		local sl = g1 * tx[i] + g2 * ty[i] + g3 * tz[i]
		local pn = -(g1 * a1.nx + g2 * a1.ny + g3 * a1.nz)
		do
			-- (more here than the surface holds, three times as much where it is level: see below)
			local ex = V[i] - hold[i] - CAPV * Lc[i] * (pn < 0.5 and 1 or 3)
			if ex > shedEx then shedI, shedEx = i, ex end
		end
		if pn < 0 then pn = 0 end
		local h1, h2 = hN[i], hN[i + 1]
		local S = sl + (pn * LEVEL + CAPIL) * (h1 - h2) / Ls[i]
		dr[i] = S
		local up, h, sign = i, h1, 1
		if S < 0 then up, h, sign, S = i + 1, h2, -1, -S end
		local d = 0
		if h > 1e-5 then
			local u = KF * S * h * h / mu[up]
			if u > VMAX then u = VMAX end
			local vol = V[up] - hold[up]
			d = vol / Lc[up] * u * dt
			if d > vol * 0.45 then d = vol * 0.45 end
			if u > us[up] then us[up] = u end
			qv[i] = sign * u
			-- (how fast a wave crosses the shortest cell: the next step is split to stay under it)
			local cr = u / Lc[up]
			if cr > rate then rate = cr end
		else
			qv[i] = 0
		end
		dVs[i] = sign * d
	end
	ch.rate = rate * 2
	-- (blood carries its age and its warmth with it)
	for i = 1, n - 1 do
		local d = dVs[i]
		if d ~= 0 then
			local up, dn = i, i + 1
			if d < 0 then up, dn, d = i + 1, i, -d end
			local vd = V[dn]
			local tot = vd + d
			age[dn] = (age[dn] * vd + age[up] * d) / tot
			T[dn] = (T[dn] * vd + T[up] * d) / tot
			V[dn] = tot
			V[up] = V[up] - d
		end
	end

	-- More at a node than a stream on a steep surface holds (a fold of the cloth that has filled, a
	-- supply no stream carries away) does not stay: it drops off there.
	if pose then
		local a1 = an[n]
		local g = GBind(pose, a1.b1, gx, gy, gz, gmag, stamp)
		local ex = V[n] - hold[n] - CAPV * Lc[n] * (-(g[1] * a1.nx + g[2] * a1.ny + g[3] * a1.nz) < 0.5 and 1 or 3)
		if ex > shedEx then shedI, shedEx = n, ex end
		if shedI > 0 and now - (ch.shedT or 0) > 0.07 then
			local d = shedEx * 0.3
			if d < 0.06 then d = 0.06 elseif d > 0.8 then d = 0.8 end
			Shed(ch, s, ch.src, pose, shedI, d, now)
		end
	end

	-- the end of the channel
	local hd = ch.head
	local a = an[n]
	ch.qTip = 0
	if hd and not hd.placed then
		-- (a head made during this step has not been stepped yet: nothing for it, and no second head)
		qv[n] = 0
	elseif hd then
		local vol = V[n] - hold[n]
		if vol > 1e-7 then
			local wx, wy, wz
			if pose then wx, wy, wz = pose:SkinPoint(a) else wx, wy, wz = a.px, a.py, a.pz end
			local dx, dy, dz = hd.wx - wx, hd.wy - wy, hd.wz - wz
			local dd = sqrt(dx * dx + dy * dy + dz * dz)
			local d = 0
			if n == 1 and dd < 0.15 then
				-- still at the wound: the bead there is the head, the wound keeps only a wet opening
				local ex = V[1] - hold[1] - K.rootHold
				if ex > 0 then d = ex * min(1, dt * K.rootRate) end
			else
				local S
				if dd < 0.06 then S = hd.gt else S = (dx * hd.ix + dy * hd.iy + dz * hd.iz) / (dd * gmag) end
				-- a full head on level ground holds the stream back
				local hh0 = 0.5 * (max(hd.vol, 0) / ML) ^ 0.3333
				S = S + hd.pn * (hN[n] - hh0) / max(dd, 0.15) * LEVEL
				-- (a head that sits still is where the stream ends: it takes what comes, and drips,
				-- spills or runs on by its own rules)
				if S < 0.3 and dd < 1.5 then S = 0.3 end
				local h = hN[n]
				if S > 0 and h > 1e-5 then
					local u = KF * S * h * h / mu[n]
					if u > VMAX then u = VMAX end
					d = vol / Lc[n] * u * dt
					if d > vol * 0.45 then d = vol * 0.45 end
					if u > us[n] then us[n] = u end
					qv[n] = u
				else
					qv[n] = 0
				end
			end
			-- (phase 21, C.P21.streamHead: a head on the world takes no more than keeps it its bead, hd.bead,
			-- cl_flowworld.lua; the rest of what comes stays in the stream, which carries it on as the head
			-- runs ahead and lays its bed. What stands at the stream's end beyond what a stretch of its bed
			-- holds, a sheet's worth (CAPV) over the end node's stretch and no less than the units between
			-- two nodes on the world, goes on into the head all the same: a surge the stream cannot hold
			-- makes the head heavy. Over the end node's stretch alone, 0.2 units at a channel's first node,
			-- the pool's handovers of 0.4 ml counted as such a surge and a head that the pool fed held 1.02
			-- ml, run p21h_after4; against a rivulet's worth over that stretch and 1.4 units more, 0.67 ml,
			-- p21h_after6: at its start the pool-fed stream's end held 0.86 ml)
			local bead = hd.bead
			if bead then
				local room = bead - hd.vol
				local over = vol - CAPV * (Lc[n] > WSTEP and Lc[n] or WSTEP)
				if over > room then room = over end
				if d > room then d = room > 0 and room or 0 end
			end
			if d > 0 then
				local tot = hd.vol + d
				hd.bage = (hd.bage * hd.vol + age[n] * d) / tot
				hd.vol = tot
				V[n] = V[n] - d
				ch.qTip = d / dt
			end
		end
	elseif ch.joinCh then
		local och, oi = ch.joinCh, ch.joinIdx
		if och.dead then
			ch.joinCh = nil
		else
			local b = och.an[oi]
			local dx, dy, dz = b.px - a.px, b.py - a.py, b.pz - a.pz
			local dd = sqrt(dx * dx + dy * dy + dz * dz)
			if dd < 0.05 then dd = 0.05 end
			local g = GBind(pose, a.b1, gx, gy, gz, gmag, stamp)
			local sl = (g[1] * dx + g[2] * dy + g[3] * dz) / dd
			local pn = -(g[1] * a.nx + g[2] * a.ny + g[3] * a.nz)
			if pn < 0 then pn = 0 end
			local h = hN[n]
			-- (into a stream: it takes what comes, the junction never backs up for want of slope)
			local S = max(sl, 0.25) + pn * (h - och.h[oi]) / dd * LEVEL
			local vol = V[n] - hold[n]
			if S > 0 and h > 1e-5 and vol > 0 then
				local u = KF * S * h * h / mu[n]
				if u > VMAX then u = VMAX end
				local d = vol / Lc[n] * u * dt
				if d > vol * 0.45 then d = vol * 0.45 end
				local OV = och.V
				local tot = OV[oi] + d
				och.age[oi] = (och.age[oi] * OV[oi] + age[n] * d) / tot
				och.T[oi] = (och.T[oi] * OV[oi] + T[n] * d) / tot
				OV[oi] = tot
				V[n] = V[n] - d
				if u > us[n] then us[n] = u end
				qv[n] = u
				ch.qTip = d / dt
				-- What arrives wakes the stream it arrives in once it amounts to something. (A
				-- trace left at a dry node, a millionth of a millilitre, goes on creeping into
				-- the next channel for minutes; it woke that channel at every step, and a
				-- channel with a few such neighbours was stepped at every frame, with nothing in
				-- it, until all of them were dry.)
				local arr = (och.arr or 0) + d
				if arr >= WAKE then och.done, och.idleT, arr = false, 0, 0 end
				och.arr = arr
			else
				qv[n] = 0
			end
		end
	elseif ch.sink then
		-- it ends on a floor: the pool there takes what comes down (cl_flowworld.lua hands it over)
		local vol = V[n] - hold[n]
		local h = hN[n]
		if vol > 1e-7 and h > 1e-5 then
			local u = KF * 0.5 * h * h / mu[n]
			if u > VMAX then u = VMAX end
			local d = vol / Lc[n] * u * dt
			if d > vol * 0.45 then d = vol * 0.45 end
			V[n] = V[n] - d
			ch.sinkAcc = (ch.sinkAcc or 0) + d
			if u > us[n] then us[n] = u end
			qv[n] = u
			ch.qTip = d / dt
		else
			qv[n] = 0
		end
	else
		qv[n] = 0
		-- a channel whose head is gone and that fills up again at its end gets a new head there
		if V[n] - hold[n] > K.respawn then
			if ch.world then
				ch.wantHead = true
			else
				local vol = (V[n] - hold[n]) * 0.85
				V[n] = V[n] - vol
				local nh = SpawnHead(ch, a[1], a[2], a[3], vol)
				nh.bage = age[n]
			end
		end
	end

	-- what happens to the blood where it is
	local Fm, Sk, Dr, Cv, wet, fed, sh, ab, ts, wmax = ch.F, ch.S, ch.D, ch.Cv, ch.wet, ch.fed, ch.sh, ch.ab, ch.ts, ch.wmax
	local ph, pw = ch.ph, ch.pw
	local cool = exp(-dt / K.coolTau)
	local kS = min(1, dt / K.shearTau)
	local kN, kG = min(1, dt / K.narrowTau), min(1, dt / K.widenTau)
	local tempK, soakCap, absorbK = K.tempK, K.soakCap, K.absorb
	local thinH, kThin = K.thinH, min(1, dt / K.thinTau)
	local kFilm, dWet, CLOTV = min(1, dt / tFilm), dt / tWet, K.clotVisc
	local live, mobile = 0, 0
	local wetMax = 0      -- (the wettest node: the drawing asks whether anything on the channel still shines)
	local dAbs, dClot, dDry = 0, 0, 0
	local wj, hj = 0, 0
	for i = 1, n do
		local v = V[i]
		local lc = Lc[i]
		ph[i], pw[i] = hh[i], ww[i]
		local c = 0
		if v > 1e-6 then
			-- cloth under the stream takes blood up until it is full
			local abi = ab[i]
			if abi > 0 then
				local room = soakCap * abi * lc - Sk[i]
				if room > 0 then
					local t = absorbK * abi * (ww[i] + 0.04) * lc * dt
					if t > room then t = room end
					if t > v * 0.5 then t = v * 0.5 end
					Sk[i] = Sk[i] + t
					v = v - t
					dAbs = dAbs + t
					-- (blood held back in a puddle is taken first)
					if hold[i] > v then hold[i] = v end
				end
			end
			-- blood too thin to run is film
			if hh[i] < thinH and hold[i] <= 0 then
				local t = v * kThin
				Fm[i] = Fm[i] + t
				v = v - t
			end
			age[i] = age[i] + dt
			T[i] = T[i] * cool
			wet[i] = 1
			wetMax = 1
			fed[i] = now
			c = age[i] / tClot
			if c >= 1 then
				-- set: it stays where it is, a clot
				Cv[i] = Cv[i] + v
				dClot = dClot + v
				v, hold[i], age[i], c = 0, 0, 0, 0
			end
			mobile = mobile + v
		else
			-- nothing runs over it: the film dries (wetness goes first, then the colour)
			local f = Fm[i]
			if f > 0 then
				local d = f * kFilm + 1e-6
				if d > f then d = f end
				Fm[i] = f - d
				Dr[i] = Dr[i] + d
				dDry = dDry + d
				live = live + f - d
			end
			local w = wet[i]
			if w > 0 then
				w = w - dWet
				if w < 0 then w = 0 end
				wet[i] = w
				if w > wetMax then wetMax = w end
				live = live + 1e-4
			end
		end
		V[i] = v
		-- the cross-section drawn: all the liquid here. The width grows at once and narrows slowly.
		local h, w = 0, 0
		if v > 1e-7 then
			-- (Geo written out)
			local ar = v / (lc * ML)
			local h0 = sqrt(ar / KA)
			h = h0 / sqrt(1 + (h0 / HMAX) * (h0 / HMAX))
			w = 1.5 * ar / h
			if w > WCAP then
				w = WCAP
				h = 1.5 * ar / w
				if h > HBEAD then
					h = HBEAD
					w = 1.5 * ar / h
					if w > WSHEET then
						w = WSHEET
						h = 1.5 * ar / w
					end
				end
			end
		end
		local cw = ww[i]
		if w >= cw then cw = cw + (w - cw) * kG else cw = cw + (w - cw) * kN end
		ww[i] = cw
		if cw > wmax[i] then wmax[i] = cw end
		if cw > 1e-4 and v > 1e-7 then
			local hp = 1.5 * v / (lc * ML) / cw
			if hp < h then h = hp end
		end
		hh[i] = h
		local dw, dh = abs(cw - pw[i]), abs(h - ph[i])
		if dw > wj then wj = dw end
		if dh > hj then hj = dh end
		-- shear lately, and the viscosity that goes with it, the warmth left and the clotting
		local g = h > 1e-5 and 3 * us[i] / h or 0
		local sg = sh[i] + (g - sh[i]) * kS
		sh[i] = sg
		-- (ShearF and ClotF written out)
		local cf = 1
		if c > 0 then
			if c >= 1 then
				cf = 1e4
			else
				local c2 = c * c
				cf = 1 + CLOTV * c2 * c2 * c2 / (1.02 - c)
			end
		end
		mu[i] = (1 + 15.23 * (1 + 10.976 * sg * sg) ^ -0.3216) * (1 + tempK * (ts[i] - T[i])) * cf
	end
	if dAbs > 0 then FC.Move("surface", "absorbed", dAbs) bk.surface, bk.absorbed = bk.surface - dAbs, bk.absorbed + dAbs end
	if dClot > 0 then FC.Move("surface", "clotted", dClot) bk.surface, bk.clotted = bk.surface - dClot, bk.clotted + dClot end
	if dDry > 0 then FC.Move("surface", "dried", dDry) bk.surface, bk.dried = bk.surface - dDry, bk.dried + dDry end
	if wj > (ch.wJump or 0) then ch.wJump = wj end
	if hj > (ch.hJump or 0) then ch.hJump = hj end
	ch.lt, ch.sd = ABL.Sim.t, dt
	ch.mobile = mobile
	ch.wetMax = wetMax
	ch.steps = (ch.steps or 0) + 1
	return mobile, live
end

------------------------------------------------------------------------------------------
-- Step
------------------------------------------------------------------------------------------
local stampN = 0
local cAwake, cAwakeN, cIdle = 0, 0, 0     -- channels stepped this frame: awake (and their nodes), idle

-- The liquid of all channels of state s over dt: short steps (the step of a slow frame is split, and
-- split further while a fast stream crosses short cells), fewer for what is far away and for what
-- the frame's budget does not cover. pose, m: the body's (nil for channels on the world).
local function StepLiquid(s, src, pose, m, dt, now, lod, gx, gy, gz, gmag, gscale, tClot, tFilm, tWet, allow)
	local chans = s.chans
	local subHz = (lod >= C.LOD_ULTRA and K.subHz) or (lod >= C.LOD_HIGH and K.subHz * 0.5) or 0
	local maxSub = lod >= C.LOD_HIGH and K.maxSub or 1
	-- (allow: how many short steps the frame's budget leaves this body)
	if allow and maxSub > allow then maxSub = allow end
	local nsub = math.ceil(dt * subHz - 0.01)
	if nsub < 1 then nsub = 1 elseif nsub > maxSub then nsub = maxSub end
	local sdt = dt / nsub
	for c = 1, #chans do
		local ch = chans[c]
		if ch and not ch.dead and not ch.done and not ch.dissolve then
			-- a channel with nothing moving is looked at about twice a second (it only dries)
			local idle = ch.idleT > 1.5 and not ch.head
			local run, cdt, sub = true, sdt, nsub
			local need = math.ceil(dt * (ch.rate or 0) / 0.6 - 0.01)
			if need > sub then
				sub = need > maxSub and maxSub or need
				cdt = dt / sub
			end
			if idle then
				ch.skip = (ch.skip or 0) + dt
				if ch.skip >= 0.5 then cdt, sub, ch.skip = ch.skip, 1, 0 else run = false end
			end
			if run then
				if idle then cIdle = cIdle + 1 else cAwake, cAwakeN = cAwake + 1, cAwakeN + ch.n end
				local mobile, live = 0, 0
				-- (what its wound has given since the last step, a part with every short step)
				local inflow = pose and ch.inflow
				if inflow then ch.inflow = nil end
				for _ = 1, sub do
					if inflow then Inflow(ch, s, src, pose, inflow / sub, now) end
					stampN = stampN + 1
					mobile, live = StepChannel(ch, s, pose, cdt, now, gx, gy, gz, gmag, stampN, gscale, tClot, tFilm, tWet)
					prof.nodeSteps = prof.nodeSteps + ch.n
				end
				if mobile < 1e-4 and not ch.head then ch.idleT = ch.idleT + cdt * sub else ch.idleT = 0 end
				if m and mobile > K.branchVol then
					ch.branchAcc = (ch.branchAcc or 0) + dt
					if ch.branchAcc >= 0.3 then
						ch.branchAcc = 0
						Branch(ch, s, src, pose, m, now, gx, gy, gz, gmag, stampN)
					end
				end
				-- dry, and nothing left to change: only a stain now
				if idle and live <= 0 and mobile <= 0 and now - ch.fedT > 3 and (ch.sinkAcc or 0) <= 0 then
					ch.done = true
					ch.meshDirty = true
				end
				prof.chans = prof.chans + 1
			end
		end
	end
	if s.sweep then
		s.sweep = nil
		for c = #chans, 1, -1 do
			local ch = chans[c]
			if ch.dissolve then
				WriteOff(ch, s)
				FreeChannel(ch, s)
				table.remove(chans, c)
			end
		end
		for c = 1, #chans do
			local ch = chans[c]
			if ch.joinCh and ch.joinCh.dead then ch.joinCh = nil end
			if ch.parentCh and ch.parentCh.dead then ch.parentCh = nil end
		end
		Reindex(s)
	end
end
FC.StepLiquid = StepLiquid
FC.FreeChannel = FreeChannel
FC.FreeHead = FreeHead
FC.Near = Near
FC.Reindex = Reindex

-- One body's flow over dt: its heads, then the liquid in its channels (allow: short steps at most).
local function StepSource(src, s, dt, allow, now, gx, gy, gz, gmag, gscale, tClot, tFilm, tWet)
	local pose, m = src.pose, src.mesh
	local simT = ABL.Sim.t
	local t0 = SysTime()
	local chans = s.chans
	for c = 1, #chans do
		local ch = chans[c]
		local hd = ch and ch.head
		if hd and not ch.dead then
			if not hd.tri or hd.tri > m.nt then
				local t = hd.vol + hd.film
				FC.Move("surface", "lost", t)
				s.bk.surface = s.bk.surface - t
				FreeHead(hd)
			elseif not hd.moving and hd.bage >= tClot and hd.vol > 0 then
				-- it has sat too long: the bead sets where it is
				local nn = ch.n
				local t = hd.vol
				ch.Cv[nn] = ch.Cv[nn] + t
				ch.F[nn] = ch.F[nn] + hd.film
				FC.Move("surface", "clotted", t)
				s.bk.surface, s.bk.clotted = s.bk.surface - t, s.bk.clotted + t
				-- (what stands there now is a clot: darker, drawn until blood runs over it again)
				if t > 0.004 then
					local cb = { hd.tri, hd.u, hd.v, m }
					cb.r = (t / ML / 1.28) ^ 0.3333 * 0.9
					ch.clotBead = cb
				end
				FreeHead(hd)
			else
				hd.ptri, hd.pu, hd.pv = hd.tri, hd.u, hd.v
				hd.lt, hd.sd = simT, dt
				if StepHead(hd, ch, s, src, pose, m, dt, gx, gy, gz, gmag, now) then
					-- a head with nothing left and nothing coming is no head: the stream ends there
					if hd.vol < B.minVol and not hd.moving and (ch.mobile or 0) < 0.002 and now - ch.fedT > 1.5 then
						hd.idle = hd.idle + dt
						if hd.idle > 2 then
							ch.F[ch.n] = ch.F[ch.n] + hd.vol + hd.film
							FreeHead(hd)
							-- (a drop that landed and never ran is a spot, no stream)
							if ch.n == 1 and not ch.wd and not ch.parentCh then
								local x, y, z, nx, ny, nz = pose:SkinPoint(ch.an[1])
								ABL.Stains.OnCharacter(src.body, x, y, z, nx, ny, nz, 0.03)
								Settle(ch, s)
								ch.dissolve, s.sweep = true, true
							end
						end
					else
						hd.idle = 0
					end
				end
			end
			prof.heads = prof.heads + 1
		end
	end
	local t1 = SysTime()
	prof.head = prof.head + (t1 - t0) * 1000
	StepLiquid(s, src, pose, m, dt, now, src.lod, gx, gy, gz, gmag, gscale, tClot, tFilm, tWet, allow)
	local t2 = SysTime()
	prof.chan = prof.chan + (t2 - t1) * 1000
	ABL.Prof.Add("sub.flow.heads", t1 - t0)
	ABL.Prof.Add("sub.flow.chans", t2 - t1)
end

-- Bodies whose flow is due this frame, most urgent first.
local due, nDue = {}, 0
local function MoreUrgent(a, b) return a.fcPrio > b.fcPrio end

-- All bodies, once per frame (h: the simulated time of the frame). One manager: no body, stream or
-- drop has a hook or a timer of its own. Each body collects the time since its last step and is
-- stepped with all of it; which bodies are stepped this frame is a matter of the budget:
--   the most important one (near, in view, bleeding hard, the local player) always;
--   the others in the order of their importance and of how long they have waited, while the
--   solver's share of abl_budget_ms lasts, and with no more short steps than it covers;
--   nobody waits longer than stepWait.
-- A body that waits is still drawn every frame, between its last two states.
function FC.Step(h)
	F = F or ABL.Flow
	Drops = Drops or ABL.Drops
	WS = WS or ABL.Wounds
	local Sim = ABL.Sim
	local gx, gy, gz, gmag = ABL.Gravity()
	local gscale = gmag / C.DEFAULT_GRAVITY
	local now = CurTime()
	local dryScale = C.sv.drying:GetFloat()
	local tClot, tFilm, tWet = K.clotTime * dryScale, K.filmDry * dryScale, K.wetTime * dryScale
	nDue = 0
	local ns0, nh0 = prof.nodeSteps, prof.heads
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.fc
		if s and #s.chans > 0 then
			local tier = C.LODTiers[src.lod]
			if tier and src.mesh and IsValid(src.body) then
				-- near bodies every frame; farther ones less often, with a longer step
				local hz = tier.bodyflow and tier.flowHz or K.farHz
				s.acc = s.acc + h
				if s.acc + 1e-6 >= Sim.Period(hz) then
					nDue = nDue + 1
					due[nDue] = src
					src.fcPrio = (src.importance or 0) * (1 + s.acc * 8) + (s.acc > K.stepWait and 100 or 0)
				end
				-- how far apart its nodes are laid: a few pixels at least, more under load
				local c = K.nodePx * (src.dist or 0) / ((L.pxK or 960) * K.spacing) / sqrt(max(L.scale, 0.25))
				s.coarse = c < 1 and 1 or (c > K.coarseMax and K.coarseMax or c)
			end
		end
	end
	for i = nDue + 1, #due do due[i] = nil end
	if nDue > 1 then table.sort(due, MoreUrgent) end
	-- What the frame affords, in node steps. A long frame holds more simulated time and gets as
	-- many more (from 30 frames per second down): a stream is then worked through in the same
	-- number of short steps per second of its own time as at a high frame rate. With one step's
	-- worth for a tenth of a second it carried a third of what it should, blood backed up on the
	-- body and poured off it, and a wound looked different at 10 frames per second than at 60.
	local left = K.stepShare * C.cl.budget:GetFloat() * 1000 / K.nodeCost * math.Clamp(h * 30, 1, 6)
	local stepped = 0
	for i = 1, nDue do
		local src = due[i]
		local s = src.fc
		if i == 1 or left > 0 or s.acc > K.stepWait then
			local allow = math.floor(left / max(s.nodes, 1))
			if allow < 1 then allow = 1 elseif allow > K.maxSub then allow = K.maxSub end
			-- (the most important body gets two short steps at least: its fast streams stay smooth)
			if i == 1 and allow < 2 then allow = 2 end
			local dt = s.acc
			if dt > 0.3 then dt = 0.3 end
			s.acc = 0
			local before = prof.nodeSteps
			StepSource(src, s, dt, allow, now, gx, gy, gz, gmag, gscale, tClot, tFilm, tWet)
			left = left - (prof.nodeSteps - before) - 14 * #s.chans
			stepped = stepped + 1
		end
	end
	FC.stepped, FC.due = stepped, nDue
	ABL.Prof.Count("node steps", prof.nodeSteps - ns0)
	ABL.Prof.Count("ch awake", cAwake) ABL.Prof.Count("nodes awake", cAwakeN) ABL.Prof.Count("ch idle stepped", cIdle)
	cAwake, cAwakeN, cIdle = 0, 0, 0
	ABL.Prof.Count("head steps", prof.heads - nh0)
	-- wet stains off the body dry as one
	local sw = FC.stainWet
	if sw > 0 then
		local d = sw * min(1, h / (K.stainDry * dryScale))
		FC.stainWet = sw - d
		FC.Move("surface", "dried", d)
	end
end

-- Impulse on a bone (ragdoll collision): heads on that bone are shaken off, and the blood in the
-- channel there with them.
function FC.Shake(src, bone, speed, nx, ny, nz)
	local s = src.fc
	local m = src.mesh
	if not s or not m then return end
	Drops = Drops or ABL.Drops
	local pose = src.pose
	local frac = math.Clamp(speed / 600, 0.2, 0.9)
	for c = 1, #s.chans do
		local ch = s.chans[c]
		local hd = ch.head
		if hd and not ch.dead and hd.tri and hd.tri <= m.nt and m.tb[hd.tri] == bone and hd.vol > 0.015 then
			local px, py, pz, snx, sny, snz = pose:Point(hd.tri, hd.u, hd.v)
			local sp = speed * 0.25
			hd.vx, hd.vy, hd.vz = -nx * sp * 0.3, -ny * sp * 0.3, -nz * sp * 0.3
			hd.stuckT = 0
			Detach(hd, s, src, hd.vol * frac, px, py, pz, snx, sny, snz, 0, 0, 0, max(sp * 0.3, 4))
		end
	end
end

------------------------------------------------------------------------------------------
-- Measurements (developer profiler, test harness)
------------------------------------------------------------------------------------------
-- Totals over all characters: channels, channels with liquid in them, nodes with liquid, heads.
function FC.Counts()
	local chans, active, cells, heads, joined = 0, 0, 0, 0, 0
	local states = {}
	for _, src in ipairs(ABL.Sources.list) do states[#states + 1] = src.fc end
	for _, reg in ipairs(ABL.FlowWorld.regions) do states[#states + 1] = reg.fc end
	for _, s in ipairs(states) do
		do
			for c = 1, #s.chans do
				local ch = s.chans[c]
				chans = chans + 1
				if (ch.mobile or 0) > 1e-4 or ch.head then active = active + 1 end
				local V = ch.V
				for i = 1, ch.n do if V[i] > 1e-6 then cells = cells + 1 end end
				if ch.head then heads = heads + 1 end
				if ch.joinCh then joined = joined + 1 end
			end
		end
	end
	return chans, active, cells, heads, joined
end

-- The measures of one channel that say whether it is a stream: its length, how its width and height
-- vary along the wet part, whether the wet part is in one piece, and the mass it holds.
function FC.Measure(ch)
	local n = ch.n
	local V, w, h = ch.V, ch.w, ch.h
	local wetN, sw, sw2, sh2, shs, gaps, inWet, mobile, maxV = 0, 0, 0, 0, 0, 0, false, 0, 0
	local first, last = nil, nil
	for i = 1, n do
		if V[i] > 1e-5 then
			wetN = wetN + 1
			sw, sw2 = sw + w[i], sw2 + w[i] * w[i]
			shs, sh2 = shs + h[i], sh2 + h[i] * h[i]
			first = first or i
			last = i
			mobile = mobile + V[i]
			if V[i] > maxV then maxV = V[i] end
		end
	end
	-- dry nodes between the first and the last wet one: breaks in the stream
	if first then
		for i = first, last do if V[i] <= 1e-5 then gaps = gaps + 1 end end
	end
	local mw = wetN > 0 and sw / wetN or 0
	local mh = wetN > 0 and shs / wetN or 0
	return {
		nodes = n, length = ch.dist[n] or 0, wet = wetN, gaps = gaps,
		width = mw, widthSd = wetN > 1 and sqrt(max(sw2 / wetN - mw * mw, 0)) or 0,
		height = mh, heightSd = wetN > 1 and sqrt(max(sh2 / wetN - mh * mh, 0)) or 0,
		mobile = mobile, head = ch.head and ch.head.vol or 0, tip = ch.qTip or 0,
	}
end

-- Developer: which model a character's body blood uses (abl_dev_compare on the server, or
-- abl_flow_legacy <0/1> for the character under the crosshair; needs abl_dev 1).
local function SetLegacy(ent, legacy)
	if not IsValid(ent) then return end
	ent.ablFlowLegacy = legacy and true or nil
	-- (blood already on the body belongs to the other model: it starts again)
	local src = ABL.Sources.byKey[ent]
	if src then
		for i = #src.blobs, 1, -1 do ABL.Flow.FreeBlob(src.blobs[i]) end
		src.blobs = {}
		ABL.Flow.FreeSegs(src)
		FC.FreeSource(src)
		if ABL.Film then ABL.Film.FreeSource(src) end
		if (src.lbk or 0) > 0 then FC.Move("surface", "lost", src.lbk) end
		src.lbk = nil
		for _, w in pairs(src.wounds) do w.bead = nil w.chan = nil end
	end
end
net.Receive(ABL.Net.DEV, function()
	local ent = Entity(net.ReadUInt(13))
	SetLegacy(ent, net.ReadBool())
end)
concommand.Add("abl_flow_legacy", function(ply, _, args)
	if not C.sv.dev:GetBool() then print("abl_flow_legacy requires abl_dev 1") return end
	local ent = ply:GetEyeTrace().Entity
	local owner = IsValid(ent) and ABL.ZC.GetOwner(ent)
	if IsValid(owner) then ent = owner end
	if not IsValid(ent) then ent = ply end
	SetLegacy(ent, args[1] ~= "0")
	print("body blood of " .. tostring(ent) .. ": " .. (args[1] ~= "0" and "older bead model" or "the film (abl_body_film 1) or the flow core's streams"))
end)

-- (ABL.ClearAll clears the channels on the world before this: their nodes are counted here too)
function FC.Clear()
	for _, src in ipairs(ABL.Sources.list) do FC.FreeSource(src) end
	FC.nodes, FC.heads = 0, 0
	FC.stainWet = 0
	FC.ResetBooks()
end
