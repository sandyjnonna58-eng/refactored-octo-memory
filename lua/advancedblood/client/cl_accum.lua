-- Accumulation (phase 18, 2026-10-14): where wet blood gathers on a body (the film, cl_film.lua)
-- and on the floor (the pools, cl_pools.lua), how much each place holds, what comes into it and
-- goes out of it, and whether it grows, stands or shrinks. Everything here is read from the
-- simulation's own state; nothing is drawn from a timer.
--
-- A region of a film is a connected stretch of cells that hold wet blood (liquid and set blood)
-- more than DEPTH above their residual film: a run, a sheet, the blood standing in a hollow. Its
-- quantity is what those cells hold (ml). While a film is measured, the film counts what crosses
-- from one region to another at the transfer itself, what arrives in each from outside (a wound's
-- opening, a drop that lands), what leaves it (to the edge it drips from, or the floor), and what
-- soaks into the cloth and dries there (cl_film.lua: s.trk, s.rid). Between two measurements the
-- regions are held fixed, so for every region
--     held now - held then = arrived + crossed in - crossed out - left - soaked in - dried
-- has to come out exactly: a region that grew without blood coming in, or that lost blood that went
-- nowhere, would show here (A.err). Then the cells are grouped anew; a region keeps its number
-- while most of its blood is still in it, so one place can be followed over minutes.
-- A pool is one region: its lattice's wet blood, what came in (p.inTot) and what went out, dried
-- or soaked in.
-- The developer's view (abl_dev_acc 1, with abl_dev 1 or under the test harness) draws, for every
-- film and pool: each region's outline in the colour of what it does (green: growing, white:
-- standing, orange: losing), how deep the blood stands in it (a tick on the surface as long as the
-- blood is deep, times 40), which way it runs and how fast (arrows), where blood leaves the body as
-- drops or seeps onto the floor, and where it lands; and a label with what the region holds, how fast
-- that changes, and what comes in and goes out. Off in ordinary play.

ABL.NoJIT()
ABL.Accum = ABL.Accum or {}
local A = ABL.Accum
local C = ABL.Config
local K = C.Film
local ML = C.ML_PER_CU
local floor, min, max, abs, sqrt = math.floor, math.min, math.max, math.abs, math.sqrt

A.cvView = CreateClientConVar("abl_dev_acc", "0", false, false, "Developer (needs abl_dev 1): where blood gathers on bodies and on the floor: each region's outline in the colour of what it does (green growing, white standing, orange losing), how deep it stands, which way it runs, where it leaves and lands, and what each region holds, gains and loses. 2: with the cells under a lying body.", 0, 2)

A.EVERY = 0.5       -- s between two measurements of a film
A.DEPTH = 0.002     -- units of wet blood above a place's residual film from which it belongs to a region
A.POOLED = 0.025    -- units: a region whose blood stands deeper than this on average holds it (an accumulation;
                    -- a run down a chest is about 0.015 deep, 0.3 mm, on the bench)
A.STILL = 0.01      -- ml a second: a region that gains or loses less than this stands
A.err = A.err or 0          -- the largest error of a region's books since asked (ml)
A.errFlow = A.errFlow or 0  -- ... and what moved through that region in that interval (ml)
A.events = A.events or {}

local tracking = false
function A.Tracking() return tracking end

-- Count where blood goes, region by region (on: true), or not (the film then counts nothing).
function A.Track(on)
	tracking = on and true or false
	-- (and where blood is written off, by the line that does it: cl_flowcore.lua, FC.Move)
	local FC = ABL.FlowCore
	if FC then FC.lostAt = tracking and (FC.lostAt or {}) or nil end
	for _, src in ipairs(ABL.Sources and ABL.Sources.list or {}) do
		local s = src.film
		if s then
			if tracking then
				if not s.trk then A.Reset(s) end
			else
				s.trk, s.rid, s.acc = nil, nil, nil
			end
		end
	end
end

local function NewCounts() return { ein = {}, eout = {}, xin = {}, xout = {}, soak = {}, dry = {} } end

-- What each region of film s holds (ml), by the regions the cells were given at the last grouping
-- (region 0: the cells that lie in none).
local function Held(s)
	local q = {}
	local h, k, ar, rid = s.h, s.k, s.ar, s.rid
	for c = 1, s.n do
		local r = rid[c] or 0
		q[r] = (q[r] or 0) + (h[c] + k[c]) * ar[c] * ML
	end
	return q
end

-- Film s is measured from now on: every cell outside any region until the first grouping, with
-- what it holds now (a film that is measured from a moment on has blood on it already).
function A.Reset(s)
	s.trk = NewCounts()
	s.rid = {}
	s.acc = { t = CurTime(), q0 = Held(s), regions = {}, nextId = 1, labels = 0 }
end

local NB = { "nb1", "nb2", "nb3", "nb4" }

-- The cells of film s grouped anew into regions; a new region takes the number of the old one most of
-- its blood was in, if no larger one has taken it.
local stack = {}
local function Group(s, now)
	local acc = s.acc
	local h, k, rs, ar, rid = s.h, s.k, s.rs, s.ar, s.rid
	local nb1, nb2, nb3, nb4 = s.nb1, s.nb2, s.nb3, s.nb4
	local sp, dx, dy = s.sp, s.dx, s.dy
	local depth = A.DEPTH
	local seen = {}
	local comps = {}
	for c0 = 1, s.n do
		if not seen[c0] and h[c0] + k[c0] > rs[c0] + depth then
			-- one region: every cell that can be reached from here through cells that hold blood
			local cells, q, area, dmax, dsum, running, old = {}, 0, 0, 0, 0, 0, {}
			local top, deepest = 0, c0
			seen[c0] = true
			top = 1
			stack[1] = c0
			while top > 0 do
				local c = stack[top]
				stack[top] = nil
				top = top - 1
				cells[#cells + 1] = c
				local d = h[c] + k[c]
				local v = d * ar[c] * ML
				q, area, dsum = q + v, area + ar[c], dsum + d * ar[c]
				if d > dmax then dmax, deepest = d, c end
				if sp[c] > 0.05 then running = running + 1 end
				local r = rid[c]
				if r and r > 0 then old[r] = (old[r] or 0) + v end
				for f = 1, 4 do
					local j
					if f == 1 then j = nb1[c] elseif f == 2 then j = nb2[c] elseif f == 3 then j = nb3[c] else j = nb4[c] end
					if j and j > 0 and not seen[j] and h[j] + k[j] > rs[j] + depth then
						seen[j] = true
						top = top + 1
						stack[top] = j
					end
				end
			end
			comps[#comps + 1] = { cells = cells, q = q, area = area, dmax = dmax, dmean = area > 0 and dsum / area or 0, running = running, old = old, deep = deepest }
		end
	end
	table.sort(comps, function(a, b) return a.q > b.q end)
	local taken, regions = {}, {}
	local nrid = {}
	for _, e in ipairs(comps) do
		local best, bv = nil, 0
		for r, v in pairs(e.old) do
			if not taken[r] and v > bv then best, bv = r, v end
		end
		if not best then
			best = acc.nextId
			acc.nextId = best + 1
		end
		taken[best] = true
		for i = 1, #e.cells do nrid[e.cells[i]] = best end
		local rec = acc.regions[best] or { id = best, born = now, hist = {} }
		rec.q, rec.area, rec.n, rec.dmax, rec.dmean, rec.running, rec.deep = e.q, e.area, #e.cells, e.dmax, e.dmean, e.running, e.deep
		rec.cells = e.cells
		rec.pooled = e.dmean > A.POOLED
		rec.seen = now
		local hist = rec.hist
		hist[#hist + 1] = { now, e.q }
		while #hist > 1 and now - hist[1][1] > 2.05 do table.remove(hist, 1) end
		local h0 = hist[1]
		rec.rate = (#hist > 1 and now > h0[1]) and (e.q - h0[2]) / (now - h0[1]) or 0
		rec.state = rec.rate > A.STILL and "growing" or (rec.rate < -A.STILL and "losing" or "standing")
		regions[best] = rec
	end
	s.rid = nrid
	acc.regions = regions
	acc.labels = acc.labels + 1
end

-- One measurement of film s: the books of every region since the last one, then the regions anew.
function A.Measure(s, now)
	local acc, trk = s.acc, s.trk
	if not acc or not trk then return end
	local dt = now - acc.t
	if dt <= 0 then return end
	local q1 = Held(s)
	local q0 = acc.q0
	local ids = {}
	for r in pairs(q1) do ids[r] = true end
	for r in pairs(q0) do ids[r] = true end
	for _, t in pairs(trk) do for r in pairs(t) do ids[r] = true end end
	for r in pairs(ids) do
		local ein, eout, xin, xout = trk.ein[r] or 0, trk.eout[r] or 0, trk.xin[r] or 0, trk.xout[r] or 0
		local soak, dry = trk.soak[r] or 0, trk.dry[r] or 0
		local d = (q1[r] or 0) - (q0[r] or 0)
		local e = abs(d - (ein + xin - eout - xout - soak - dry))
		if e > A.err then A.err, A.errFlow = e, ein + xin + eout + xout + soak + dry end
		local rec = acc.regions[r]
		if rec then
			rec.inRate, rec.outRate = (ein + xin) / dt, (eout + xout) / dt
			rec.fromWound, rec.leftRate = ein / dt, eout / dt
			rec.soakRate, rec.dryRate = soak / dt, dry / dt
		end
	end
	s.trk = NewCounts()
	Group(s, now)
	-- what each region holds now, by its new cells: the start of the next interval's books
	acc.q0 = Held(s)
	acc.t = now
end

-- The regions of film s, the largest first.
function A.Regions(s)
	local list = {}
	if s and s.acc then
		for _, rec in pairs(s.acc.regions) do list[#list + 1] = rec end
	end
	table.sort(list, function(a, b) return a.q > b.q end)
	return list
end

------------------------------------------------------------------------------------------
-- Pools
------------------------------------------------------------------------------------------
local poolHist = setmetatable({}, { __mode = "k" })

-- What pool p holds (ml of wet blood), the floor it covers (units^2), and how that changes.
function A.Pool(p, now)
	local g = p.sim
	if not g then return nil end
	local PS = ABL.PoolSim
	local q = PS.Volume(g) * ML
	-- (under: cells under a body with wet blood in them, and how much: blood that stood deep enough
	-- beside the body to seep under it, PS.SetBody; stained: with only dried or soaked-in blood, which
	-- stays where a body comes to lie over it)
	local cov, under, stained, underQ = 0, 0, 0, 0
	local n, h, k, s, ab, blk = g.n, g.h, g.k, g.s, g.ab, g.blk
	local tiny = g.film * 0.05
	if g.bx1 >= g.bx0 then
		for j = g.by0, g.by1 do
			local c = j * n + g.bx0 + 1
			for _ = g.bx0, g.bx1 do
				if h[c] + k[c] + s[c] + ab[c] > tiny then
					if blk[c] == 4 then
						if h[c] + k[c] > tiny then
							under = under + 1
							underQ = underQ + h[c] + k[c]
						else
							stained = stained + 1
						end
					else
						cov = cov + 1
					end
				end
				c = c + 1
			end
		end
	end
	underQ = underQ * g.a * g.a * ML
	-- (how fast, over the last four seconds or so: blood reaches a pool in lumps, a drop or a seep at
	-- a time, and over a shorter while a pool that is fed looks as if it stood still or shrank)
	local e = poolHist[p]
	if not e then e = { hist = {} } poolHist[p] = e end
	local hist = e.hist
	if not hist[1] or now - hist[#hist][1] >= 0.25 then hist[#hist + 1] = { now, q, p.inTot } end
	while #hist > 2 and now - hist[2][1] >= 4 do table.remove(hist, 1) end
	local h0 = hist[1]
	local span = now - h0[1]
	local rate = span > 0.5 and (q - h0[2]) / span or 0
	local inRate = span > 0.5 and (p.inTot - h0[3]) / span or 0
	return {
		q = q, area = cov * g.a * g.a, cells = cov, under = under, underQ = underQ, stained = stained, bodyCells = g.bodyN or 0, cell = g.a, pushed = g.pushed or 0,
		rate = rate, inRate = inRate, state = rate > A.STILL and "growing" or (rate < -A.STILL and "losing" or "standing"),
		inTot = p.inTot, outTot = p.outTot, dried = p.driedTot, soaked = p.soakTot, vol = p.vol,
	}
end

------------------------------------------------------------------------------------------
-- Measuring (a film every A.EVERY seconds, while tracking)
------------------------------------------------------------------------------------------
hook.Add("Think", "ABL_Accum", function()
	if not tracking then
		-- (the developer's view measures what it shows)
		if A.cvView:GetInt() > 0 and (C.sv.dev:GetBool() or ABL.testRun) then A.Track(true) else return end
	end
	local now = CurTime()
	for _, src in ipairs(ABL.Sources.list) do
		local s = src.film
		if s then
			if not s.trk then A.Reset(s) end
			if now - s.acc.t >= A.EVERY then A.Measure(s, now) end
		end
	end
end)

-- Where blood leaves a body and lands (cl_film.lua: FM.onEvent), for the view: the last few seconds.
local function OnEvent(kind, x, y, z, vol)
	if not tracking then return end
	local ev = A.events
	ev[#ev + 1] = { kind = kind, x = x, y = y, z = z, vol = vol, t = CurTime() }
	if #ev > 60 then table.remove(ev, 1) end
	A.counts = A.counts or {}
	A.counts[kind] = (A.counts[kind] or 0) + vol
end
if ABL.Film then ABL.Film.onEvent = OnEvent end

------------------------------------------------------------------------------------------
-- The developer's view
------------------------------------------------------------------------------------------
local COL = { growing = Color(60, 255, 90), standing = Color(235, 235, 235), losing = Color(255, 150, 40) }
local colRun, colDeep, colDrop, colSeep, colLand, colBody, colText = Color(80, 190, 255), Color(255, 60, 200), Color(255, 220, 0), Color(255, 40, 40), Color(170, 120, 255), Color(120, 120, 120), Color(255, 255, 255)
local vA, vB = Vector(), Vector()

local labels = {}
local function Label(x, y, z, text, col)
	labels[#labels + 1] = { x, y, z, text, col }
end

local function Cross(x, y, z, r, col)
	vA:SetUnpacked(x - r, y, z) vB:SetUnpacked(x + r, y, z) render.DrawLine(vA, vB, col, false)
	vA:SetUnpacked(x, y - r, z) vB:SetUnpacked(x, y + r, z) render.DrawLine(vA, vB, col, false)
	vA:SetUnpacked(x, y, z - r) vB:SetUnpacked(x, y, z + r) render.DrawLine(vA, vB, col, false)
end

local function DrawFilm(src)
	local s = src.film
	if not s or not s.acc or not src.pose or s.m ~= src.mesh or not IsValid(src.body) then return end
	local pose = src.pose
	pose:Begin(FrameNumber())
	local rid, nb1, nb2, nb3, nb4 = s.rid, s.nb1, s.nb2, s.nb3, s.nb4
	local h, k, tt, bu, bv, sp, dx, dy = s.h, s.k, s.tt, s.bu, s.bv, s.sp, s.dx, s.dy
	local drawn = 0
	for _, rec in pairs(s.acc.regions) do
		local col = COL[rec.state] or colText
		for _, c in ipairs(rec.cells or {}) do
			if drawn > 2500 then break end
			-- (on the region's outline: a cell beside one that is not in it)
			local r = rid[c]
			local edge = false
			for f = 1, 4 do
				local j
				if f == 1 then j = nb1[c] elseif f == 2 then j = nb2[c] elseif f == 3 then j = nb3[c] else j = nb4[c] end
				if not j or j <= 0 or rid[j] ~= r then edge = true break end
			end
			local d = h[c] + k[c]
			local run = sp[c] > 0.3 and (c % 3 == 0)
			if edge or d > A.POOLED or run then
				local x, y, z, nx, ny, nz = pose:Point(tt[c], bu[c], bv[c])
				if edge then
					Cross(x + nx * 0.12, y + ny * 0.12, z + nz * 0.12, 0.09, col)
					drawn = drawn + 1
				end
				-- how deep it stands: a tick out of the surface, 40 times as long as the blood is deep
				if d > A.POOLED then
					vA:SetUnpacked(x + nx * 0.1, y + ny * 0.1, z + nz * 0.1)
					vB:SetUnpacked(x + nx * (0.1 + d * 40), y + ny * (0.1 + d * 40), z + nz * (0.1 + d * 40))
					render.DrawLine(vA, vB, colDeep, false)
					drawn = drawn + 1
				end
				-- which way it runs (the cells across its grid's x and y give the way on the body)
				if run then
					local ux, uy = dx[c], dy[c]
					local jx = ux >= 0 and nb2[c] or nb1[c]
					local jy = uy >= 0 and nb4[c] or nb3[c]
					if jx and jx > 0 and jy and jy > 0 then
						local ax, ay, az = pose:Point(tt[jx], bu[jx], bv[jx])
						local bx, by, bz = pose:Point(tt[jy], bu[jy], bv[jy])
						local fx = (ax - x) * abs(ux) + (bx - x) * abs(uy)
						local fy = (ay - y) * abs(ux) + (by - y) * abs(uy)
						local fz = (az - z) * abs(ux) + (bz - z) * abs(uy)
						local l = sqrt(fx * fx + fy * fy + fz * fz)
						if l > 1e-4 then
							local len = min(0.25 + sp[c] * 0.12, 1.2) / l
							vA:SetUnpacked(x + nx * 0.15, y + ny * 0.15, z + nz * 0.15)
							vB:SetUnpacked(x + nx * 0.15 + fx * len, y + ny * 0.15 + fy * len, z + nz * 0.15 + fz * len)
							render.DrawLine(vA, vB, colRun, false)
							drawn = drawn + 1
						end
					end
				end
			end
		end
		local c = rec.deep
		if c and rec.q > 0.05 then
			local x, y, z, nx, ny, nz = pose:Point(tt[c], bu[c], bv[c])
			Label(x + nx * 1.2, y + ny * 1.2, z + nz * 1.2, string.format("R%d %s%s %.2f ml %+.2f ml/s | in %.2f out %.2f | %.0f u2 deep %.1f mm",
				rec.id, rec.pooled and "held " or "", rec.state, rec.q, rec.rate or 0, rec.inRate or 0, rec.outRate or 0, rec.area, (rec.dmax or 0) * 25.4 * 0.75), col)
		end
	end
end

local function DrawPool(p, now, showBody)
	local g = p.sim
	local PS = ABL.PoolSim
	if not g or g.bx1 < g.bx0 then return end
	local info = A.Pool(p, now)
	local ToW = ABL.Pools.ToWorld
	local n, a, h, k, s, ab, blk = g.n, g.a, g.h, g.k, g.s, g.ab, g.blk
	local col = COL[info.state] or colText
	local tiny = g.film * 0.05
	local function Wet(c) return blk[c] == 0 and h[c] + k[c] + s[c] + ab[c] > tiny end
	local drawn = 0
	for j = max(g.by0 - 1, 0), min(g.by1 + 1, n - 1) do
		for i = max(g.bx0 - 1, 0), min(g.bx1 + 1, n - 1) do
			local c = j * n + i + 1
			local u0, v0 = (g.i0 + i) * a, (g.j0 + j) * a
			if Wet(c) and drawn < 3000 then
				-- the outline: the sides of a wet cell that face a dry or closed one
				for f = 1, 4 do
					local ii, jj = i + (f == 1 and -1 or (f == 2 and 1 or 0)), j + (f == 3 and -1 or (f == 4 and 1 or 0))
					local q = (ii >= 0 and jj >= 0 and ii < n and jj < n) and (jj * n + ii + 1) or nil
					if not q or not Wet(q) then
						local ua, va_, ub, vb_
						if f == 1 then ua, va_, ub, vb_ = u0, v0, u0, v0 + a
						elseif f == 2 then ua, va_, ub, vb_ = u0 + a, v0, u0 + a, v0 + a
						elseif f == 3 then ua, va_, ub, vb_ = u0, v0, u0 + a, v0
						else ua, va_, ub, vb_ = u0, v0 + a, u0 + a, v0 + a end
						vA:SetUnpacked(ToW(p, ua, va_, 0.35))
						vB:SetUnpacked(ToW(p, ub, vb_, 0.35))
						render.DrawLine(vA, vB, col, false)
						drawn = drawn + 1
					end
				end
				-- how deep it stands
				local d = h[c] + k[c]
				if d > g.film * 1.2 and (i + j) % 2 == 0 then
					local x, y, z = ToW(p, u0 + a * 0.5, v0 + a * 0.5, 0.35)
					vA:SetUnpacked(x, y, z)
					vB:SetUnpacked(x + p.nx * d * 10, y + p.ny * d * 10, z + p.nz * d * 10)
					render.DrawLine(vA, vB, colDeep, false)
				end
			elseif showBody and blk[c] == 4 and (i + j) % 2 == 0 then
				local x, y, z = ToW(p, u0 + a * 0.5, v0 + a * 0.5, 0.3)
				Cross(x, y, z, a * 0.3, colBody)
			end
		end
	end
	-- where blood has been arriving
	for _, e in ipairs(p.inlets or {}) do
		if now - e.last < 3 then
			local x, y, z = ToW(p, e.u, e.v, 0.5)
			render.DrawWireframeSphere(Vector(x, y, z), 0.35 + min(e.rate, 3) * 0.3, 6, 6, colSeep, false)
		end
	end
	local x, y, z = ToW(p, (g.i0 + (g.bx0 + g.bx1 + 1) * 0.5) * a, (g.j0 + (g.by0 + g.by1 + 1) * 0.5) * a, 3)
	Label(x, y, z, string.format("pool %s %.1f ml %+.2f ml/s | in %.2f ml/s | %.0f u2%s", info.state, info.q, info.rate, info.inRate, info.area,
		info.bodyCells > 0 and string.format(" | %d cells under a body", info.bodyCells) or ""), col)
end

hook.Add("PostDrawTranslucentRenderables", "ABL_AccumView", function(depth, sky, sky3d)
	if depth or sky or sky3d then return end
	local mode = A.cvView:GetInt()
	if mode <= 0 or not (C.sv.dev:GetBool() or ABL.testRun) then return end
	-- (the main view only: not the water's reflection of the world)
	local rt = render.GetRenderTarget()
	if rt and string.find(string.lower(rt:GetName()), "_rt_water", 1, true) then return end
	render.SetColorMaterial()
	local now = CurTime()
	for _, src in ipairs(ABL.Sources.list) do DrawFilm(src) end
	for _, p in ipairs(ABL.Pools.list or {}) do DrawPool(p, now, mode >= 2) end
	-- where blood left the bodies and landed, in the last three seconds
	for _, e in ipairs(A.events) do
		local age = now - e.t
		if age < 3 then
			local col = e.kind == "drop" and colDrop or (e.kind == "seep" and colSeep or colLand)
			vA:SetUnpacked(e.x, e.y, e.z)
			render.DrawWireframeSphere(vA, 0.25 + (e.vol or 0) ^ 0.33 * 0.6, 5, 5, col, false)
			if age < 0.6 then Label(e.x, e.y, e.z + 0.8, string.format("%s %.3f ml", e.kind, e.vol or 0), col) end
		end
	end
	-- the labels, facing the eye
	local eye = EyePos()
	for i = 1, #labels do
		local l = labels[i]
		labels[i] = nil
		local pos = Vector(l[1], l[2], l[3])
		local ang = (eye - pos):Angle()
		ang:RotateAroundAxis(ang:Up(), 90)
		ang:RotateAroundAxis(ang:Forward(), 90)
		local sc = math.Clamp(pos:Distance(eye) / 1400, 0.025, 0.25)
		cam.Start3D2D(pos, ang, sc)
			draw.SimpleTextOutlined(l[4], "DermaDefault", 0, 0, l[5], TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, color_black)
		cam.End3D2D()
	end
end)
