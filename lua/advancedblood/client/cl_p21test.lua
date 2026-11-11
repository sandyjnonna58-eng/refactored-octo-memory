-- Client half of the scenes of phase 21 (server/sv_p21test.lua; developer tool, inert unless the test
-- harness is running): ground pools that grow from the blood that reaches them. What each pool holds,
-- covers and does, every few seconds, in the harness log; where the same blood is shown twice (a drop's
-- stain that still stands as liquid under a pool that has taken its blood); whether one drop ever
-- lands twice; the pools' books against what the pools hold; checks that log PASS or FAILED.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local min, max, abs, sqrt, floor = math.min, math.max, math.abs, math.sqrt, math.floor
local MM = ABL.Config.MM_PER_UNIT
local ML = ABL.Config.ML_PER_CU

------------------------------------------------------------------------------------------
-- One drop, one landing
------------------------------------------------------------------------------------------
-- Every drop that reaches a surface goes through ABL.Impacts.Handle once (cl_droplets.lua, Collide).
-- Counted by the drop's number while t.on: a number seen twice is one drop that landed twice.
local imp = { on = false, seen = {}, n = 0, twice = 0, pool = 0, ground = 0, ml = 0 }
local origHandle
function H.p21impacts(t)
	local I = ABL.Impacts
	if t.on and not origHandle then
		origHandle = I.Handle
		I.Handle = function(d, tr)
			if imp.on then
				local id = d.id
				if imp.seen[id] then
					imp.twice = imp.twice + 1
					Log(string.format("FAILED p21 one landing: drop %s (%.4f ml) reached a surface a second time", tostring(id), d.vol or 0))
				end
				imp.seen[id] = true
				imp.n = imp.n + 1
				imp.ml = imp.ml + (d.vol or 0)
			end
			return origHandle(d, tr)
		end
	end
	imp.on = t.on and true or false
	if t.reset then imp.seen, imp.n, imp.twice, imp.ml = {}, 0, 0, 0 end
	Log(string.format("p21impacts %s: %d landings so far (%.2f ml), %d of them a second landing of one drop", imp.on and "on" or "off", imp.n, imp.ml, imp.twice))
end

------------------------------------------------------------------------------------------
-- What a pool is now
------------------------------------------------------------------------------------------
-- The lattice's figures: wet and covered area (units^2), mean and deepest wet layer (units), how
-- many separate wet regions (four-neighbour), the wet cells' extent along the pool's own axes.
local function Lattice(p)
	local g = p.sim
	local r = { wet = 0, cov = 0, mean = 0, max = 0, regions = 0, cells = 0, a = 0, n = 0 }
	if not g then return r end
	local n, a = g.n, g.a
	local h, k, s, ab = g.h, g.k, g.s, g.ab
	local film = g.film
	local wetN, covN, sum = 0, 0, 0
	local lab = {}
	for j = max(g.by0, 0), min(g.by1, n - 1) do
		for i = max(g.bx0, 0), min(g.bx1, n - 1) do
			local c = j * n + i + 1
			local w = h[c] + k[c]
			if w + s[c] + ab[c] > film * 0.1 then covN = covN + 1 end
			if w > film * 0.1 then
				wetN = wetN + 1
				sum = sum + w
				if w > r.max then r.max = w end
			end
		end
	end
	-- (regions: wet cells joined side by side)
	local regions = 0
	for j = max(g.by0, 0), min(g.by1, n - 1) do
		for i = max(g.bx0, 0), min(g.bx1, n - 1) do
			local c0 = j * n + i + 1
			if not lab[c0] and h[c0] + k[c0] > film * 0.1 then
				regions = regions + 1
				local st, sp = { c0 }, 1
				lab[c0] = regions
				while sp > 0 do
					local q = st[sp]
					st[sp] = nil
					sp = sp - 1
					local qi = (q - 1) % n
					for d = 1, 4 do
						local o = (d == 1 and qi > 0 and q - 1) or (d == 2 and qi < n - 1 and q + 1) or (d == 3 and q > n and q - n) or (d == 4 and q <= n * (n - 1) and q + n) or nil
						if o and not lab[o] and h[o] + k[o] > film * 0.1 then
							lab[o] = regions
							sp = sp + 1
							st[sp] = o
						end
					end
				end
			end
		end
	end
	local aa = a * a
	r.wet, r.cov, r.mean, r.regions, r.cells, r.a, r.n = wetN * aa, covN * aa, wetN > 0 and sum / wetN or 0, regions, wetN, a, n
	r.film = film
	return r
end

-- Is the place (x, y, z) under pool p's layer as its picture shows it (PS.Shown: the cell holds half a
-- film of wet blood and three of its sides hold blood; the picture leaves a lone cell out)?
local function UnderPool(p, x, y, z)
	local g = p.sim
	if not g then return false end
	local rx, ry, rz = x - p.x, y - p.y, z - p.z
	if abs(rx * p.nx + ry * p.ny + rz * p.nz) > 1 then return false end
	local u, v = rx * p.sx + ry * p.sy + rz * p.sz, rx * p.tx + ry * p.ty + rz * p.tz
	local PS = ABL.PoolSim
	if PS.Shown then return PS.Shown(g, u, v) end
	return PS.Covers(g, u, v, 0) == true
end

local snaps = {}

-- The pools within t.r units of t.near (all, without t.near), their figures, the drops collecting
-- toward a pool there, the stains there and how many of their bodies of liquid lie under a pool.
-- Kept under t.name for the checks (H.p21check).
local function Snapshot(t, tag)
	local P = ABL.Pools
	local now = CurTime()
	local near, r = t.near, t.r or 60
	local out = { t = now, pools = {}, n = 0, vol = 0, wet = 0, cov = 0, inTot = 0, outTot = 0, dried = 0, soaked = 0, regions = 0 }
	for _, p in ipairs(P.list) do
		local px, py, pz = p.cx or p.x, p.cy or p.y, p.cz or p.z
		if not near or (px - near.x) ^ 2 + (py - near.y) ^ 2 + (pz - near.z) ^ 2 < (r + (p.rad or 0)) ^ 2 then
			local L = Lattice(p)
			-- (held: what lies in it and what has crossed its edge and waits to be handed to a stream,
			-- runAcc; out: what it handed on and what was written off, lostTot. What the floor took up at
			-- the pool's full width, capTot, never came in: P.Feed)
			local e = { id = p.id, owner = p.owner, vol = p.vol + (p.runAcc or 0), inTot = p.inTot, outTot = p.outTot + (p.lostTot or 0), dried = p.driedTot, soaked = p.soakTot,
				wet = L.wet, cov = L.cov, mean = L.mean, max = L.max, regions = L.regions, a = L.a, n = L.n, film = L.film, wetness = p.wet,
				moving = p.sim and ABL.PoolSim.Active(p.sim) or false, painted = p.painted, born = p.born, leaving = p.leaving and true or false }
			if p.sim and p.slope > 0.003 then
				e.down, e.up = ABL.PoolSim.Extent(p.sim, p.du, p.dv), ABL.PoolSim.Extent(p.sim, -p.du, -p.dv)
			end
			out.pools[#out.pools + 1] = e
			out.n = out.n + 1
			out.vol, out.wet, out.cov = out.vol + e.vol, out.wet + e.wet, out.cov + e.cov
			out.inTot, out.outTot, out.dried, out.soaked = out.inTot + e.inTot, out.outTot + e.outTot, out.dried + (e.dried or 0), out.soaked + (e.soaked or 0)
			out.regions = out.regions + e.regions
		end
	end
	if near then
		out.seeds, out.seedVol = P.SeedsNear(near.x, near.y, near.z, r)
		local function Inside(x, y, z)
			for _, p in ipairs(P.list) do
				if UnderPool(p, x, y, z) then return true end
			end
			return false
		end
		out.stains, out.bodies, out.bodyVol, out.under = ABL.Ground.BodiesNear(near.x, near.y, near.z, r, Inside)
	end
	-- the pools' books: what they are booked to hold against what they hold (cl_flowcore.lua)
	local BK = ABL.FlowCore.Books
	out.booked, out.held = BK.pool, P.Volume()
	snaps[tag] = out
	return out
end

local function Line(name, s)
	Log(string.format("p21 %s | %d pool(s): %.2f ml wet, covering %.2f units^2 (wet %.2f), %d wet region(s) | in %.2f out %.2f dried %.2f soaked %.2f | collecting %s cell(s) %.2f ml | stains %s, %s with a body (%.3f ml), %s of those under a pool | books: pools booked %.3f ml, held %.3f ml",
		name, s.n, s.vol, s.cov, s.wet, s.regions, s.inTot, s.outTot, s.dried, s.soaked, tostring(s.seeds or "-"), s.seedVol or 0, tostring(s.stains or "-"), tostring(s.bodies or "-"), s.bodyVol or 0, tostring(s.under or "-"), s.booked, s.held))
	for i, e in ipairs(s.pools) do
		if i > 4 then break end
		Log(string.format("     pool %d (%s): %.2f ml | wet %.2f units^2 covering %.2f | %.2f mm deep on average (%.2f films), %.2f at most | %d region(s) | cells %.2f x %d | in %.2f out %.2f dried %.2f soaked %.2f | wetness %.2f %s%s",
			e.id, tostring(e.owner), e.vol, e.wet, e.cov, e.mean * MM, e.film and e.mean / e.film or 0, e.max * MM, e.regions, e.a, e.n, e.inTot, e.outTot, e.dried or 0, e.soaked or 0, e.wetness,
			e.moving and "moving" or "at rest", e.down and string.format(" | reach downhill %.2f uphill %.2f", e.down, e.up) or ""))
	end
end

-- A snapshot now (t.name), logged.
function H.p21snap(t)
	Line(tostring(t.name), Snapshot(t, tostring(t.name)))
end

-- Snapshots every t.every seconds for t.secs seconds, named <t.name>_<seconds since>.
function H.p21watch(t)
	local t0 = CurTime()
	local id = "ABL_P21Watch_" .. tostring(t.name)
	timer.Create(id, t.every or 2, math.ceil((t.secs or 30) / (t.every or 2)), function()
		local name = string.format("%s_%03d", tostring(t.name), floor(CurTime() - t0 + 0.5))
		Line(name, Snapshot(t, name))
	end)
end

local function Check(ok, what, detail)
	Log(string.format("%s p21 %s: %s", ok and "PASS" or "FAILED", what, detail))
end

-- Checks between snapshots (t.from, t.to) or of one (t.at):
--   "none"     no pool and nothing collecting (t.at): a wound alone makes no pool
--   "small"    the first pool holds no more than what has arrived (t.most ml) and covers little (t.area)
--   "grow"     covers more by t.k (and t.minArea units^2 at least) and received more
--   "still"    received no more than t.most ml and covers no more than t.k more (the source stopped)
--   "persist"  still holds wet or set blood and covers at least t.k of what it covered
--   "books"    the pools' books against what they hold, within t.most ml (t.at)
--   "one"      one wet region (t.at): two pools that met are one liquid
--   "double"   no stain's body of liquid under a pool (t.at), t.most at the most
--   "landing"  no drop landed twice
--   "conserve" in - out = held + dried + soaked within t.most ml (t.at)
function H.p21check(t)
	local kind = tostring(t.kind)
	local a, b = snaps[t.from or ""], snaps[t.to or t.at or ""]
	local name = string.format("%s %s%s", kind, t.from and (tostring(t.from) .. "..") or "", tostring(t.to or t.at))
	if kind == "landing" then
		Check(imp.twice == 0, name, string.format("%d landings, %.2f ml; %d drop(s) landed a second time", imp.n, imp.ml, imp.twice))
		return
	end
	if not b then Check(false, name, "no snapshot " .. tostring(t.to or t.at)) return end
	if kind == "none" then
		Check(b.n == 0, name, string.format("%d pool(s), %s cell(s) of drops collecting (%.2f ml)", b.n, tostring(b.seeds or 0), b.seedVol or 0))
	elseif kind == "small" then
		local e = b.pools[1]
		local area = e and e.cov or 0
		Check(e ~= nil and e.vol <= (t.most or 3) and area <= (t.area or 6), name, e and string.format("the first pool holds %.2f ml (allowed %.2f) over %.2f units^2 (allowed %.2f), %d region(s)", e.vol, t.most or 3, area, t.area or 6, e.regions) or "no pool")
	elseif kind == "books" then
		local d = abs(b.booked - b.held)
		Check(d <= (t.most or 0.01), name, string.format("booked %.4f ml, held %.4f ml: off by %.4f (allowed %.4f)", b.booked, b.held, d, t.most or 0.01))
	elseif kind == "one" then
		Check(b.n >= 1 and b.regions == 1, name, string.format("%d pool(s), %d wet region(s)", b.n, b.regions))
	elseif kind == "double" then
		Check((b.under or 0) <= (t.most or 0), name, string.format("%s stain(s) with a body of liquid, %s of them under a pool that holds their blood (allowed %d), %.3f ml in those bodies",
			tostring(b.bodies), tostring(b.under), t.most or 0, b.bodyVol or 0))
	elseif kind == "conserve" then
		local d = abs((b.inTot - b.outTot) - (b.vol + b.dried + b.soaked))
		Check(d <= (t.most or 0.05), name, string.format("in %.3f - out %.3f = %.3f; held %.3f + dried %.3f + soaked %.3f = %.3f (off by %.4f)",
			b.inTot, b.outTot, b.inTot - b.outTot, b.vol, b.dried, b.soaked, b.vol + b.dried + b.soaked, d))
	else
		if not a then Check(false, name, "no snapshot " .. tostring(t.from)) return end
		if kind == "grow" then
			local need = max(a.cov * (t.k or 0.2), t.minArea or 1)
			Check(b.cov >= a.cov + need and b.inTot > a.inTot, name, string.format("covers %.2f -> %.2f units^2 (wanted %.2f more), wet %.2f -> %.2f ml, received %.2f -> %.2f ml over %.1f s",
				a.cov, b.cov, need, a.vol, b.vol, a.inTot, b.inTot, b.t - a.t))
		elseif kind == "still" then
			local most, k = t.most or 0.2, t.k or 0.05
			Check(b.inTot - a.inTot <= most and b.cov <= a.cov * (1 + k) + 0.5, name, string.format("received %.3f ml (allowed %.3f); covers %.2f -> %.2f units^2 (allowed %.0f%% more); wet %.2f -> %.2f ml over %.1f s",
				b.inTot - a.inTot, most, a.cov, b.cov, k * 100, a.vol, b.vol, b.t - a.t))
		elseif kind == "persist" then
			local k = t.k or 0.8
			Check(b.n >= 1 and b.cov >= a.cov * k, name, string.format("%d -> %d pool(s), covering %.2f -> %.2f units^2 (at least %.0f%% wanted), holding %.2f -> %.2f ml wet, dried %.2f, soaked %.2f",
				a.n, b.n, a.cov, b.cov, k * 100, a.vol, b.vol, b.dried, b.soaked))
		end
	end
end

-- Two clients (the harness's host and a second game on the same machine, tools/harness/harness.ps1
-- -Peer): each writes what its own pools are every 5 s, to a file of its own (the host
-- abl_test/mp_host.txt, the other abl_test/mp_peer.txt), so that the two can be laid side by side.
-- Pools are each client's own (the server sends the wounds, every client simulates the blood): what
-- the files show is how far two clients' pools agree, by owner and place.
local mpNext = 0
hook.Add("Think", "ABL_P21MP", function()
	local now = CurTime()
	if now < mpNext then return end
	mpNext = now + 5
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local host = lp:IsListenServerHost()
	local name = host and "abl_test/mp_host.txt" or "abl_test/mp_peer.txt"
	local P = ABL.Pools
	local parts = {}
	local byOwner = {}
	for _, p in ipairs(P.list) do
		local L = Lattice(p)
		local key = tostring(p.owner)
		local e = byOwner[key] or { n = 0, vol = 0, cov = 0, inTot = 0 }
		e.n, e.vol, e.cov, e.inTot = e.n + 1, e.vol + p.vol, e.cov + L.cov, e.inTot + p.inTot
		byOwner[key] = e
		if #parts < 8 then
			parts[#parts + 1] = string.format("%s @ %.0f %.0f %.0f: %.1f ml, %.1f u2, in %.1f", key, p.cx or p.x, p.cy or p.y, p.cz or p.z, p.vol, L.cov, p.inTot)
		end
	end
	local own = {}
	for k, e in pairs(byOwner) do own[#own + 1] = string.format("%s: %d pool(s) %.1f ml %.1f u2 in %.1f", k, e.n, e.vol, e.cov, e.inTot) end
	table.sort(own)
	local BK = ABL.FlowCore.Books
	file.Append(name, string.format("%8.2f | %s | pools %d | by owner: %s | pools: %s | books pool %.2f released %.2f lost %.3f | ground stains %d\n",
		now, tostring(lp), #P.list, table.concat(own, " ; "), table.concat(parts, " ; "), BK.pool, BK.released, BK.lost, ABL.Ground.Count()))
end)

-- The pools' mirror: what it did (t.debug: its developer view, abl_pool_mirror_debug).
function H.p21mirror(t)
	if t.debug then RunConsoleCommand("abl_pool_mirror_debug", tostring(t.debug)) end
	local PM = ABL.PoolMirror
	-- (and who answers RenderScene now: Z-City's "jopa" is away while the harness runs, H.zview)
	local names = {}
	for k in pairs(hook.GetTable().RenderScene or {}) do names[#names + 1] = tostring(k) end
	table.sort(names)
	Log("p21mirror " .. tostring(t.name) .. ": " .. (PM and PM.Info() or "no mirror") .. " | RenderScene hooks: " .. table.concat(names, ", "))
end

-- The world streams (cl_flowworld.lua): what each channel holds and the figures of its nodes, and,
-- from the next frame's drawing (cl_flowdraw.lua, FD.tap), the sections its strips were drawn
-- through: half-widths and lookup rows of the stain and of the liquid, and their colours.
function H.p21streams(t)
	local FW, FD = ABL.FlowWorld, ABL.FlowDraw
	local name = tostring(t.name)
	for ri, reg in ipairs(FW.regions) do
		local st = reg.fc
		Log(string.format("p21streams %s region %d: dist %.1f lod %s, %d channel(s), %d nodes, light %.2f %.2f %.2f", name, ri, reg.dist or -1, tostring(reg.lod), #st.chans, st.nodes, reg.lr or 0, reg.lg or 0, reg.lb or 0))
		for _, ch in ipairs(st.chans) do
			local sV, sF, sD, sC, mV, wetN = 0, 0, 0, 0, 0, 0
			for i = 1, ch.n do
				sV, sF, sD, sC = sV + ch.V[i], sF + ch.F[i], sD + ch.D[i], sC + ch.Cv[i]
				if ch.V[i] > mV then mV = ch.V[i] end
				if ch.V[i] > 1e-6 and ch.h[i] > 1e-5 then wetN = wetN + 1 end
			end
			local hd = ch.head
			Log(string.format("   ch %d: n %d length %.1f | V %.3f ml (most at a node %.4f) F %.3f D %.3f Cv %.3f | wet nodes %d | head %s | parent %s join %s sink %s | done %s idle %.1f",
				ch.id, ch.n, ch.dist[ch.n] or 0, sV, mV, sF, sD, sC, wetN,
				hd and string.format("%.3f ml film %.3f %s %.2f u/s bead %s", hd.vol, hd.film, tostring(hd.state), sqrt(hd.vx * hd.vx + hd.vy * hd.vy + hd.vz * hd.vz),
					hd.bead and string.format("%.3f", hd.bead) or "-") or "none",
				ch.parentCh and tostring(ch.parentCh.id) or "-", ch.joinCh and (tostring(ch.joinCh.id) .. ":" .. tostring(ch.joinIdx)) or "-",
				ch.sink and string.format("%.3f", ch.sinkAcc or 0) or "-", tostring(ch.done), ch.idleT or 0))
			local parts = {}
			local step = max(1, floor(ch.n / 16))
			for i = 1, ch.n, step do
				parts[#parts + 1] = string.format("%d V%.4f F%.4f h%.4f w%.3f wm%.3f L%.2f u%.1f", i, ch.V[i], ch.F[i], ch.h[i], ch.w[i], ch.wmax[i], ch.Lc[i], ch.us[i])
			end
			Log("      nodes: " .. table.concat(parts, " | "))
		end
	end
	local frame = FrameNumber()
	FD.tap = function(src, A, N, near, gloss, lines, halo)
		if FrameNumber() > frame + 3 then FD.tap = nil return end
		if not src.world then return end
		FD.tap = nil
		local VW = ABL.Flow.VW
		Log(string.format("p21streams %s drawn: %d sections | near %s gloss %s lines %s halo %s | dist %.1f | light %.2f %.2f %.2f, the liquid's %s | streamLiquid %s",
			name, N, tostring(near), tostring(gloss), tostring(lines), tostring(halo), src.dist or -1, VW.lr or 0, VW.lg or 0, VW.lb or 0,
			VW.mr and string.format("%.2f %.2f %.2f", VW.mr, VW.mg, VW.mb) or "-", tostring(ABL.Config.P21On("streamLiquid"))))
		local parts = {}
		local step = max(1, floor(N / 40))
		for k = 1, N, step do
			parts[#parts + 1] = string.format("%d%s S%s %.3f r%.2f (%.0f %.0f %.0f %.0f) W%s %.3f r%.2f d%.4f (%.0f %.0f %.0f %.0f) own (%.0f %.0f %.0f)", k, A.BRK[k] and "|" or "",
				A.SON[k] and "+" or "-", A.SH[k] or 0, A.SV[k] or 0, A.SR[k] or 0, A.SG[k] or 0, A.SB[k] or 0, A.SA[k] or 0,
				A.WON[k] and "+" or "-", A.WH[k] or 0, A.WV[k] or 0, A.WD[k] or 0, A.WR[k] or 0, A.WG[k] or 0, A.WB[k] or 0, A.WA[k] or 0,
				A.BR[k] or 0, A.BG[k] or 0, A.BB[k] or 0)
		end
		for q = 1, #parts, 8 do Log("      " .. table.concat(parts, " | ", q, min(q + 7, #parts))) end
	end
end

-- The heads of the world streams (cl_flowworld.lua), looked at every frame from t.on until a call
-- without it: the most a head held while it ran, while it hung and while it stood, and while its stream
-- was fed (blood put into it within the last second); how often a head held over 0.5 ml; the most
-- channels at once, how many there were in all, and how many of them were fingers split off a head.
local hw = { run = {}, hang = {}, stop = {}, fed = {}, fill = {} }
local hwSeen = setmetatable({}, { __mode = "k" })
local function HeadMost(e, v, t, id)
	if v > e.v then e.v, e.t, e.id = v, t, id end
end
local function HeadLook()
	local FW = ABL.FlowWorld
	local now = CurTime()
	local t = now - hw.t0
	hw.looks = hw.looks + 1
	local heads = FW.list
	for i = 1, #heads do
		local r = heads[i]
		local v, ch = r.vol, r.chan
		local id = ch and ch.id or -1
		HeadMost(r.state == "hang" and hw.hang or (r.moving and hw.run or hw.stop), v, t, id)
		if ch and now - (ch.fedT or 0) < 1 then HeadMost(hw.fed, v, t, id) end
		-- (what stands at the end of a running head's stream: cl_flowcore.lua lets what is over a
		-- rivulet's worth there into the head)
		if ch and r.moving and ch.n >= 1 then HeadMost(hw.fill, ch.V[ch.n] - ch.hold[ch.n], t, id) end
		if v > 0.5 then hw.over = hw.over + 1 end
		hw.heads = hw.heads + 1
	end
	local nc = 0
	local regs = FW.regions
	for ri = 1, #regs do
		local chans = regs[ri].fc.chans
		nc = nc + #chans
		for c = 1, #chans do
			local ch = chans[c]
			if not hwSeen[ch] then
				hwSeen[ch] = true
				hw.all = hw.all + 1
				if ch.parentCh then hw.fingers = hw.fingers + 1 end
			end
		end
	end
	if nc > hw.most then hw.most, hw.mostT = nc, t end
end
function H.p21heads(t)
	if t.on then
		hw.t0, hw.name, hw.looks, hw.heads, hw.over, hw.most, hw.mostT, hw.all, hw.fingers = CurTime(), tostring(t.name), 0, 0, 0, 0, 0, 0, 0
		for _, e in ipairs({ hw.run, hw.hang, hw.stop, hw.fed, hw.fill }) do e.v, e.t, e.id = 0, 0, -1 end
		for k in pairs(hwSeen) do hwSeen[k] = nil end
		hook.Add("Think", "ABL_P21Heads", HeadLook)
		return
	end
	hook.Remove("Think", "ABL_P21Heads")
	if not hw.t0 then return end
	local function F(e) return string.format("%.3f ml (ch %d at %.1f s)", e.v, e.id, e.t) end
	Log(string.format("p21heads %s: over %.1f s, %d looks at %d heads | most a head held: running %s, hanging %s, standing %s; while its stream was fed %s | over 0.5 ml in %d of %d | channels at most %d at once (at %.1f s), %d in all, %d of them fingers | most at the end of a running head's stream %s | streamHead %s",
		hw.name, CurTime() - hw.t0, hw.looks, hw.heads, F(hw.run), F(hw.hang), F(hw.stop), F(hw.fed), hw.over, hw.heads, hw.most, hw.mostT, hw.all, hw.fingers,
		F(hw.fill), tostring(ABL.Config.P21On("streamHead"))))
end

-- An entry of C.P21 for the scenes that follow (t.name, t.value), as sh_config.lua would have it;
-- t.restore: back to what it was before the first change.
local p21kept = {}
function H.p21set(t)
	local P21 = ABL.Config.P21
	local was = P21[t.name]
	if t.restore then
		if p21kept[t.name] ~= nil then P21[t.name], p21kept[t.name] = p21kept[t.name], nil end
	else
		if p21kept[t.name] == nil then p21kept[t.name] = was end
		P21[t.name] = t.value
	end
	Log(string.format("p21set %s: %s (was %s)", tostring(t.name), tostring(P21[t.name]), tostring(was)))
end

-- (developer) Whether pictures can be taken now: whether the game's window has the focus and whether
-- render.Capture and render.CapturePixels / render.ReadPixel give anything. (Every shot of the runs of
-- 2026-10-20 from 17:46 to 18:50 failed while another program, a game, was the foreground window;
-- with a browser in front and no focus here they all worked, run p21s_look0.)
function H.p21captest(t)
	hook.Add("PostRender", "ABL_P21CapTest", function()
		hook.Remove("PostRender", "ABL_P21CapTest")
		local cap = render.Capture({ format = "jpeg", quality = 90, x = 0, y = 0, w = 64, h = 64 })
		local ok, r, g, b = pcall(function()
			render.CapturePixels()
			return render.ReadPixel(floor(ScrW() / 2), floor(ScrH() / 2))
		end)
		Log(string.format("p21captest %s: window has the focus %s | render.Capture %s | render.CapturePixels and ReadPixel %s: %s %s %s",
			tostring(t.name), tostring(system.HasFocus and system.HasFocus()), cap and (#cap .. " bytes") or "nothing", ok and "ran" or "failed", tostring(r), tostring(g), tostring(b)))
	end)
end

-- The view from where it is put (as H.view), kept as t.name; t.use: that view again.
local cams = {}
function H.p21cam(t)
	if t.use then
		local v = cams[t.use]
		if v then H.view(v) end
		return
	end
	local v = { pos = t.pos, ang = (t.look - t.pos):Angle(), fov = t.fov or 60 }
	cams[t.name or "?"] = v
	H.view(v)
end
