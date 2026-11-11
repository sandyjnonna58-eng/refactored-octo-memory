-- World flow: blood on walls, slopes, ceilings and props as channels of the flow core.
-- The same liquid as on a body (cl_flowcore.lua): a channel is a row of nodes holding mobile blood,
-- film, soaked and dried blood; blood moves between the nodes by the thin-film law under gravity
-- along the surface; the head is the front of the stream. What differs is how a head finds its way:
-- on a body it walks the triangles of the mesh, here it follows the surface with traces, as the
-- older rivulets did (cl_runoff.lua): down the fall line, onto the next plane at a bend, along the
-- crease of a valley, hanging and dripping at an open edge or under a ceiling.
--   * A channel that reaches a floor ends there in the pool: whatever still runs down it afterwards
--     goes into that pool (the pool is fed by the stream, not by one arrival).
--   * Blood landing on a wall where a stream runs joins the stream at that point and runs down
--     with it; a drop landing on wet stains starts a stream once enough has gathered there.
--   * Heads that meet another channel join it; a heavy head splits a finger off.
--   * (phase 21, C.P21.streamHead) A head takes from its stream no more than its bead, what it needs
--     to run there: the stream carries the rest, and the head runs on as fast as the stream behind it.
-- Channels are kept per region of the map (a cube of 192 units) so that each is drawn with the light
-- and at the detail of where it is. The older rivulets remain for abl_flow_core 0.

ABL.NoJIT()
ABL.FlowWorld = ABL.FlowWorld or {}
local FW = ABL.FlowWorld
local FC, FD, F = ABL.FlowCore, ABL.FlowDraw, ABL.Flow
local C, L, R = ABL.Config, ABL.LOD, ABL.Render
local RC, K = C.Runoff, C.Flow
local sqrt, min, max, abs, floor = math.sqrt, math.min, math.max, math.abs, math.floor
local Drops

local REGION = 192
local regions, regionList, heads = {}, {}, {}
FW.list = heads
FW.regions = regionList
-- (phase 21, C.P21.streamHead: how a head takes from its stream and lets go of what hangs; read once a
-- step, FW.Step)
local headRule = false

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
	return tx, ty, tz, sqrt(tx * tx + ty * ty + tz * tz), gn, gmag
end

------------------------------------------------------------------------------------------
-- Regions, channels, heads
------------------------------------------------------------------------------------------
local function Region(x, y, z)
	local key = ABL.CellKey(x, y, z, REGION)
	local reg = regions[key]
	if not reg then
		reg = {
			key = key, world = true, seed = floor(abs(x * 11 + y * 5 + z * 3)) + 7,
			fc = { chans = {}, cells = {}, nodes = 0, nextId = 0, bk = { fed = 0, surface = 0, absorbed = 0, clotted = 0, dried = 0, left = 0 } },
			cx = (floor(x / REGION) + 0.5) * REGION, cy = (floor(y / REGION) + 0.5) * REGION, cz = (floor(z / REGION) + 0.5) * REGION,
			rad = REGION * 0.9, dist = 0, lod = C.LOD_ULTRA, tone = math.Rand(C.ToneRange[1], 1),
			acc = 0, hz = 82, hzT = 0, lightT = 0, lr = 1, lg = 1, lb = 1, lx = x, ly = y, lz = z,
			-- (the surface's normal at the light's place: the light a pool there is lit with, mr, mg, mb,
			-- is found facing it: C.P21.streamLiquid, FW.Draw)
			lnx = 0, lny = 0, lnz = 1,
		}
		regions[key] = reg
		regionList[#regionList + 1] = reg
	end
	return reg
end

local function RemoveHead(r)
	if r.dead then return end
	r.dead = true
	if r.chan and r.chan.head == r then r.chan.head = nil end
	for i = #heads, 1, -1 do
		if heads[i] == r then ABL.SwapRemove(heads, i) break end
	end
end

local function NewHead(ch, reg, x, y, z, nx, ny, nz, vol, surf, hanging)
	local r = {
		chan = ch, reg = reg, x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, vol = vol, surf = surf,
		state = hanging and "hang" or "run", last = CurTime(),
		dist = 0, moved = 0, travel = 0, mz = 0, hangT = 0, hangWait = 0.5, edgeHang = false, hangK = 0, lastDrip = 0,
		cx = x, cy = y, cz = z, px = x, py = y, pz = z, lt = ABL.Sim.t, sd = 0.05,
		creaseLeft = 0, kx = 0, ky = 0, kz = 0, kslope = 0,
		-- what the flow core and its drawing read of a head
		tri = 0, wx = x, wy = y, wz = z, ix = 0, iy = 0, iz = -1, gt = 0, pn = 0, placed = true,
		vx = 0, vy = 0, vz = 0, bage = 0, film = 0, moving = false, stuckT = 0, atEdge = false, chk = 0, idle = 0,
		rng = ch.rng,
	}
	r.dripVol = RC.pendant * r.rng:Range(0.8, 1.3)
	ch.head = r
	heads[#heads + 1] = r
	return r
end

function FW.Count() return #heads end

-- A stream on a prop that has been moved: the stream is gone with the place it ran at, and its
-- trail stays on the prop as flat stains, where the prop is now (at most LEAVE_MAX a stream; the
-- stains' own budget may allow fewer).
local LEAVE_MAX = 4
local function LeaveOn(ch)
	local ent, p0, a0 = ch.ent, ch.entPos, ch.entAng
	if not (IsValid(ent) and p0 and a0) or ch.n < 2 then return end
	local p1, a1 = ent:GetPos(), ent:GetAngles()
	local an, n = ch.an, ch.n
	local step = max(1, math.ceil((n - 1) / LEAVE_MAX))
	local col = C.Colors.decal
	local left = 0
	local i = 1
	while i < n do
		local j = min(i + step, n)
		local A, Z = an[i], an[j]
		if A and Z and A.px and Z.px then
			vA:SetUnpacked((A.px + Z.px) * 0.5, (A.py + Z.py) * 0.5, (A.pz + Z.pz) * 0.5)
			local wp = LocalToWorld(WorldToLocal(vA, angle_zero, p0, a0), angle_zero, p1, a1)
			vA:SetUnpacked(A.nx, A.ny, A.nz)
			local wn = LocalToWorld(WorldToLocal(vA, angle_zero, vector_origin, a0), angle_zero, vector_origin, a1)
			vA:SetUnpacked(Z.px - A.px, Z.py - A.py, Z.pz - A.pz)
			local len = vA:Length()
			if len > 0.6 then
				local wd = LocalToWorld(WorldToLocal(vA, angle_zero, vector_origin, a0), angle_zero, vector_origin, a1)
				local w = math.Clamp((ch.wmax and ch.wmax[i] or 0.3) * 2.2, 0.5, 2.2)
				if ABL.Stains.Place("smear", ABL.Mat.Random("smear"), wp.x, wp.y, wp.z, wn.x, wn.y, wn.z, wd.x / len, wd.y / len, wd.z / len, min(len * 1.15, 14), w, col, 205, ent, 0) then
					left = left + 1
				end
			end
		end
		i = j
	end
	FW.left = (FW.left or 0) + left
end

-- A channel goes; what it still held is written off (books).
local function DropChannel(st, c)
	local ch = st.chans[c]
	local t = (ch.sinkAcc or 0)
	for i = 1, ch.n do t = t + ch.V[i] + ch.F[i] end
	if ch.head then
		t = t + ch.head.vol + ch.head.film
		RemoveHead(ch.head)
	end
	if t > 0 then
		FC.Move("surface", "lost", t)
		st.bk.surface, st.bk.left = st.bk.surface - t, st.bk.left + t
	end
	FC.FreeChannel(ch, st)
	table.remove(st.chans, c)
end

-- Nodes of all channels on the world.
function FW.Nodes()
	local n = 0
	for i = 1, #regionList do n = n + regionList[i].fc.nodes end
	return n
end

-- Room for `need` more nodes. Dry streams on walls are kept while there is room for them; they
-- all count against abl_max_flow_nodes, the regions of a map are many, and without this a long
-- session ends with every node held by old stains and none left for a body that bleeds now. The
-- streams that go: dry, with no head, with no living stream running into them or branching from
-- them; the longest dry and the farthest first. Returns the nodes freed.
local cand = {}
local function Older(a, b) return a.sc > b.sc end
function FW.MakeRoom(need)
	local now = CurTime()
	-- (asked again and again while nothing is dry: looked at four times a second at most)
	if now < (FW.noRoomUntil or 0) then return 0 end
	local nc = 0
	for ri = 1, #regionList do
		local reg = regionList[ri]
		local chans = reg.fc.chans
		for c = 1, #chans do chans[c].inUse = false end
		for c = 1, #chans do
			local ch = chans[c]
			if not ch.done or ch.head then
				if ch.joinCh then ch.joinCh.inUse = true end
				if ch.parentCh then ch.parentCh.inUse = true end
			end
		end
		for c = 1, #chans do
			local ch = chans[c]
			if ch.done and not ch.head and not ch.inUse then
				nc = nc + 1
				local e = cand[nc]
				if not e then e = {} cand[nc] = e end
				e.ch, e.reg, e.sc = ch, reg, (now - ch.fedT) + reg.dist * 0.05
			end
		end
	end
	for i = nc + 1, #cand do cand[i] = nil end
	if nc == 0 then
		FW.noRoomUntil = now + 0.25
		return 0
	end
	table.sort(cand, Older)
	local freed = 0
	for i = 1, nc do
		local e = cand[i]
		local st = e.reg.fc
		for c = 1, #st.chans do
			if st.chans[c] == e.ch then
				freed = freed + e.ch.n
				DropChannel(st, c)
				e.reg.swept = true
				FW.evicted = (FW.evicted or 0) + 1
				break
			end
		end
		e.ch = nil
		if freed >= need then break end
	end
	for ri = 1, #regionList do
		local reg = regionList[ri]
		if reg.swept then
			reg.swept = nil
			local chans = reg.fc.chans
			for c = 1, #chans do
				if chans[c].joinCh and chans[c].joinCh.dead then chans[c].joinCh = nil end
				if chans[c].parentCh and chans[c].parentCh.dead then chans[c].parentCh = nil end
			end
			FC.Reindex(reg.fc)
		end
	end
	return freed
end

-- Liquid blood all world channels hold (books).
function FW.Volume()
	local t = 0
	for i = 1, #regionList do
		local st = regionList[i].fc
		t = t + FC.Held(st)
		for c = 1, #st.chans do t = t + (st.chans[c].sinkAcc or 0) end
	end
	return t
end

-- A running or hanging head near a point of a surface facing the same way.
function FW.FindNear(x, y, z, nx, ny, nz, radius)
	local r2 = radius * radius
	for i = 1, #heads do
		local r = heads[i]
		if r.nx * nx + r.ny * ny + r.nz * nz > 0.8 then
			local dx, dy, dz = r.x - x, r.y - y, r.z - z
			if dx * dx + dy * dy + dz * dz < r2 then return r end
		end
	end
	return nil
end

-- Fresh blood joining a head: the mix is younger, and it runs again.
local function AddToHead(r, vol)
	local tot = r.vol + vol
	r.bage = r.bage * r.vol / max(tot, 1e-6)
	r.vol = tot
	if r.state == "stop" then
		r.state = "run"
		r.cx, r.cy, r.cz = r.x, r.y, r.z
	end
	local bk = r.reg.fc.bk
	bk.fed, bk.surface = bk.fed + vol, bk.surface + vol
	r.chan.done, r.chan.idleT, r.chan.fedT = false, 0, CurTime()
end

-- A new stream at a point of a surface. Returns its head (or the head it joined), nil when there is
-- no room. (The caller books the blood onto the surface.)
function FW.Spawn(x, y, z, nx, ny, nz, vol, surf, ent, hanging, noMerge, owner)
	if not (ABL.GoodVol(vol) and ABL.InWorld(x, y, z) and nx * nx + ny * ny + nz * nz > 0.5) then return nil end
	surf = surf or C.Surfaces.default
	if not noMerge then
		local e = FW.FindNear(x, y, z, nx, ny, nz, 1.6)
		if e then
			AddToHead(e, vol)
			return e
		end
	end
	if #heads >= L.Cap(C.cl.maxRunoff) then return nil end
	-- (short of nodes, or the walls hold more than their share: the oldest dry streams make way)
	local nodeCap = L.Cap(FC.cvNodes)
	if FC.nodes >= nodeCap or FW.Nodes() >= nodeCap * K.worldShare then
		FW.MakeRoom(nodeCap * 0.1)
		-- (no dry stream to drop: the blood stays the stain it is)
		if FC.nodes >= nodeCap or FW.Nodes() >= nodeCap * K.worldShare then return nil end
	end
	local reg = Region(x, y, z)
	local st = reg.fc
	-- (over the cap of channels kept: the oldest dry one of this region goes)
	if #st.chans >= K.worldChans then
		local oi
		for c = 1, #st.chans do
			if st.chans[c].done and not st.chans[c].head then oi = c break end
		end
		if not oi then return nil end
		FC.FreeChannel(st.chans[oi], st)
		table.remove(st.chans, oi)
		for c = 1, #st.chans do
			if st.chans[c].joinCh and st.chans[c].joinCh.dead then st.chans[c].joinCh = nil end
		end
		FC.Reindex(st)
	end
	local now = CurTime()
	local ch = FC.NewChannel(reg, st, nil)
	ch.world, ch.surf = true, surf
	ch.owner = owner
	if IsValid(ent) then ch.ent, ch.entPos, ch.entAng = ent, ent:GetPos(), ent:GetAngles() end
	local n = FC.AddWorldNode(ch, st, x, y, z, nx, ny, nz, surf.absorb or 0, now)
	ch.wmax[n] = 0.06
	reg.lx, reg.ly, reg.lz = x + nx * 2, y + ny * 2, z + nz * 2
	reg.lnx, reg.lny, reg.lnz = nx, ny, nz
	st.bk.fed, st.bk.surface = st.bk.fed + vol, st.bk.surface + vol
	return NewHead(ch, reg, x, y, z, nx, ny, nz, vol, surf, hanging)
end

-- Blood that arrives where a stream already has its bed (a pool's tip that goes on feeding the
-- stream it began): it goes into that stream at its nearest node within `radius` and runs down
-- with it. Returns true when there was one.
function FW.Join(x, y, z, nx, ny, nz, vol, radius)
	if not (ABL.GoodVol(vol) and ABL.InWorld(x, y, z)) then return false end
	local reg = regions[ABL.CellKey(x, y, z, REGION)]
	if not reg then return false end
	local och, oi = FC.Near(reg.fc, x, y, z, radius or 1.2, nil)
	if not och then return false end
	local a = och.an[oi]
	if a.nx * nx + a.ny * ny + a.nz * nz <= 0.8 then return false end
	local V = och.V
	local tot = V[oi] + vol
	och.age[oi] = och.age[oi] * V[oi] / tot
	V[oi] = tot
	och.done, och.idleT, och.fedT = false, 0, CurTime()
	reg.fc.bk.fed, reg.fc.bk.surface = reg.fc.bk.fed + vol, reg.fc.bk.surface + vol
	return true
end

-- A drop that landed on a wall or slope (the caller has booked it as a wet stain).
function FW.Deposit(x, y, z, nx, ny, nz, vol, surf, ent, owner)
	if not (ABL.GoodVol(vol) and ABL.InWorld(x, y, z)) then return end
	-- onto a stream that runs there: it joins it where it landed, and runs down with it
	local reg = regions[ABL.CellKey(x, y, z, REGION)]
	if reg then
		local och, oi = FC.Near(reg.fc, x, y, z, 1.2, nil)
		if och then
			local a = och.an[oi]
			if a.nx * nx + a.ny * ny + a.nz * nz > 0.8 then
				local V = och.V
				local tot = V[oi] + vol
				och.age[oi] = och.age[oi] * V[oi] / tot
				V[oi] = tot
				och.done, och.idleT, och.fedT = false, 0, CurTime()
				FC.stainWet = max(FC.stainWet - vol, 0)
				reg.fc.bk.fed, reg.fc.bk.surface = reg.fc.bk.fed + vol, reg.fc.bk.surface + vol
				return
			end
		end
	end
	local r = FW.FindNear(x, y, z, nx, ny, nz, 1.6)
	if r then
		AddToHead(r, vol)
		FC.stainWet = max(FC.stainWet - vol, 0)
		return
	end
	-- enough blood on this spot of the wall to run: a stream starts, out of the wet stains there
	surf = surf or C.Surfaces.default
	local _, _, _, tm, _, gmag = Tangent(nx, ny, nz)
	local wetVol = ABL.Surface.WetGet(x, y, z)
	local drive = (wetVol ^ 0.6667) * tm / gmag
	local thresh = RC.adhesion * surf.adhesion * (wetVol > 0.15 and 0.35 or 1)
	if drive > thresh and FW.Spawn(x, y, z, nx, ny, nz, wetVol * 0.85, surf, ent, false, true, owner) then
		ABL.Surface.WetTake(x, y, z, wetVol * 0.85)
		local take = min(wetVol * 0.85, FC.stainWet)
		FC.stainWet = FC.stainWet - take
		-- (the wetness grid may hold more than the stains were booked with: that is new blood)
		if wetVol * 0.85 > take then FC.Release("surface", wetVol * 0.85 - take) end
	end
end

-- A drop that landed under a ceiling. Returns true when its blood is in a hanging head now.
function FW.Pendant(x, y, z, nx, ny, nz, vol, surf, ent, owner)
	if not (ABL.GoodVol(vol) and ABL.InWorld(x, y, z)) then return false end
	local r = FW.FindNear(x, y, z, nx, ny, nz, 1.3)
	if r then
		AddToHead(r, vol)
		return true
	end
	return FW.Spawn(x, y, z, nx, ny, nz, vol, surf, ent, true, true, owner) ~= nil
end

------------------------------------------------------------------------------------------
-- The head
------------------------------------------------------------------------------------------
local function Lay(r, ch, st, now)
	if ch.n >= K.maxNodes then return false end
	local nodeCap = L.Cap(FC.cvNodes)
	if FC.nodes >= nodeCap or FW.Nodes() >= nodeCap * K.worldShare then
		FW.MakeRoom(nodeCap * 0.1)
		if FC.nodes >= nodeCap or FW.Nodes() >= nodeCap * K.worldShare then return false end
	end
	-- (not on top of the node it stands on)
	local a = ch.an[ch.n]
	local dx, dy, dz = a.px - r.x, a.py - r.y, a.pz - r.z
	if dx * dx + dy * dy + dz * dz < 0.04 then return false end
	FC.Laid(r, ch, FC.AddWorldNode(ch, st, r.x, r.y, r.z, r.nx, r.ny, r.nz, r.surf.absorb or 0, now))
	return true
end

-- linked: it follows the one before closely, and the two fall as one stream (cl_droplets.lua draws
-- linked drops as a ribbon)
local function Drip(r, vol, linked)
	vol = min(vol, r.vol)
	if vol <= 0 then return end
	r.vol = r.vol - vol
	local bk = r.reg.fc.bk
	bk.surface, bk.left = bk.surface - vol, bk.left + vol
	local d = Drops.Spawn(r.x + r.nx * 0.3, r.y + r.ny * 0.3, r.z + r.nz * 0.3, 0, 0, 0, vol, nil, 0, linked and 1 or 0, "surface", r.chan and r.chan.owner)
	if linked and r.chan then Drops.Link(d, r.chan, "drip") end
end

-- The channel ends on a floor: the head's blood goes into the pool there, and what comes down the
-- channel afterwards follows it (FW.Step hands it over).
local upVec = Vector()
local function Sink(r, ch, x, y, z, hn, surf, ent, dx, dy, dz)
	ch.sink = { x = x, y = y, z = z, n = Vector(hn.x, hn.y, hn.z), surf = surf, ent = ent, dx = dx, dy = dy, dz = dz }
	ch.sinkAcc = (ch.sinkAcc or 0) + r.vol + r.film
	ch.sinkT = 0
	r.vol, r.film = 0, 0
	RemoveHead(r)
end

-- One step of a head. Returns false when it is gone.
local function StepHead(r, ch, reg, dt, now, tClot)
	local st = reg.fc
	local tx, ty, tz, tm, gn, gmag = Tangent(r.nx, r.ny, r.nz)
	local gx, gy, gz = ABL.Gravity()
	r.ix, r.iy, r.iz = gx, gy, gz
	r.gt = tm / gmag
	r.pn = gn < 0 and -gn / gmag or 0
	r.wx, r.wy, r.wz = r.x, r.y, r.z
	r.bage = r.bage + dt
	local rng = r.rng

	-- hanging drop: on an underside, or gathered on the lip of an open edge
	local underside = gn > 0.35 * gmag
	r.hangK = 0
	if underside or r.state == "hang" then
		local vd = r.dripVol * (underside and gmag / gn or 1)
		r.hangK = r.vol / vd
		if r.vol > vd then
			r.hangT = r.hangT + dt
			-- the drop visibly swells for a moment before gravity wins. (phase 21, C.P21.streamHead) One that
			-- holds more than two drops' worth, as one does that a stream feeds, lets go the sooner the more
			-- it holds, and lets go all of it but one drop (half a millilitre at the most); what it lets go
			-- in quick succession falls as one stream. (It let go one drop every 0.25 to 1.2 s whatever it
			-- held, and a head that a pool fed hung at the plate's edge with 1.9 to 7.4 ml, run p21s_after.)
			local wait, heavy = r.hangWait, headRule and r.vol > 2 * vd
			if heavy then
				local k = 2 * vd / r.vol
				wait = wait * k * k
			end
			if r.hangT > wait then
				r.hangT = 0
				r.hangWait = rng:Range(0.25, 1.2)
				r.dripVol = RC.pendant * rng:Range(0.8, 1.3)
				local dv = vd * rng:Range(0.85, 1)
				if heavy then dv = max(dv, min(r.vol - vd, 0.5)) end
				Drip(r, dv, heavy and now - r.lastDrip < 0.15)
				r.lastDrip = now
			end
		else
			r.hangT = 0
		end
	end
	if r.state == "hang" and (r.edgeHang or tm / gmag < 0.25) then
		r.moving = false
		r.stuckT = r.stuckT + dt
		-- (it takes all that comes down its stream, and lets it go as drops)
		r.bead = nil
		return true
	end

	-- blood that has been out for a while is thicker: it holds on harder and runs slower
	local visc = FC.ClotF(r.bage / (tClot / (r.surf.dry or 1)))

	-- direction: down the fall line, or along the crease of a valley between two surfaces
	local dx, dy, dz, slope
	local crease = r.creaseLeft > 0
	if crease then
		dx, dy, dz, slope = r.kx, r.ky, r.kz, r.kslope
	elseif tm >= 1e-3 then
		dx, dy, dz, slope = tx / tm, ty / tm, tz / tm, tm / gmag
	end
	local wet = ABL.Surface.WetGet(r.x, r.y, r.z)
	local drive = dx and (max(r.vol, 0) ^ 0.6667) * slope or 0
	local thresh = RC.adhesion * r.surf.adhesion * (wet > 0.15 and 0.35 or 1) * min(visc, 20)
	-- (phase 21, C.P21.streamHead) Its bead: what it needs to run here (its weight along the surface against
	-- the hold of its contact line) and a little more, streamBead at least. Of what comes down its stream it
	-- takes no more than that (cl_flowcore.lua, StepChannel): the rest stays in the stream, which runs on
	-- behind it as fast as it runs. Where nothing pulls it along it takes all that comes, as it did.
	if headRule and dx and slope > 1e-3 then
		r.bead = max(C.P21.streamBead, (thresh / slope) ^ 1.5 * C.P21.streamBeadRun)
	else
		r.bead = nil
	end
	if drive <= thresh then
		r.state = "stop"
		r.moving = false
		r.stuckT = r.stuckT + dt
		r.vx, r.vy, r.vz = 0, 0, 0
		-- enough blood on a gentle slope gathers into a pool where it came to rest
		local up = -(r.nx * gx + r.ny * gy + r.nz * gz) / gmag
		if r.vol >= RC.collect and up >= 0.25 then
			if r.dist > 0.2 then Lay(r, ch, st, now) end
			upVec:SetUnpacked(r.nx, r.ny, r.nz)
			Sink(r, ch, r.x, r.y, r.z, upVec, r.surf, ch.ent, nil, nil, nil)
			return false
		end
		return true
	end
	r.state = "run"
	r.moving = true
	r.stuckT = 0
	r.last = now
	local n = ch.n
	local sp = RC.speed * r.surf.runoff * (r.vol ^ 0.3333) * slope * (1 - thresh / drive) / visc
	-- well supplied, the front runs as fast as the stream behind it
	if r.vol > K.headFull then
		local us = ch.us[n] * min(1, (r.vol - K.headFull) / K.headFull + 0.3) / visc
		if us > sp then sp = us end
	end
	sp = math.Clamp(sp, 0.3, K.maxSpeed)
	local step = sp * dt
	-- (the stretch ahead has to be looked at and the frame has no trace left for it: the head waits
	-- where it is, and wets nothing meanwhile)
	if r.moved + step >= RC.checkDist and L.traces >= L.traceBudget then return true end
	-- the heading wanders off the fall line with the distance run (roughness of the surface)
	if not crease then
		local ml = K.meanderLen * 1.5
		r.mz = r.mz - r.mz * min(1, step / ml) + rng:Normal() * K.meanderAmp * 0.7 * sqrt(2 * min(step / ml, 0.5))
		local sx, sy, sz = r.ny * dz - r.nz * dy, r.nz * dx - r.nx * dz, r.nx * dy - r.ny * dx
		local cm, sm = math.cos(r.mz), math.sin(r.mz)
		dx, dy, dz = dx * cm + sx * sm, dy * cm + sy * sm, dz * cm + sz * sm
	else
		r.creaseLeft = r.creaseLeft - step
	end
	r.vx, r.vy, r.vz = dx * sp, dy * sp, dz * sp
	local nx2, ny2, nz2 = r.x + dx * step, r.y + dy * step, r.z + dz * step

	-- the film it wets the surface with (less on a path that is already wet)
	local loss = min(r.vol, step * RC.filmLoss * (wet > 0.15 and 0.3 or 1) * (1 + r.surf.absorb))
	r.vol = r.vol - loss
	r.film = r.film + loss
	ABL.Surface.WetAdd(r.x, r.y, r.z, loss, C.Stain.dryBase * 2 / r.surf.dry)

	-- a heavy head splits a finger off now and then
	if not crease and r.vol > RC.forkVol and rng:Next() < dt * RC.forkRate * (r.vol - RC.forkVol) then
		local share = r.vol * rng:Range(0.3, 0.45)
		local sx, sy, sz = ABL.Norm(r.ny * dz - r.nz * dy, r.nz * dx - r.nx * dz, r.nx * dy - r.ny * dx)
		local side = rng:Next() < 0.5 and -1 or 1
		local o = FW.Spawn(r.x + sx * side * 0.5, r.y + sy * side * 0.5, r.z + sz * side * 0.5, r.nx, r.ny, r.nz, share, r.surf, ch.ent, false, true, ch.owner)
		if o then
			r.vol = r.vol - share
			st.bk.fed, st.bk.surface = st.bk.fed - share, st.bk.surface - share
			o.bage = r.bage
			o.mz, r.mz = side * 0.5, -side * 0.5
			-- (phase 21, C.P21.streamHead: the finger takes its share of this head and nothing of the stream
			-- after it; what comes down later stays in the stream's own bed. It went on taking 40 % of what
			-- stood at the node it left, and fingers ran side by side with their stream, run p21s_after)
			o.chan.parentCh, o.chan.parentIdx = ch, n
			if headRule then o.chan.share, o.chan.pud = 0, false else o.chan.share, o.chan.pud = 0.4, true end
		end
	end

	r.moved = r.moved + step
	r.dist = r.dist + step
	r.travel = r.travel + step
	r.chk = r.chk + step
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
			local up = -(hn.x * gx + hn.y * gy + hn.z * gz) / gmag
			if up > 0.64 then
				-- reached the floor: the stream ends in a pool, and goes on feeding it
				r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
				Lay(r, ch, st, now)
				Sink(r, ch, tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, hn, ABL.Surface.FromTrace(tr), IsValid(tr.Entity) and tr.Entity or nil, dx, dy, dz)
				return false
			end
			-- inner corner. If blood on the new plane would run straight back into this one, the
			-- two planes form a valley: follow the crease downhill, or gather where it is level
			local t2x, t2y, t2z, t2m = Tangent(hn.x, hn.y, hn.z)
			if t2m > 1e-3 and (t2x * r.nx + t2y * r.ny + t2z * r.nz) / t2m < -0.2 then
				local kx, ky, kz = ABL.Norm(r.ny * hn.z - r.nz * hn.y, r.nz * hn.x - r.nx * hn.z, r.nx * hn.y - r.ny * hn.x)
				local kg = (kx * gx + ky * gy + kz * gz) / gmag
				if kg < 0 then kx, ky, kz, kg = -kx, -ky, -kz, -kg end
				r.x = tr.HitPos.x - r.nx * 0.35 + hn.x * 0.4
				r.y = tr.HitPos.y - r.ny * 0.35 + hn.y * 0.4
				r.z = tr.HitPos.z - r.nz * 0.35 + hn.z * 0.4
				r.cx, r.cy, r.cz = r.x, r.y, r.z
				Lay(r, ch, st, now)
				if kg < 0.06 or (kx == 0 and ky == 0 and kz == 0) then
					r.state = "stop"
					r.moving = false
					r.bead = nil
					return true
				end
				r.kx, r.ky, r.kz, r.kslope, r.creaseLeft = kx, ky, kz, kg, 12
				return true
			end
			-- outer bend onto the new plane
			r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
			Lay(r, ch, st, now)
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
			-- open edge: it stays on the lip (the last verified point) and drips from there
			r.x, r.y, r.z = cx, cy, cz
			Lay(r, ch, st, now)
			r.state = "hang"
			r.edgeHang = true
			r.atEdge = true
			r.moving = false
			r.hangT = r.hangWait
			r.bead = nil
			-- (phase 21, C.P21.streamHead: a bead that comes to the edge with more than two drops' worth lets
			-- all but one go at once; the stream behind it fills the hanging drop again. It took in the front
			-- of its stream first and held 0.58 ml for a moment, run p21h_after)
			if headRule and r.vol > 2 * r.dripVol then
				Drip(r, r.vol - r.dripVol, false)
				r.lastDrip = now
			end
			return true
		end
		local hn = tr.HitNormal
		r.x, r.y, r.z = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
		r.nx, r.ny, r.nz = hn.x, hn.y, hn.z
		r.cx, r.cy, r.cz = r.x, r.y, r.z
		-- nodes only at verified positions, so a stream never leaves the surface
		Lay(r, ch, st, now)
	end

	-- another stream in the way: join it
	if r.chk >= 0.3 then
		r.chk = 0
		local och, oi = FC.Near(st, r.x, r.y, r.z, K.mergeWorld, ch)
		if och and not (och == ch.parentCh and r.travel < 2) then
			-- (never in a circle)
			local c, loop = och, false
			for _ = 1, 12 do
				if c == ch then loop = true break end
				c = c.joinCh
				if not c then break end
			end
			if not loop then
				if r.dist > 0.2 then Lay(r, ch, st, now) end
				local V = och.V
				local tot = V[oi] + r.vol
				if tot > 0 then
					och.age[oi] = (och.age[oi] * V[oi] + r.bage * r.vol) / tot
					V[oi] = tot
				end
				och.F[oi] = och.F[oi] + r.film
				och.done, och.idleT = false, 0
				ch.joinCh, ch.joinIdx = och, oi
				r.vol, r.film = 0, 0
				RemoveHead(r)
				return false
			end
		end
	end
	return true
end

------------------------------------------------------------------------------------------
-- Step: every simulation tick; each region at the rate its distance allows
------------------------------------------------------------------------------------------
function FW.Step(h)
	if #regionList == 0 then return end
	Drops = Drops or ABL.Drops
	headRule = C.P21On("streamHead")
	local Sim = ABL.Sim
	local now, simT = CurTime(), Sim.t
	local gx, gy, gz, gmag = ABL.Gravity()
	local gscale = gmag / C.DEFAULT_GRAVITY
	local dryScale = C.sv.drying:GetFloat()
	local tClot, tFilm, tWet = K.clotTime * dryScale, K.filmDry * dryScale, K.wetTime * dryScale
	for ri = #regionList, 1, -1 do
		local reg = regionList[ri]
		local st = reg.fc
		local chans = st.chans
		if #chans == 0 then
			regions[reg.key] = nil
			table.remove(regionList, ri)
		else
			if now > reg.hzT then
				reg.hzT = now + 0.4 + math.random() * 0.2
				-- how far the nearest of its streams is; streams on props that have moved are dropped
				local best = math.huge
				local dropped = false
				for c = #chans, 1, -1 do
					local ch = chans[c]
					if ch.entPos and (not IsValid(ch.ent) or ch.ent:GetPos():DistToSqr(ch.entPos) > 1) then
						LeaveOn(ch)
						DropChannel(st, c)
						dropped = true
					else
						local a = ch.an[ch.n]
						local d = (a.px - L.eyeX) ^ 2 + (a.py - L.eyeY) ^ 2 + (a.pz - L.eyeZ) ^ 2
						if d < best then best = d end
					end
				end
				if dropped then
					for c = 1, #chans do
						if chans[c].joinCh and chans[c].joinCh.dead then chans[c].joinCh = nil end
						if chans[c].parentCh and chans[c].parentCh.dead then chans[c].parentCh = nil end
					end
					FC.Reindex(st)
				end
				reg.dist = sqrt(best)
				reg.hz = Sim.TierAt(reg.dist).runoffHz
				reg.lod = (reg.dist < 420 and C.LOD_ULTRA) or (reg.dist < 950 and C.LOD_HIGH) or C.LOD_MEDIUM
			end
			reg.acc = reg.acc + h
			if reg.acc + 1e-6 >= Sim.Period(reg.hz) then
				local dt = reg.acc
				reg.acc = 0
				for c = 1, #chans do
					-- (a head that needs room may drop a dry channel of this very list: the list is
					-- shorter then than when the loop began)
					local ch = chans[c]
					local r = ch and ch.head
					if r then
						r.px, r.py, r.pz = r.x, r.y, r.z
						r.lt, r.sd = simT, dt
						if not r.moving and r.bage >= tClot and r.vol > 0 and r.state ~= "hang" then
							-- it has sat too long: the bead sets where it is
							local n = ch.n
							ch.Cv[n] = ch.Cv[n] + r.vol
							ch.F[n] = ch.F[n] + r.film
							FC.Move("surface", "clotted", r.vol)
							st.bk.surface, st.bk.clotted = st.bk.surface - r.vol, st.bk.clotted + r.vol
							r.vol, r.film = 0, 0
							RemoveHead(r)
						elseif StepHead(r, ch, reg, dt, now, tClot) then
							-- a head with nothing left and nothing coming is no head: the stream ends there
							if r.vol < 0.004 and not r.moving and (ch.mobile or 0) < 0.002 and now - ch.fedT > 1.5 then
								r.idle = r.idle + dt
								if r.idle > 2 then
									ch.F[ch.n] = ch.F[ch.n] + r.vol + r.film
									r.vol, r.film = 0, 0
									RemoveHead(r)
								end
							else
								r.idle = 0
							end
						end
					elseif ch and ch.wantHead then
						-- a channel whose head is gone and that fills up again at its end gets a new head there
						ch.wantHead = nil
						local n = ch.n
						local a = ch.an[n]
						local vol = (ch.V[n] - ch.hold[n]) * 0.85
						if vol > 0 and #heads < L.Cap(C.cl.maxRunoff) then
							ch.V[n] = ch.V[n] - vol
							local nh = NewHead(ch, reg, a.px, a.py, a.pz, a.nx, a.ny, a.nz, vol, ch.surf, false)
							nh.bage = ch.age[n]
						end
					end
				end
				FC.StepLiquid(st, reg, nil, nil, dt, now, reg.lod, gx, gy, gz, gmag, gscale, tClot, tFilm, tWet)
				-- streams that end on a floor: what has come down goes into the pool there
				for c = 1, #chans do
					local ch = chans[c]
					local acc = ch.sinkAcc
					if acc and acc > 0 and (acc > 0.05 or now > (ch.sinkT or 0)) then
						local sk = ch.sink
						ch.sinkAcc = 0
						ch.sinkT = now + 0.3
						FC.Move("surface", "pool", acc)
						st.bk.surface, st.bk.left = st.bk.surface - acc, st.bk.left + acc
						ABL.Pools.Deposit(sk.x, sk.y, sk.z, sk.n, acc, sk.surf, sk.ent, sk.dx and "runoff" or "seep", sk.dx, sk.dy, sk.dz, nil, ch.owner)
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Drawing: each region through the flow core's renderer (cl_flowdraw.lua), with the world as
-- the "pose": a node is where it is.
------------------------------------------------------------------------------------------
local IDENT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }
local WorldPose = {}
function WorldPose:SkinPoint(a) return a.px, a.py, a.pz, a.nx, a.ny, a.nz end
function WorldPose:BoneInv() return IDENT end
-- where a head is, between its last two steps
function WorldPose:HeadPoint(r)
	local al = ABL.Sim.Alpha(r.lt, r.sd)
	return r.px + (r.x - r.px) * al, r.py + (r.y - r.py) * al, r.pz + (r.z - r.pz) * al, r.nx, r.ny, r.nz
end

function FW.Draw()
	if #regionList == 0 then return end
	local t0 = SysTime()
	local now, rt = CurTime(), RealTime()
	local dryT = 160 * C.sv.drying:GetFloat()
	local maxD = C.cl.drawDist:GetFloat()
	local VW = F.VW
	local gx, gy, gz, gmag = ABL.Gravity()
	VW.ux, VW.uy, VW.uz = -gx / gmag, -gy / gmag, -gz / gmag
	VW.ex, VW.ey, VW.ez = L.eyeX, L.eyeY, L.eyeZ
	local sx, sy, sz, vis = R.Sun()
	if sx then VW.sx, VW.sy, VW.sz, VW.sk = sx, sy, sz, vis else VW.sx, VW.sy, VW.sz, VW.sk = VW.ux, VW.uy, VW.uz, 0.35 end
	-- (phase 21, C.P21.streamLiquid) the liquid's own colour in the light a pool there is lit with
	-- (cl_pools.lua, BuildMesh: as a model lying there, R.ModelLight, while C.V19's poolModelLight is on)
	local liquid = C.P21On("streamLiquid")
	local modelLight = liquid and C.V19On ~= nil and C.V19On("poolModelLight") and R.ModelLight ~= nil
	for i = 1, #regionList do
		local reg = regionList[i]
		local _, seen = L.View(reg.cx, reg.cy, reg.cz, reg.rad)
		if seen and reg.dist < maxD then
			if rt > reg.lightT then
				reg.lightT = rt + 2 + math.random()
				reg.lr, reg.lg, reg.lb = R.Light(reg.lx, reg.ly, reg.lz)
				if modelLight then
					local nx, ny, nz = reg.lnx, reg.lny, reg.lnz
					local r, g, b, fit = R.ModelLight(reg.lx - nx * 2, reg.ly - ny * 2, reg.lz - nz * 2, nx, ny, nz)
					reg.mr, reg.mg, reg.mb = r, g, b
					-- (no fit left this frame: the plain light for now, the fit soon)
					if not fit then reg.lightT = rt + 0.1 end
				else
					reg.mr, reg.mg, reg.mb = reg.lr, reg.lg, reg.lb
				end
			end
			VW.lr, VW.lg, VW.lb = reg.lr, reg.lg, reg.lb
			VW.mr, VW.mg, VW.mb = reg.mr, reg.mg, reg.mb
			FD.Source(reg, WorldPose, FC.WORLD, reg.dist < 1500, reg.dist < 700, RC.offset * 0.6, now, dryT)
		end
	end
	VW.mr, VW.mg, VW.mb = nil, nil, nil
	R.EndFilter()
	ABL.Prof.Add("draw.flowworld", SysTime() - t0)
end

function FW.Clear()
	for i = #regionList, 1, -1 do
		local st = regionList[i].fc
		for c = #st.chans, 1, -1 do FC.FreeChannel(st.chans[c], st) end
		regionList[i] = nil
	end
	for k in pairs(regions) do regions[k] = nil end
	for i = #heads, 1, -1 do heads[i] = nil end
end
