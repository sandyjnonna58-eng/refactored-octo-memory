-- World runoff.
-- Blood deposited on a wall / slope becomes a rivulet once its volume overcomes the surface's
-- adhesion for the gravity component *tangent to that surface* (g - n (g.n)). A rivulet:
--   * flows only along that projected gravity (never uphill), slowly meandering,
--   * loses volume as a film (wet paths let later blood run further), so streaks end naturally,
--   * thickens as it clots: older blood runs slower and stops sooner,
--   * follows the surface with throttled traces: turns onto a new plane at corners, runs along
--     the crease where two surfaces form a valley, feeds a pool when it reaches a floor or stops
--     on a gentle slope with enough volume, and forms a hanging drop that detaches at open edges,
--   * merges with nearby rivulets (small flow + small flow = larger flow), and a heavy flow can
--     split into two fingers that wander apart and may rejoin.
-- Ceilings: deposits hang as pendant drops that grow as more blood arrives and detach once
-- gravity beats surface tension. Finished streaks are baked into engine decals.

ABL.NoJIT()
ABL.Runoff = ABL.Runoff or {}
local RU = ABL.Runoff
local C, L = ABL.Config, ABL.LOD
local RC = C.Runoff
local sqrt, min, max, abs, cos, sin, floor = math.sqrt, math.min, math.max, math.abs, math.cos, math.sin, math.floor

local list = {}
RU.list = list

local traceOut = {}
local trace = { mask = MASK_SOLID, output = traceOut, filter = ABL.Surface.ProbeFilter }
local vA, vB = Vector(), Vector()

local function Trace(x0, y0, z0, x1, y1, z1)
	vA:SetUnpacked(x0, y0, z0)
	vB:SetUnpacked(x1, y1, z1)
	trace.start, trace.endpos = vA, vB
	util.TraceLine(trace)
	return traceOut
end

local function Tangent(nx, ny, nz)
	local gx, gy, gz, gmag = ABL.Gravity()
	local gn = gx * nx + gy * ny + gz * nz
	local tx, ty, tz = gx - nx * gn, gy - ny * gn, gz - nz * gn
	local tm = sqrt(tx * tx + ty * ty + tz * tz)
	return tx, ty, tz, tm, gn, gmag
end

local function Threshold(r)
	local wet = ABL.Surface.WetGet(r.x, r.y, r.z)
	return RC.adhesion * r.surf.adhesion * (wet > 0.15 and 0.35 or 1)
end

------------------------------------------------------------------------------------------
-- Creation / merging
------------------------------------------------------------------------------------------
function RU.FindNear(x, y, z, nx, ny, nz, radius)
	local r2 = radius * radius
	for i = 1, #list do
		local r = list[i]
		if r.state ~= "done" and r.nx * nx + r.ny * ny + r.nz * nz > 0.8 then
			local dx, dy, dz = r.x - x, r.y - y, r.z - z
			if dx * dx + dy * dy + dz * dz < r2 then return r end
		end
	end
	return nil
end

-- Fresh blood joining a rivulet: the mix is younger (volume-weighted age) and it runs again.
local function Join(r, vol)
	local now = CurTime()
	r.born = r.born + (now - r.born) * min(1, vol / max(r.vol + vol, 1e-6))
	r.vol = r.vol + vol
	if r.state == "stop" then r.state = "run" r.cx, r.cy, r.cz = r.x, r.y, r.z end
end

-- a place on a surface: a point of the map and a normal
local function OnSurface(x, y, z, nx, ny, nz)
	return ABL.InWorld(x, y, z) and nx * nx + ny * ny + nz * nz > 0.5 and nx * nx + ny * ny + nz * nz < 2
end

function RU.Spawn(x, y, z, nx, ny, nz, vol, surf, ent, hanging, noMerge, owner)
	if not (ABL.GoodVol(vol) and OnSurface(x, y, z, nx, ny, nz)) then return nil end
	-- (as channels of the flow core: cl_flowworld.lua; what follows is the older head-and-trail model)
	if ABL.FlowCore.cv:GetBool() then return ABL.FlowWorld.Spawn(x, y, z, nx, ny, nz, vol, surf, ent, hanging, noMerge, owner) end
	if vol <= 0 then return nil end
	local existing = not noMerge and RU.FindNear(x, y, z, nx, ny, nz, 1.6)
	if existing then
		Join(existing, vol)
		return existing
	end
	if #list >= L.Cap(C.cl.maxRunoff) then
		-- over budget: bake the oldest finished streak to make room, otherwise give up
		local oi, ob = nil, math.huge
		for i = 1, #list do
			if list[i].state ~= "run" and list[i].born < ob then oi, ob = i, list[i].born end
		end
		if not oi then return nil end
		RU.Finish(list[oi])
		ABL.SwapRemove(list, oi)
	end
	local r = {
		x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, vol = vol, surf = surf or C.Surfaces.default,
		ent = ent, entPos = IsValid(ent) and ent:GetPos() or nil, owner = owner,
		state = hanging and "hang" or "run", born = CurTime(), last = CurTime(), acc = 0,
		dist = 0, moved = 0, meander = 0, hangT = 0, hangWait = 0.5, edgeHang = false,
		cx = x, cy = y, cz = z,
		px = x, py = y, pz = z, lt = ABL.Sim.t, sd = 0.05, acc = 0, hz = 41, hzT = 0,
		creaseLeft = 0, kx = 0, ky = 0, kz = 0, kslope = 0,
		tn = 0, tx = {}, ty = {}, tz = {}, tw = {}, tt = {}, mesh = nil, dirty = true, nextBuild = 0,
		lightT = 0, lr = 1, lg = 1, lb = 1, tone = math.Rand(C.ToneRange[1], 1),
	}
	r.rng = ABL.RNG(floor(abs(x * 11 + y * 5 + z * 3)) + 7)
	r.dripVol = RC.pendant * r.rng:Range(0.8, 1.3)
	-- first trail point at the origin
	r.tn = 1
	r.tx[1], r.ty[1], r.tz[1], r.tw[1], r.tt[1] = x, y, z, 0.3 + 0.5 * vol ^ 0.33, CurTime()
	list[#list + 1] = r
	return r
end

-- A drop that landed on a wall / slope.
function RU.Deposit(x, y, z, nx, ny, nz, vol, surf, ent, owner)
	if not (ABL.GoodVol(vol) and OnSurface(x, y, z, nx, ny, nz)) then return end
	local FC = ABL.FlowCore
	if FC.cv:GetBool() then return ABL.FlowWorld.Deposit(x, y, z, nx, ny, nz, vol, surf, ent, owner) end
	local r = RU.FindNear(x, y, z, nx, ny, nz, 1.6)
	if r then
		Join(r, vol)
		FC.stainWet = max(FC.stainWet - vol, 0)
		return
	end
	local tx, ty, tz, tm, _, gmag = Tangent(nx, ny, nz)
	local wetVol = ABL.Surface.WetGet(x, y, z)
	local drive = (wetVol ^ 0.6667) * tm / gmag
	local thresh = RC.adhesion * (surf or C.Surfaces.default).adhesion * (wetVol > 0.15 and 0.35 or 1)
	if drive > thresh then
		-- (the rivulet's blood comes out of the wet stains here: books)
		if RU.Spawn(x, y, z, nx, ny, nz, wetVol * 0.85, surf, ent, nil, nil, owner) then
			ABL.Surface.WetTake(x, y, z, wetVol * 0.85)
			local take = min(wetVol * 0.85, FC.stainWet)
			FC.stainWet = FC.stainWet - take
			-- (the wetness grid may hold more than the stains were booked with: that is new blood)
			if wetVol * 0.85 > take then FC.Release("surface", wetVol * 0.85 - take) end
		end
	end
end

-- A drop that landed on a ceiling-like surface.
-- Returns true when the blood is now in a rivulet (false: no room for one).
function RU.Pendant(x, y, z, nx, ny, nz, vol, surf, ent, owner)
	if not (ABL.GoodVol(vol) and OnSurface(x, y, z, nx, ny, nz)) then return false end
	if ABL.FlowCore.cv:GetBool() then return ABL.FlowWorld.Pendant(x, y, z, nx, ny, nz, vol, surf, ent, owner) end
	local r = RU.FindNear(x, y, z, nx, ny, nz, 1.3)
	if r then Join(r, vol) return true end
	return RU.Spawn(x, y, z, nx, ny, nz, vol, surf, ent, true, nil, owner) ~= nil
end

-- Liquid blood all rivulets hold (books).
function RU.Volume()
	local t = ABL.FlowWorld.Volume()
	for i = 1, #list do t = t + list[i].vol end
	return t
end

------------------------------------------------------------------------------------------
-- Finished streaks stay as geometry: they are appended to shared chunk meshes (a few draw calls
-- for all of them) whose colours keep ageing to dried blood. The oldest are dropped first when
-- over the cap. Streaks on props that move are discarded.
------------------------------------------------------------------------------------------
local archive = {}
RU.archive = archive
local ARCH_CHUNK = 16
local archCount = 0

local function DropOldestArchived()
	local c = archive[1]
	if not c then return end
	table.remove(c.items, 1)
	archCount = archCount - 1
	c.dirty = true
	if #c.items == 0 then
		if c.mesh then c.mesh:Destroy() end
		if c.gloss then c.gloss:Destroy() end
		table.remove(archive, 1)
	end
end

function RU.Finish(r)
	if r.finished then return end
	r.finished = true
	-- (what it still held stays where it is, as a wet stain)
	if r.vol > 0 then
		ABL.FlowCore.stainWet = ABL.FlowCore.stainWet + r.vol
		r.vol = 0
	end
	if r.mesh then r.mesh:Destroy() r.mesh = nil end
	if r.gloss then r.gloss:Destroy() r.gloss = nil end
	if r.tn < 2 then return end
	local cap = L.Cap(C.cl.maxRunoff) * 3
	while archCount >= cap and #archive > 0 do DropOldestArchived() end
	local c = archive[#archive]
	if not c or #c.items >= ARCH_CHUNK then
		c = { items = {}, mesh = nil, dirty = true, nextBuild = 0, nextAge = 0, x = 0, y = 0, z = 0, rad = 0, lightT = 0 }
		archive[#archive + 1] = c
	end
	c.items[#c.items + 1] = {
		tx = r.tx, ty = r.ty, tz = r.tz, tw = r.tw, tt = r.tt, tn = r.tn, nx = r.nx, ny = r.ny, nz = r.nz,
		lr = r.lr, lg = r.lg, lb = r.lb, ent = r.ent, entPos = r.entPos, tone = r.tone,
	}
	archCount = archCount + 1
	c.dirty = true
end

------------------------------------------------------------------------------------------
-- Simulation
------------------------------------------------------------------------------------------
local Drops

local function Drip(r, vol, vx, vy, vz)
	vol = min(vol, r.vol)
	if vol <= 0 then return end
	r.vol = r.vol - vol
	Drops.Spawn(r.x + r.nx * 0.3, r.y + r.ny * 0.3, r.z + r.nz * 0.3, vx, vy, vz, vol, nil, 0, 0, "surface", r.owner)
end

local function AddTrailPoint(r)
	if r.tn >= RC.trailPoints then
		-- decimate: drop every other old point
		local nx, ny, nz, nw, nt = {}, {}, {}, {}, {}
		local j = 0
		for i = 1, r.tn do
			if i % 2 == 1 or i > r.tn - 6 then
				j = j + 1
				nx[j], ny[j], nz[j], nw[j], nt[j] = r.tx[i], r.ty[i], r.tz[i], r.tw[i], r.tt[i]
			end
		end
		r.tx, r.ty, r.tz, r.tw, r.tt, r.tn = nx, ny, nz, nw, nt, j
	end
	local n = r.tn + 1
	r.tn = n
	r.tx[n], r.ty[n], r.tz[n] = r.x, r.y, r.z
	r.tw[n] = 0.18 + 0.45 * max(r.vol, 0) ^ 0.33
	r.tt[n] = CurTime()
	r.dirty = true
end

local upVec = Vector()

-- A rivulet that came to rest with enough blood on a gentle slope gathers into a pool there.
local function Collect(r)
	local gx, gy, gz, gm = ABL.Gravity()
	local up = -(r.nx * gx + r.ny * gy + r.nz * gz) / gm
	if r.vol < RC.collect or up < 0.25 then return false end
	upVec:SetUnpacked(r.nx, r.ny, r.nz)
	ABL.FlowCore.Move("surface", "pool", r.vol)
	ABL.Pools.Deposit(r.x, r.y, r.z, upVec, r.vol, r.surf, r.ent, "seep", nil, nil, nil, nil, r.owner)
	r.vol = 0
	return true
end

-- Split a finger off a heavy rivulet. Both wander apart on their own meander and rejoin if
-- their heads meet again.
local function Fork(r, dx, dy, dz)
	if #list >= L.Cap(C.cl.maxRunoff) then return end
	local rng = r.rng
	local share = r.vol * rng:Range(0.3, 0.45)
	local sx, sy, sz = ABL.Norm(r.ny * dz - r.nz * dy, r.nz * dx - r.nx * dz, r.nx * dy - r.ny * dx)
	local side = rng:Next() < 0.5 and -1 or 1
	local o = RU.Spawn(r.x + sx * side * 1.2, r.y + sy * side * 1.2, r.z + sz * side * 1.2, r.nx, r.ny, r.nz, share, r.surf, r.ent, false, true, r.owner)
	if not o then return end
	r.vol = r.vol - share
	o.born = r.born
	-- the finger's streak starts at the fork point on the parent's path
	o.tx[1], o.ty[1], o.tz[1] = r.x, r.y, r.z
	o.cx, o.cy, o.cz = r.x, r.y, r.z
	o.meander = side * 1.6
	r.meander = -side * 1.6
end

local function StepOne(r, dt)
	-- entity surfaces that moved invalidate the rivulet
	if r.entPos then
		if not IsValid(r.ent) or r.ent:GetPos():DistToSqr(r.entPos) > 1 then return false end
	end
	local tx, ty, tz, tm, gn, gmag = Tangent(r.nx, r.ny, r.nz)
	local rng = r.rng

	-- hanging drop: on an underside, or gathered on the lip of an open edge
	local underside = gn > 0.35 * gmag
	if underside or r.state == "hang" then
		local vd = r.dripVol * (underside and gmag / gn or 1)
		if r.vol > vd then
			r.hangT = r.hangT + dt
			-- the drop visibly swells for a moment before gravity wins
			if r.hangT > r.hangWait then
				r.hangT = 0
				r.hangWait = rng:Range(0.25, 1.2)
				r.dripVol = RC.pendant * rng:Range(0.8, 1.3)
				Drip(r, vd * rng:Range(0.85, 1), 0, 0, 0)
			end
		else
			r.hangT = 0
		end
	end
	if r.state == "hang" and (r.edgeHang or tm / gmag < 0.25) then
		return r.vol >= 0.004
	end
	if r.state == "stop" then
		return CurTime() - r.last <= 25
	end

	local now = CurTime()
	-- clotting: older blood is thicker, holds on harder and runs slower
	local visc = 1 + (now - r.born) / (RC.coag * C.sv.drying:GetFloat() / (r.surf.dry or 1))

	-- direction: down the fall line, or along the crease of a valley between two surfaces
	local dx, dy, dz, slope
	local crease = r.creaseLeft > 0
	if crease then
		dx, dy, dz, slope = r.kx, r.ky, r.kz, r.kslope
	elseif tm >= 1e-3 then
		dx, dy, dz, slope = tx / tm, ty / tm, tz / tm, tm / gmag
	end
	local drive = dx and (max(r.vol, 0) ^ 0.6667) * slope or 0
	local thresh = Threshold(r) * visc
	if drive <= thresh then
		r.state = "stop"
		r.last = now
		AddTrailPoint(r)
		-- enough blood on a gentle slope gathers into a pool where it came to rest
		if Collect(r) then return false end
		return true
	end
	r.state = "run"
	r.last = now
	local sp = RC.speed * r.surf.runoff * (r.vol ^ 0.3333) * slope * (1 - thresh / drive) / visc
	sp = math.Clamp(sp, 0.3, 14)
	-- gentle meander around the fall line (surface micro-roughness)
	r.meander = r.meander + (rng:Normal() * 1.2 - r.meander * 2) * dt
	if not crease then
		local sx, sy, sz = r.ny * dz - r.nz * dy, r.nz * dx - r.nx * dz, r.nx * dy - r.ny * dx
		local m = r.meander * 0.18
		dx, dy, dz = ABL.Norm(dx + sx * m, dy + sy * m, dz + sz * m)
	end
	local step = sp * dt
	if crease then r.creaseLeft = r.creaseLeft - step end
	local nx2, ny2, nz2 = r.x + dx * step, r.y + dy * step, r.z + dz * step

	-- film deposit along the way (less on already wet paths)
	local wet = ABL.Surface.WetGet(r.x, r.y, r.z)
	local loss = min(r.vol, step * RC.filmLoss * (wet > 0.15 and 0.3 or 1) * (1 + r.surf.absorb))
	r.vol = r.vol - loss
	ABL.FlowCore.stainWet = ABL.FlowCore.stainWet + loss
	ABL.Surface.WetAdd(r.x, r.y, r.z, loss, C.Stain.dryBase * 2 / r.surf.dry)

	-- a heavy flow splits into two fingers now and then
	if not crease and r.vol > RC.forkVol and rng:Next() < dt * RC.forkRate * (r.vol - RC.forkVol) then Fork(r, dx, dy, dz) end

	r.moved = r.moved + step
	if r.moved < RC.checkDist then
		r.x, r.y, r.z = nx2, ny2, nz2
	else
		-- verify the whole unchecked stretch since the last verified point
		if not L.TakeTrace() then return true end
		r.moved = 0
		local cx, cy, cz = r.cx, r.cy, r.cz
		local tr = Trace(cx + r.nx * 0.35, cy + r.ny * 0.35, cz + r.nz * 0.35, nx2 + dx * 0.6 + r.nx * 0.35, ny2 + dy * 0.6 + r.ny * 0.35, nz2 + dz * 0.6 + r.nz * 0.35)
		if tr.Hit and not tr.StartSolid then
			local hn = tr.HitNormal
			local gx, gy, gz, gm = ABL.Gravity()
			local up = -(hn.x * gx + hn.y * gy + hn.z * gz) / gm
			if up > 0.64 then
				-- reached the floor: the rivulet ends in a pool
				r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
				AddTrailPoint(r)
				ABL.FlowCore.Move("surface", "pool", r.vol)
				ABL.Pools.Deposit(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, hn, r.vol, ABL.Surface.FromTrace(tr), IsValid(tr.Entity) and tr.Entity or nil, "runoff", dx, dy, dz, nil, r.owner)
				r.vol = 0
				return false
			end
			-- inner corner. If blood on the new plane would run straight back into this one, the
			-- two planes form a valley: follow the crease downhill, or gather where it is level
			local t2x, t2y, t2z, t2m = Tangent(hn.x, hn.y, hn.z)
			if t2m > 1e-3 and (t2x * r.nx + t2y * r.ny + t2z * r.nz) / t2m < -0.2 then
				local kx, ky, kz = ABL.Norm(r.ny * hn.z - r.nz * hn.y, r.nz * hn.x - r.nx * hn.z, r.nx * hn.y - r.ny * hn.x)
				local kg = (kx * gx + ky * gy + kz * gz) / gm
				if kg < 0 then kx, ky, kz, kg = -kx, -ky, -kz, -kg end
				-- back onto this plane, standing off the obstacle so the next trace runs along the
				-- crease instead of into it
				r.x = tr.HitPos.x - r.nx * 0.35 + hn.x * 0.4
				r.y = tr.HitPos.y - r.ny * 0.35 + hn.y * 0.4
				r.z = tr.HitPos.z - r.nz * 0.35 + hn.z * 0.4
				r.cx, r.cy, r.cz = r.x, r.y, r.z
				AddTrailPoint(r)
				if kg < 0.06 or (kx == 0 and ky == 0 and kz == 0) then
					r.state = "stop"
					r.last = now
					if Collect(r) then return false end
					return true
				end
				r.kx, r.ky, r.kz, r.kslope, r.creaseLeft = kx, ky, kz, kg, 12
				return true
			end
			-- outer bend onto the new plane
			r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
			AddTrailPoint(r)
			r.nx, r.ny, r.nz = hn.x, hn.y, hn.z
			r.surf = ABL.Surface.FromTrace(tr)
			r.cx, r.cy, r.cz = r.x, r.y, r.z
			r.creaseLeft = 0
			return true
		end
		-- is there still a surface under the new position?
		if not L.TakeTrace() then return true end
		tr = Trace(nx2 + r.nx * 1.2, ny2 + r.ny * 1.2, nz2 + r.nz * 1.2, nx2 - r.nx * 2.5, ny2 - r.ny * 2.5, nz2 - r.nz * 2.5)
		if not tr.Hit or tr.StartSolid then
			-- open edge: stay on the lip (the last verified point) and drip from there
			r.x, r.y, r.z = cx, cy, cz
			AddTrailPoint(r)
			r.state = "hang"
			r.edgeHang = true
			r.hangT = r.hangWait
			return r.vol >= 0.004
		end
		local hn = tr.HitNormal
		r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
		r.nx, r.ny, r.nz = hn.x, hn.y, hn.z
		r.cx, r.cy, r.cz = r.x, r.y, r.z
		-- trail points only at verified positions, so streaks never leave the surface
		AddTrailPoint(r)
	end

	if r.vol < 0.004 then
		r.x, r.y, r.z = r.cx, r.cy, r.cz
		AddTrailPoint(r)
		r.state = "stop"
		r.last = CurTime()
	end
	return true
end

-- Called every simulation tick; each rivulet steps at the rate its distance allows (C.LODTiers
-- runoffHz: 82 Hz up close). Traces are spaced by distance travelled, not by steps, so a higher
-- rate costs no extra traces; it makes the head move smoothly.
function RU.Step(h)
	Drops = Drops or ABL.Drops
	local Sim = ABL.Sim
	local now, simT = CurTime(), Sim.t
	local i = #list
	while i > 0 do
		local r = list[i]
		if now > (r.hzT or 0) then
			r.hzT = now + 0.4 + math.random() * 0.2
			local dx, dy, dz = r.x - L.eyeX, r.y - L.eyeY, r.z - L.eyeZ
			r.hz = Sim.TierAt(sqrt(dx * dx + dy * dy + dz * dz)).runoffHz
		end
		r.acc = (r.acc or 0) + h
		local keep = true
		if r.acc + 1e-6 >= Sim.Period(r.hz) then
			local dt = r.acc
			r.acc = 0
			-- the state before this step, for drawing in between
			r.px, r.py, r.pz = r.x, r.y, r.z
			r.lt, r.sd = simT, dt
			keep = StepOne(r, dt)
		end
		if keep and r.state == "run" and r.lt == simT then
			-- merge with any other rivulet whose head is right here
			for j = 1, #list do
				local o = list[j]
				if o ~= r and o.state ~= "done" then
					local dx, dy, dz = o.x - r.x, o.y - r.y, o.z - r.z
					if dx * dx + dy * dy + dz * dz < 1.0 and o.nx * r.nx + o.ny * r.ny + o.nz * r.nz > 0.8 then
						r.born = r.born + (o.born - r.born) * min(1, o.vol / max(r.vol + o.vol, 1e-6))
						r.vol = r.vol + o.vol
						o.vol = 0
						o.state = "stop"
						o.last = 0
						break
					end
				end
			end
		end
		if not keep then
			RU.Finish(r)
			ABL.SwapRemove(list, i)
		end
		i = i - 1
	end
end

------------------------------------------------------------------------------------------
-- Rendering. A rivulet's trail is an absorbing film (filter pass: the wall shows through its thin
-- edges, the thick middle is a deep crimson) plus, while it is wet, a reflection strip (gloss pass,
-- a broken highlight line along its crest, strength from the view angle). Both are static meshes per
-- rivulet, rebuilt when it grows or dries a step; finished streaks are batched into chunk meshes.
-- The moving / hanging head is a lit liquid drop.
------------------------------------------------------------------------------------------
local vec = Vector()

local function DryTime()
	return C.Stain.dryBase * 2 * C.sv.drying:GetFloat()
end

-- Quads of one streak (trail arrays + plane normal) into the mesh being built.
-- gloss: the reflection strip (wetness x light in the colour) instead of the filter.
local function WriteStrip(t, now, gloss)
	local R = ABL.Render
	local off = RC.offset
	local v = 0
	local nx, ny, nz = t.nx, t.ny, t.nz
	local ofx, ofy, ofz = nx * off, ny * off, nz * off
	local tx, ty, tz, tw, tt = t.tx, t.ty, t.tz, t.tw, t.tt
	local dryT = DryTime()
	local tone = t.tone or 1
	local lr, lg, lb = t.lr or 1, t.lg or 1, t.lb or 1
	local last = t.tn
	for i = 1, t.tn - 1 do
		local x1, y1, z1 = tx[i], ty[i], tz[i]
		local x2, y2, z2 = tx[i + 1], ty[i + 1], tz[i + 1]
		local sx, sy, sz = x2 - x1, y2 - y1, z2 - z1
		local sl = sqrt(sx * sx + sy * sy + sz * sz)
		local wx, wy, wz = sy * nz - sz * ny, sz * nx - sx * nz, sx * ny - sy * nx
		local wl = sqrt(wx * wx + wy * wy + wz * wz)
		if wl < 1e-6 then wx, wy, wz, wl = 1, 0, 0, 1 end
		local h1, h2 = tw[i] * 0.5 / wl, tw[i + 1] * 0.5 / wl
		local k1 = math.Clamp((now - tt[i]) / dryT, 0, 1)
		local k2 = math.Clamp((now - tt[i + 1]) / dryT, 0, 1)
		-- the first point (where the blood arrived) is a thinner film; the rest an even layer
		local f1 = i == 1 and 0.6 or 0.92
		local r1, g1, b1, a1, r2, g2, b2, a2
		if gloss then
			local w1, w2 = (1 - k1 / 0.5), (1 - k2 / 0.5)
			w1, w2 = w1 > 0 and w1 * 255 or 0, w2 > 0 and w2 * 255 or 0
			r1, g1, b1, a1 = w1 * lr, w1 * lg, w1 * lb, 255 * f1
			r2, g2, b2, a2 = w2 * lr, w2 * lg, w2 * lb, 255 * 0.92
		else
			local mr, mg, mb = R.FilterAge(k1)
			r1, g1, b1, a1 = R.FilterColor(mr * tone, mg, mb, f1)
			mr, mg, mb = R.FilterAge(k2)
			r2, g2, b2, a2 = R.FilterColor(mr * tone, mg, mb, 0.92)
		end
		local v2 = v + sl / 8
		vec:SetUnpacked(x1 - wx * h1 + ofx, y1 - wy * h1 + ofy, z1 - wz * h1 + ofz) mesh.Position(vec) mesh.TexCoord(0, 0, v) mesh.Color(r1, g1, b1, a1) mesh.AdvanceVertex()
		vec:SetUnpacked(x1 + wx * h1 + ofx, y1 + wy * h1 + ofy, z1 + wz * h1 + ofz) mesh.Position(vec) mesh.TexCoord(0, 1, v) mesh.Color(r1, g1, b1, a1) mesh.AdvanceVertex()
		vec:SetUnpacked(x2 + wx * h2 + ofx, y2 + wy * h2 + ofy, z2 + wz * h2 + ofz) mesh.Position(vec) mesh.TexCoord(0, 1, v2) mesh.Color(r2, g2, b2, a2) mesh.AdvanceVertex()
		vec:SetUnpacked(x2 - wx * h2 + ofx, y2 - wy * h2 + ofy, z2 - wz * h2 + ofz) mesh.Position(vec) mesh.TexCoord(0, 0, v2) mesh.Color(r2, g2, b2, a2) mesh.AdvanceVertex()
		v = v2
	end
	return last
end

local function Wet(t, now)
	return t.tn >= 2 and now - t.tt[t.tn] < DryTime() * 0.5
end

local function Build(r)
	if r.mesh then r.mesh:Destroy() r.mesh = nil end
	if r.gloss then r.gloss:Destroy() r.gloss = nil end
	if r.tn < 2 then return end
	local now = CurTime()
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, r.tn - 1)
	WriteStrip(r, now, false)
	mesh.End()
	r.mesh = m
	if Wet(r, now) then
		local g = Mesh()
		mesh.Begin(g, MATERIAL_QUADS, r.tn - 1)
		WriteStrip(r, now, true)
		mesh.End()
		r.gloss = g
	end
	r.dirty = false
	r.builtAt = now
end

local function BuildChunk(c, now)
	if c.mesh then c.mesh:Destroy() c.mesh = nil end
	if c.gloss then c.gloss:Destroy() c.gloss = nil end
	c.dirty = false
	local total, wetTotal = 0, 0
	for _, it in ipairs(c.items) do
		total = total + it.tn - 1
		if Wet(it, now) then wetTotal = wetTotal + it.tn - 1 end
	end
	if total <= 0 then return end
	local m = Mesh()
	mesh.Begin(m, MATERIAL_QUADS, total)
	local sx, sy, sz, n, youngest = 0, 0, 0, 0, 0
	local anx, any, anz = 0, 0, 0
	for _, it in ipairs(c.items) do
		WriteStrip(it, now, false)
		for i = 1, it.tn do sx, sy, sz, n = sx + it.tx[i], sy + it.ty[i], sz + it.tz[i], n + 1 end
		anx, any, anz = anx + it.nx, any + it.ny, anz + it.nz
		if it.tt[it.tn] > youngest then youngest = it.tt[it.tn] end
	end
	mesh.End()
	c.mesh = m
	if wetTotal > 0 then
		local g = Mesh()
		mesh.Begin(g, MATERIAL_QUADS, wetTotal)
		for _, it in ipairs(c.items) do
			if Wet(it, now) then WriteStrip(it, now, true) end
		end
		mesh.End()
		c.gloss = g
	end
	c.x, c.y, c.z = sx / n, sy / n, sz / n
	c.nx, c.ny, c.nz = ABL.Norm(anx, any, anz)
	local rad = 0
	for _, it in ipairs(c.items) do
		for i = 1, it.tn do
			local d = (it.tx[i] - c.x) ^ 2 + (it.ty[i] - c.y) ^ 2 + (it.tz[i] - c.z) ^ 2
			if d > rad then rad = d end
		end
	end
	c.rad = sqrt(rad) + 1
	c.youngest = youngest
end

-- reflection strips queued during the filter pass: { mesh, x, y, z, nx, ny, nz }
local glossQ, glossN = {}, 0
local function QueueGloss(m, x, y, z, nx, ny, nz)
	glossN = glossN + 1
	local q = glossQ[glossN] or {}
	glossQ[glossN] = q
	q[1], q[2], q[3], q[4], q[5], q[6], q[7] = m, x, y, z, nx, ny, nz
end

-- Finished streaks: drop the ones on props that moved, keep colours ageing, draw what is in view.
local function DrawArchive(rt, now, builds)
	local dryT = DryTime()
	for i = #archive, 1, -1 do
		local c = archive[i]
		if rt > c.nextAge then
			c.nextAge = rt + 5 + math.random()
			local items = c.items
			for j = #items, 1, -1 do
				local it = items[j]
				if it.entPos and (not IsValid(it.ent) or it.ent:GetPos():DistToSqr(it.entPos) > 1) then
					table.remove(items, j)
					archCount = archCount - 1
					c.dirty = true
				end
			end
			if c.youngest and now - c.youngest < dryT then c.dirty = true end
		end
		if #c.items == 0 then
			if c.mesh then c.mesh:Destroy() end
			if c.gloss then c.gloss:Destroy() end
			table.remove(archive, i)
		else
			if (c.dirty or not c.mesh) and builds < 8 and rt > c.nextBuild then
				BuildChunk(c, now)
				builds = builds + 1
				c.nextBuild = rt + 0.5
			end
			if c.mesh then
				local d2, vis = L.View(c.x, c.y, c.z, c.rad)
				if vis and d2 < (2500 + c.rad) ^ 2 then
					ABL.Render.FilterDraw(ABL.Mat.filmFilter, c.mesh)
					if c.gloss and d2 < 1200 * 1200 then QueueGloss(c.gloss, c.x, c.y, c.z, c.nx, c.ny, c.nz) end
				end
			end
		end
	end
end

local glossCol = Vector()

-- The live end of a running rivulet: from its last trail point to the interpolated head, in the
-- film pass (FilterDraw state is already set up by the rivulet's mesh draw).
local tipV = Vector()
local function TipV(x, y, z, u, v, r, g, b, a)
	tipV:SetUnpacked(x, y, z)
	mesh.Position(tipV)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end
local function DrawTip(r, M)
	local n = r.tn
	local x1, y1, z1 = r.tx[n], r.ty[n], r.tz[n]
	local x2, y2, z2 = r.rx, r.ry, r.rz
	local sx, sy, sz = x2 - x1, y2 - y1, z2 - z1
	local sl = sqrt(sx * sx + sy * sy + sz * sz)
	if sl < 0.05 then return end
	local nx, ny, nz = r.nx, r.ny, r.nz
	local wx, wy, wz = ABL.Norm(sy * nz - sz * ny, sz * nx - sx * nz, sx * ny - sy * nx)
	local off = RC.offset
	local h1 = r.tw[n] * 0.5
	local h2 = (0.18 + 0.45 * max(r.vol, 0) ^ 0.33) * 0.5
	local R = ABL.Render
	local mr, mg, mb = R.FilterAge(0)
	local cr, cg, cb, ca = R.FilterColor(mr * (r.tone or 1), mg, mb, 0.92)
	local ox, oy, oz = nx * off, ny * off, nz * off
	render.SetMaterial(M.filmFilter)
	R.BeginFilter()
	mesh.Begin(MATERIAL_QUADS, 1)
	TipV(x1 - wx * h1 + ox, y1 - wy * h1 + oy, z1 - wz * h1 + oz, 0, 0, cr, cg, cb, ca)
	TipV(x1 + wx * h1 + ox, y1 + wy * h1 + oy, z1 + wz * h1 + oz, 1, 0, cr, cg, cb, ca)
	TipV(x2 + wx * h2 + ox, y2 + wy * h2 + oy, z2 + wz * h2 + oz, 1, sl / 8, cr, cg, cb, ca)
	TipV(x2 - wx * h2 + ox, y2 - wy * h2 + oy, z2 - wz * h2 + oz, 0, sl / 8, cr, cg, cb, ca)
	mesh.End()
end

function RU.Draw()
	local R = ABL.Render
	local M = ABL.Mat
	local rt = RealTime()
	local now = CurTime()
	local builds = 0
	glossN = 0
	-- (FilterDraw sets material and blend per draw: rebuilding a mesh in the loop resets them)
	for i = 1, #list do
		local r = list[i]
		local d2, vis = L.View(r.x, r.y, r.z, 30)
		r.visible = vis and d2 < 2500 * 2500
		if r.visible then
			if rt > r.lightT then
				r.lightT = rt + 2 + math.random()
				r.lr, r.lg, r.lb = R.Light(r.x + r.nx * 2, r.y + r.ny * 2, r.z + r.nz * 2)
				r.dirty = true
			end
			if now - (r.builtAt or 0) > 2 then r.dirty = true end
			if (r.dirty or not r.mesh) and rt > r.nextBuild and builds < 8 then
				Build(r)
				builds = builds + 1
				r.nextBuild = rt + 0.1
			end
			if r.mesh then
				R.FilterDraw(M.filmFilter, r.mesh)
				if r.gloss and d2 < 1200 * 1200 then QueueGloss(r.gloss, r.x, r.y, r.z, r.nx, r.ny, r.nz) end
			end
			-- where the rivulet is, between its last two steps; the stretch from its last trail point
			-- to there is drawn live, so the streak grows with the head instead of in jumps
			local a = ABL.Sim.Alpha(r.lt, r.sd)
			r.rx, r.ry, r.rz = r.px + (r.x - r.px) * a, r.py + (r.y - r.py) * a, r.pz + (r.z - r.pz) * a
			if r.state == "run" and r.tn >= 1 and d2 < 1500 * 1500 then DrawTip(r, M) end
		end
	end
	DrawArchive(rt, now, builds)
	R.EndFilter()
	-- reflection: Fresnel of the view angle on the wall times the sky it mirrors
	if glossN > 0 then
		local gm = M.filmGloss
		render.SetMaterial(gm)
		for i = 1, glossN do
			local q = glossQ[i]
			local dx, dy, dz = q[2] - L.eyeX, q[3] - L.eyeY, q[4] - L.eyeZ
			local d = max(sqrt(dx * dx + dy * dy + dz * dz), 1)
			local k = min(C.Ground.sheen * 1.2 * R.Fresnel((dx * q[5] + dy * q[6] + dz * q[7]) / d) + 0.05, 0.8)
			glossCol:SetUnpacked(k, k, k)
			gm:SetVector("$color", glossCol)
			q[1]:Draw()
			q[1] = nil
		end
	end
	-- the moving / hanging heads: lit liquid drops (the sprite carries colour and highlight)
	for i = 1, #list do
		local r = list[i]
		if r.visible and r.vol > 0.01 and r.state ~= "done" then
			-- surface tension caps how big the head can bulge
			local rad = 0.15 + 0.5 * min(r.vol, r.state == "hang" and 0.15 or 0.5) ^ 0.33
			local hx, hy, hz = (r.rx or r.x) + r.nx * 0.2, (r.ry or r.y) + r.ny * 0.2, (r.rz or r.z) + r.nz * 0.2
			local t = r.tone or 1
			local cr, cg, cb = min(255, 255 * r.lr * t), min(255, 255 * r.lg), min(255, 255 * r.lb)
			if r.state == "hang" then
				local gx, gy, gz = ABL.Gravity()
				local s = 1 + min(r.hangT * 1.5, 1)
				local ax, ay, az = ABL.Norm(gx, gy, gz)
				R.Streak(M.droplet, hx + ax * rad * 0.5 * s, hy + ay * rad * 0.5 * s, hz + az * rad * 0.5 * s, ax, ay, az, rad * 2 * s, rad * 2, cr, cg, cb, 245)
			else
				-- a flattened bead lying on the wall, drawn out along its run
				local gx, gy, gz = ABL.Gravity()
				local ax, ay, az = ABL.Norm(gx - r.nx * (gx * r.nx + gy * r.ny + gz * r.nz), gy - r.ny * (gx * r.nx + gy * r.ny + gz * r.nz), gz - r.nz * (gx * r.nx + gy * r.ny + gz * r.nz))
				local qx, qy, qz = r.ny * az - r.nz * ay, r.nz * ax - r.nx * az, r.nx * ay - r.ny * ax
				R.PlaneQuad(M.droplet, hx, hy, hz, ax * rad * 1.25, ay * rad * 1.25, az * rad * 1.25, qx * rad, qy * rad, qz * rad, cr, cg, cb, 235)
			end
		end
	end
end

function RU.Clear()
	for i = #list, 1, -1 do
		if list[i].mesh then list[i].mesh:Destroy() end
		if list[i].gloss then list[i].gloss:Destroy() end
		list[i] = nil
	end
	for i = #archive, 1, -1 do
		if archive[i].mesh then archive[i].mesh:Destroy() end
		if archive[i].gloss then archive[i].gloss:Destroy() end
		archive[i] = nil
	end
	archCount = 0
end

function RU.Count() return #list + ABL.FlowWorld.Count() end
