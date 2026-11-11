-- Body-surface flow.
-- Blood that seeps from a wound forms a bead on the actual body mesh. Each step the world
-- gravity vector (plus the inertial pseudo-force of the accelerating body part) is split into a
-- component normal to the current triangle and a tangential component:
--   * tangential part drives the bead along the skin once surface adhesion is overcome
--     (larger beads and already-wet skin move more easily),
--   * normal part pulls it off the surface: on undersides the bead hangs, swells and detaches as
--     a drop, and violent accelerations fling it off.
-- Beads walk across triangle edges using mesh adjacency and cross small gaps between separate
-- mesh pieces (zipper strips, clothing layers). They lose volume as a film (which later makes new
-- blood follow old paths), leave streak segments stored in bone space, and detach at open edges
-- and low points. A bead that cannot run on a flat area spreads into a puddle soaked into the
-- cloth; once the puddle is full it overflows from its downhill side, so blood on a body lying on
-- its back still finds its way to the flanks and down to the floor. Drops that would form against
-- the ground seep under the body into the pool there. Because everything is recomputed from the
-- current pose, rotating, flipping or dragging the body changes where blood runs immediately.
--
-- Streaks are rendered as one static mesh per (character, bone) in that bone's local space and
-- drawn with the bone matrix as model matrix, so they follow the body with no per-vertex work.

ABL.NoJIT()
ABL.Flow = ABL.Flow or {}
local F = ABL.Flow
local C, L, BM = ABL.Config, ABL.LOD, ABL.BodyMesh
local FC = ABL.FlowCore
local FM, FMD = ABL.Film, ABL.FilmDraw
local B = C.Body
local sqrt, min, max, abs, pi = math.sqrt, math.min, math.max, math.abs, math.pi

local blobPool = ABL.NewPool(function() return {} end)
F.count = 0
F.segTotal = 0
local SEG_PER_SOURCE = 400
-- profiling accumulators (ms / calls since the last reset; read by the test harness)
F.prof = F.prof or { step = 0, steps = 0, walk = 0, bridge = 0, bridges = 0, seep = 0, seeps = 0 }
local prof = F.prof

function F.FreeBlob(b)
	if b.dead then return end
	b.dead = true
	if b.tethered and b.tethered.bead == b then b.tethered.bead = nil end
	b.tethered = nil
	b.trail = nil
	b.src = nil
	F.count = F.count - 1
	blobPool:Put(b)
end

local function NewBlob(src, tri, u, v, vol)
	local b = blobPool:Get()
	b.dead = false
	b.src, b.tri, b.u, b.v, b.vol = src, tri, u, v, vol
	b.vx, b.vy, b.vz = 0, 0, 0
	b.age, b.dist, b.travel, b.moving = 0, 0, 0, false
	b.trail, b.tethered, b.atEdge = nil, nil, false
	b.wx, b.wy, b.wz, b.nx, b.ny, b.nz = 0, 0, 0, 0, 0, 1
	b.hang, b.stuckT, b.skip, b.mz, b.lastDrip = 0, 0, 0, 0, 0
	b.hangK, b.lastSpill, b.noMerge, b.markR = 0, -1, 0, 0
	b.trapT, b.sampT, b.sampTravel, b.sx, b.sy, b.sz = 0, 0, 0, 0, 0, 0
	b.bridgeTri, b.bridgeT = nil, 0
	-- interpolation: the state before the last step and when that step happened
	b.ptri, b.pu, b.pv = tri, u, v
	b.lt, b.sd = ABL.Sim.t, 0.02
	b.pendMul = src.rng:Range(0.85, 1.2)
	b.rot = src.rng:Next() * 6.2831853
	src.blobs[#src.blobs + 1] = b
	F.count = F.count + 1
	return b
end
F.NewBlob = NewBlob

-- At the per-character cap, the smallest bead that has been resting a while is taken as soaked
-- into the cloth, making room for blood that is actually moving.
local function MakeRoom(src)
	local worst, wi
	local blobs = src.blobs
	for i = 1, #blobs do
		local b = blobs[i]
		if not b.dead and not b.tethered and not b.moving and b.stuckT > 0.8 and (not worst or b.vol < worst.vol) then
			worst, wi = b, i
		end
	end
	if not worst then return false end
	F.FreeBlob(worst)
	ABL.SwapRemove(blobs, wi)
	return true
end

-- evict: may recycle a resting bead of this character (never used from inside F.Step's loop)
function F.CanSpawn(src, evict)
	if F.count >= L.Cap(C.cl.maxBlobs) then return false end
	if #src.blobs < B.maxPerSource then return true end
	return evict and MakeRoom(src) or false
end

-- Seeped blood arriving at a wound.
function F.Feed(src, wd, vol)
	if not ABL.GoodVol(vol) then return end
	-- (as a film that covers the body's surface: cl_film.lua; else as the streams of the flow core,
	-- cl_flowcore.lua; what follows is the older bead model)
	if FM.Uses(src) then return FM.Feed(src, wd, vol) end
	if FC.Uses(src) then return FC.Feed(src, wd, vol) end
	local b = wd.bead
	if not b or b.dead or b.src ~= src then
		if not F.CanSpawn(src, true) then
			-- over budget: the wound drips directly instead
			wd.dripAcc = wd.dripAcc + vol
			return
		end
		b = NewBlob(src, wd.tri, wd.u, wd.v, 0)
		b.tethered = wd
		wd.bead = b
	end
	b.vol = b.vol + vol
	FC.Release("surface", vol)
	src.lbk = (src.lbk or 0) + vol
	ABL.Wounds.Ledger(src, "onBody", vol)
end

-- A drop that landed on its own body continues as surface flow.
local function AddBead(src, bone, x, y, z, vol, vx, vy, vz)
	if not src.mesh then return false end
	local tri, u, v = BM.Anchor(src.pose, bone, x, y, z, 6)
	if not tri then return false end
	-- merge with a free blob already on that triangle
	for _, b in ipairs(src.blobs) do
		if b.tri == tri and not b.tethered and not b.dead then
			b.vol = b.vol + vol
			b.skip = 0
			return true
		end
	end
	if not F.CanSpawn(src, true) then
		-- budget full: the blood joins the nearest free bead within a few units instead of vanishing
		local best, bd = nil, 16
		for _, b in ipairs(src.blobs) do
			if not b.dead and not b.tethered then
				local d = (b.wx - x) ^ 2 + (b.wy - y) ^ 2 + (b.wz - z) ^ 2
				if d < bd then best, bd = b, d end
			end
		end
		if not best then return false end
		best.vol = best.vol + vol
		best.skip = 0
		return true
	end
	local b = NewBlob(src, tri, u, v, vol)
	b.vx, b.vy, b.vz = (vx or 0) * 0.15, (vy or 0) * 0.15, (vz or 0) * 0.15
	return true
end
-- owner: whose blood it is, when it is not this body's own (a drop from another character)
function F.AddAt(src, bone, x, y, z, vol, vx, vy, vz, owner)
	if not ABL.GoodVol(vol) or not ABL.InWorld(x, y, z) then return false end
	if FM.Uses(src) then return FM.AddAt(src, bone, x, y, z, vol, vx, vy, vz, owner) end
	if FC.Uses(src) then return FC.AddAt(src, bone, x, y, z, vol, vx, vy, vz, owner) end
	if not AddBead(src, bone, x, y, z, vol, vx, vy, vz) then return false end
	FC.Move("airborne", "surface", vol)
	src.lbk = (src.lbk or 0) + vol
	return true
end

-- Radius (units) of the patch a resting puddle of `vol` ml covers.
local function PuddleRadius(vol)
	return sqrt(max(vol, 0) / C.ML_PER_CU / (pi * B.film))
end
F.PuddleRadius = PuddleRadius

------------------------------------------------------------------------------------------
-- Streak segments (bone space)
-- Per bone: `segs` (all segments), a static filter mesh and a static gloss mesh (cl. BuildBone), and
-- `segDyn`: the segments drawn live every frame (those in a joint region whose skin bends, and new
-- ones not yet in the static mesh).
------------------------------------------------------------------------------------------
local function EnsureSegs(src)
	if not src.segs then
		src.segs, src.segMesh, src.segDirty, src.segBuild = {}, {}, {}, {}
		src.segGloss, src.segDyn, src.segInfo = {}, {}, {}
		src.segQueue, src.segQHead, src.segQTail, src.segCount = {}, 1, 0, 0
	end
end
F.EnsureSegs = EnsureSegs

-- Is this triangle of the body bare skin? By the material where the model names its skin, else by
-- the body part.
function F.OnSkin(src, tri)
	local m = src.mesh
	if not m or not tri then return false end
	if (m.nskin or 0) > 0 then return m.tskin[tri] == true end
	return F.SkinBone(src, m.tb[tri]) or false
end

-- Is this bone a body part that is bare skin whatever the clothes (head, neck, hands)?
function F.SkinBone(src, bone)
	local sb = src.skinBone
	if not sb then sb = {} src.skinBone = sb end
	local v = sb[bone]
	if v == nil then
		local body = src.body
		local name = IsValid(body) and body:GetBoneName(bone) or ""
		v = string.find(name, "Head", 1, true) ~= nil or string.find(name, "Neck", 1, true) ~= nil
			or string.find(name, "Hand", 1, true) ~= nil or string.find(name, "Finger", 1, true) ~= nil
		sb[bone] = v
	end
	return v
end

local function DropOldestSeg(src)
	local q = src.segQueue
	local s = q[src.segQHead]
	if not s then return end
	q[src.segQHead] = nil
	src.segQHead = src.segQHead + 1
	s.gone = true
	local list = src.segs[s.b]
	if list then
		for i = 1, #list do
			if list[i] == s then table.remove(list, i) break end
		end
		src.segDirty[s.b] = true
	end
	src.segCount = src.segCount - 1
	F.segTotal = F.segTotal - 1
end

local function AddSeg(src, bone, x1, y1, z1, x2, y2, z2, nx, ny, nz, w1, w2, a1, a2)
	EnsureSegs(src)
	local globalCap = L.Cap(C.cl.maxSegs)
	if src.segCount >= SEG_PER_SOURCE or F.segTotal >= globalCap then DropOldestSeg(src) end
	if F.segTotal >= globalCap then return end
	local list = src.segs[bone]
	if not list then list = {} src.segs[bone] = list end
	-- a later bead running down the same wet path refreshes the existing streak instead of
	-- stacking another translucent strip on top of it
	local mx, my, mz = (x1 + x2) * 0.5, (y1 + y2) * 0.5, (z1 + z2) * 0.5
	for i = #list, 1, -1 do
		local o = list[i]
		local ox, oy, oz = (o.x1 + o.x2) * 0.5 - mx, (o.y1 + o.y2) * 0.5 - my, (o.z1 + o.z2) * 0.5 - mz
		if ox * ox + oy * oy + oz * oz < 0.16 then
			o.t = CurTime()
			-- fresh blood running over a settled stain makes it a live, wet rivulet again
			if o.settled then o.settled = nil end
			if w1 > o.w1 then o.w1 = min(w1, o.w1 * 1.15 + 0.02) end
			if w2 > o.w2 then o.w2 = min(w2, o.w2 * 1.15 + 0.02) end
			src.segDirty[bone] = true
			return
		end
	end
	local s = { b = bone, x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2, nx = nx, ny = ny, nz = nz, w1 = w1, w2 = w2, t = CurTime(), a = 222 + (src.segQTail % 5) * 6, a1 = a1, a2 = a2 }
	list[#list + 1] = s
	-- neighbours along the run (the live strips take a point's direction from them)
	if a1 and a2 then a1.na, a2.pa = a2, a1 end
	-- on bare skin (by the mesh's material, or the body part: head, neck, hands) blood does not soak in
	if a1 then
		local ts = a1[4].tskin
		s.skin = (ts and ts[a1[1]]) or F.SkinBone(src, bone)
	end
	-- drawn live until the bone's static mesh is rebuilt with it
	local dyn = src.segDyn[bone]
	if not dyn then dyn = {} src.segDyn[bone] = dyn end
	dyn[#dyn + 1] = s
	src.segQTail = src.segQTail + 1
	src.segQueue[src.segQTail] = s
	src.segCount = src.segCount + 1
	F.segTotal = F.segTotal + 1
	src.segDirty[bone] = true
end

function F.FreeSegs(src)
	if not src.segs then return end
	for _, m in pairs(src.segMesh) do m:Destroy() end
	for _, m in pairs(src.segGloss or {}) do m:Destroy() end
	F.segTotal = F.segTotal - (src.segCount or 0)
	src.segs, src.segMesh, src.segDirty, src.segBuild, src.segQueue = nil, nil, nil, nil, nil
	src.segGloss, src.segDyn, src.segInfo = nil, nil, nil
	src.segCount = 0
end

-- Hand all body streaks from one source to another (player -> corpse).
function F.MoveSegs(from, to)
	if not from.segs then return end
	F.FreeSegs(to)
	to.segs, to.segMesh, to.segDirty, to.segBuild = from.segs, from.segMesh, from.segDirty, from.segBuild
	to.segGloss, to.segDyn, to.segInfo = from.segGloss or {}, from.segDyn or {}, from.segInfo or {}
	to.segQueue, to.segQHead, to.segQTail, to.segCount = from.segQueue, from.segQHead, from.segQTail, from.segCount
	from.segs, from.segMesh, from.segDirty, from.segBuild, from.segQueue = nil, nil, nil, nil, nil
	from.segGloss, from.segDyn, from.segInfo = nil, nil, nil
	from.segCount = 0
	for bone in pairs(to.segs) do to.segDirty[bone] = true end
end

-- Record the bead's current position as the next point of its streak.
local function TrailPoint(b, src, pose, m)
	local px, py, pz, pnx, pny, pnz = pose:Point(b.tri, b.u, b.v)
	-- width follows the runnel's volume, with a little slow variation (no per-point jitter)
	local width = (0.2 + 0.42 * (max(b.vol, 0) ^ 0.3333)) * (1 + 0.18 * math.sin(b.age * 2.3 + b.rot))
	local t = b.trail
	-- one anchor table per point, shared by the segment ending and the one starting there
	local an
	if t then
		-- segment from the previous point, expressed in the previous point's bone space
		local inv = pose:BoneInv(t.bone)
		if inv then
			local ex = inv[1] * px + inv[2] * py + inv[3] * pz + inv[4]
			local ey = inv[5] * px + inv[6] * py + inv[7] * pz + inv[8]
			local ez = inv[9] * px + inv[10] * py + inv[11] * pz + inv[12]
			local enx = inv[1] * pnx + inv[2] * pny + inv[3] * pnz
			local eny = inv[5] * pnx + inv[6] * pny + inv[7] * pnz
			local enz = inv[9] * pnx + inv[10] * pny + inv[11] * pnz
			local dx, dy, dz = ex - t.x, ey - t.y, ez - t.z
			if dx * dx + dy * dy + dz * dz < 36 then
				local mnx, mny, mnz = ABL.Norm(t.nx + enx, t.ny + eny, t.nz + enz)
				an = { b.tri, b.u, b.v, m }
				-- texture coordinate along the rivulet: distance travelled (film texture repeats every 6 units)
				t.vacc = (t.vacc or 0) + sqrt(dx * dx + dy * dy + dz * dz) / 6
				an.tv = t.vacc
				AddSeg(src, t.bone, t.x, t.y, t.z, ex, ey, ez, mnx, mny, mnz, t.w, width, t.anchor, an)
			end
		end
	else
		t = {}
		b.trail = t
	end
	-- new point in its own (dominant) bone space
	local bone = m.tb[b.tri]
	local inv = pose:BoneInv(bone)
	if not inv then b.trail = nil return end
	t.bone = bone
	t.x = inv[1] * px + inv[2] * py + inv[3] * pz + inv[4]
	t.y = inv[5] * px + inv[6] * py + inv[7] * pz + inv[8]
	t.z = inv[9] * px + inv[10] * py + inv[11] * pz + inv[12]
	t.nx, t.ny, t.nz = ABL.Norm(inv[1] * pnx + inv[2] * pny + inv[3] * pnz, inv[5] * pnx + inv[6] * pny + inv[7] * pnz, inv[9] * pnx + inv[10] * pny + inv[11] * pnz)
	t.w = width
	-- the same point as a mesh anchor (triangle + barycentrics): near the camera streaks are
	-- re-skinned from these every frame, so they stay on the skin across joints
	t.anchor = an or { b.tri, b.u, b.v, m, tv = t.vacc or 0 }
end

------------------------------------------------------------------------------------------
-- Mesh walking
------------------------------------------------------------------------------------------
local Drops

-- Move blob by world displacement (dx,dy,dz) across the surface. Returns travelled distance.
-- b.atEdge is set when the walk stops on an open boundary of the mesh.
local function Walk(b, pose, m, dx, dy, dz)
	local travelled = 0
	local tri, u, v = b.tri, b.u, b.v
	if dx * dx + dy * dy + dz * dz > 1e-8 then b.atEdge = false end
	for _ = 1, 6 do
		local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = pose:Tri(tri)
		-- keep displacement in this triangle's plane (preserve length)
		local dn = dx * nx + dy * ny + dz * nz
		local len0 = sqrt(dx * dx + dy * dy + dz * dz)
		dx, dy, dz = dx - nx * dn, dy - ny * dn, dz - nz * dn
		local len1 = sqrt(dx * dx + dy * dy + dz * dz)
		if len1 < 1e-7 then break end
		local k = len0 / len1
		dx, dy, dz = dx * k, dy * k, dz * k

		local ex, ey, ez = bx - ax, by - ay, bz - az
		local fx, fy, fz = cx - ax, cy - ay, cz - az
		local g11 = ex * ex + ey * ey + ez * ez
		local g12 = ex * fx + ey * fy + ez * fz
		local g22 = fx * fx + fy * fy + fz * fz
		local det = g11 * g22 - g12 * g12
		if det < 1e-10 then break end
		local r1 = dx * ex + dy * ey + dz * ez
		local r2 = dx * fx + dy * fy + dz * fz
		local du = (g22 * r1 - g12 * r2) / det
		local dv = (g11 * r2 - g12 * r1) / det
		local nu, nv = u + du, v + dv
		local w0 = 1 - u - v
		local w1 = 1 - nu - nv
		if nu >= 0 and nv >= 0 and w1 >= 0 then
			u, v = nu, nv
			travelled = travelled + len0
			break
		end
		-- first edge crossed
		local t, slot = 1, 0
		if nv < 0 then local tt = v / (v - nv) if tt < t then t, slot = tt, 1 end end
		if w1 < 0 then local tt = w0 / (w0 - w1) if tt < t then t, slot = tt, 2 end end
		if nu < 0 then local tt = u / (u - nu) if tt < t then t, slot = tt, 3 end end
		if t < 0 then t = 0 end
		u, v = u + du * t, v + dv * t
		travelled = travelled + len0 * t
		local nb = (slot == 1 and m.n1[tri]) or (slot == 2 and m.n2[tri]) or m.n3[tri]
		if nb == 0 then
			-- open boundary (sleeve, collar, hem, fingertip, edge of a separate mesh piece)
			b.atEdge = true
			local eps = 0.01
			if u < eps then u = eps end
			if v < eps then v = eps end
			local ww = 1 - u - v
			if ww < eps then local s = (1 - eps) / (u + v) u, v = u * s, v * s end
			break
		end
		-- shared edge vertices and the parameter along them
		local ia, ib, s
		if slot == 1 then ia, ib, s = m.t1[tri], m.t2[tri], u            -- A-B, weight of B = u
		elseif slot == 2 then ia, ib, s = m.t2[tri], m.t3[tri], v        -- B-C, weight of C = v
		else ia, ib, s = m.t3[tri], m.t1[tri], 1 - v end                -- C-A, weight of A = 1 - v
		-- barycentric weights of the crossing point in the neighbour (third vertex ~0)
		local q1, q2, q3 = m.t1[nb], m.t2[nb], m.t3[nb]
		local eps = 0.015
		local wa = (q1 == ia and 1 - s) or (q1 == ib and s) or eps
		local wb = (q2 == ia and 1 - s) or (q2 == ib and s) or eps
		local wc = (q3 == ia and 1 - s) or (q3 == ib and s) or eps
		local sum = wa + wb + wc
		tri, u, v = nb, wb / sum, wc / sum
		local rem = 1 - t
		dx, dy, dz = dx * rem, dy * rem, dz * rem
		if rem < 1e-4 then break end
	end
	b.tri, b.u, b.v = tri, u, v
	return travelled
end
F.Walk = Walk

-- At an open edge, try to continue on another mesh piece right across the gap (zipper strip ->
-- jacket, collar -> neck, shirt -> trousers). fx..: flow direction (unit, world).
local function Bridge(b, src, pose, m, fx, fy, fz, gdx, gdy, gdz)
	local now = CurTime()
	if b.bridgeTri == b.tri and now < b.bridgeT then return false end
	b.bridgeTri, b.bridgeT = b.tri, now + 1
	local t0 = SysTime()
	local px, py, pz = pose:Point(b.tri, b.u, b.v)
	local qx, qy, qz = px + fx * 0.3 + gdx * 0.2, py + fy * 0.3 + gdy * 0.2, pz + fz * 0.3 + gdz * 0.2
	local nt, nu, nv = BM.Bridge(pose, m.tb[b.tri], qx, qy, qz, b.tri, B.bridge)
	prof.bridge, prof.bridges = prof.bridge + (SysTime() - t0) * 1000, prof.bridges + 1
	if not nt then return false end
	-- the streak ends on the lip; a new one starts on the other piece
	if b.trail then TrailPoint(b, src, pose, m) end
	b.trail = nil
	b.tri, b.u, b.v = nt, nu, nv
	b.atEdge = false
	b.bridgeTri = nil
	TrailPoint(b, src, pose, m)
	return true
end

------------------------------------------------------------------------------------------
-- Leaving the body
------------------------------------------------------------------------------------------
local seepOut = {}
local seepTrace = { mask = MASK_SOLID, output = seepOut, filter = ABL.Surface.ProbeFilter }
local vA, vB, vUp = Vector(), Vector(), Vector()

-- A drop forming right above the ground (a body lying in its own blood, a shoe sole) does not
-- fall: it seeps along the contact and feeds the pool there. Returns true when it did.
local function GroundSeep(vol, px, py, pz, nx, ny, nz, owner)
	-- (no trace to be had in this frame: not known whether it touches the floor. The second value
	-- says so: the film asks again at its next step, cl_film.lua Leave)
	if not L.TakeTrace() then return false, true end
	local gx, gy, gz, gmag = ABL.Gravity()
	local dx, dy, dz = gx / gmag, gy / gmag, gz / gmag
	vA:SetUnpacked(px + nx * 0.15, py + ny * 0.15, pz + nz * 0.15)
	vB:SetUnpacked(px + dx * B.contact, py + dy * B.contact, pz + dz * B.contact)
	seepTrace.start, seepTrace.endpos = vA, vB
	util.TraceLine(seepTrace)
	local tr = seepOut
	if not tr.Hit then return false end
	local hx, hy, hz, hn
	if tr.StartSolid then
		hx, hy, hz = px, py, pz
		vUp:SetUnpacked(-dx, -dy, -dz)
		hn = vUp
	else
		hx, hy, hz = tr.HitPos.x, tr.HitPos.y, tr.HitPos.z
		hn = tr.HitNormal
	end
	-- only floor-like contact holds the blood; against a wall the drop still falls / runs
	if -(hn.x * dx + hn.y * dy + hn.z * dz) < 0.5 then return false end
	local surf = ABL.Surface.FromTrace(tr)
	ABL.Surface.WetAdd(hx, hy, hz, vol, C.Stain.dryBase * 2 / surf.dry)
	ABL.Pools.Deposit(hx, hy, hz, hn, vol, surf, IsValid(tr.Entity) and tr.Entity or nil, "seep", nil, nil, nil, nil, owner)
	return true
end
F.GroundSeep = GroundSeep

-- down: the drop leaves below the surface point along gravity (a low point / fold of the mesh)
-- instead of off the surface normal
local function Detach(b, src, vol, px, py, pz, nx, ny, nz, bvx, bvy, bvz, push, kind, down)
	vol = min(vol, b.vol)
	if vol <= 0 then return end
	b.vol = b.vol - vol
	b.lastDrip = CurTime()
	b.pendMul = src.rng:Range(0.85, 1.2)
	-- gentle detachments (hanging drops, drops off an edge) next to the ground seep instead
	if push <= 3 then
		local t0 = SysTime()
		local seeped = GroundSeep(vol, px, py, pz, nx, ny, nz, src.key)
		prof.seep, prof.seeps = prof.seep + (SysTime() - t0) * 1000, prof.seeps + 1
		if seeped then
			FC.Move("surface", "pool", vol)
			src.lbk = (src.lbk or 0) - vol
			return
		end
	end
	src.lbk = (src.lbk or 0) - vol
	local lag = math.min(FrameTime(), 0.05)
	local ox, oy, oz = nx * 0.45, ny * 0.45, nz * 0.45
	if down then
		local gx, gy, gz, gmag = ABL.Gravity()
		ox, oy, oz = gx / gmag * 0.6 + nx * 0.1, gy / gmag * 0.6 + ny * 0.1, gz / gmag * 0.6 + nz * 0.1
		nx, ny, nz = 0, 0, 0
	end
	Drops.Spawn(px + ox + bvx * lag, py + oy + bvy * lag, pz + oz + bvz * lag,
		bvx + b.vx + nx * push, bvy + b.vy + ny * push, bvz + b.vz + nz * push, vol, src, 0, kind or 0, "surface")
	ABL.Wounds.Ledger(src, "offBody", vol)
end

local function Untether(b)
	if b.tethered and b.tethered.bead == b then b.tethered.bead = nil end
	b.tethered = nil
end

------------------------------------------------------------------------------------------
-- Step
------------------------------------------------------------------------------------------
local function StepBlob(b, src, pose, m, dt, gx, gy, gz, gmag)
	b.age = b.age + dt
	local tri = b.tri
	local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = pose:Tri(tri)
	local u, v = b.u, b.v
	local px = ax + u * (bx - ax) + v * (cx - ax)
	local py = ay + u * (by - ay) + v * (cy - ay)
	local pz = az + u * (bz - az) + v * (cz - az)
	b.wx, b.wy, b.wz, b.nx, b.ny, b.nz = px, py, pz, nx, ny, nz

	local bone = m.tb[tri]
	local bvx, bvy, bvz, bax, bay, baz = pose:BoneVel(bone)
	-- effective acceleration felt by blood in the body frame: gravity minus body acceleration
	local ix, iy, iz = gx - bax * B.inertia, gy - bay * B.inertia, gz - baz * B.inertia
	local gn = ix * nx + iy * ny + iz * nz           -- > 0: pulled away from the surface
	local tx, ty, tz = ix - nx * gn, iy - ny * gn, iz - nz * gn
	local tmag = sqrt(tx * tx + ty * ty + tz * tz)
	local rng = src.rng

	-- violent acceleration (impact, whip) throws blood off
	if gn > B.flingAccel and b.vol > 0.01 then
		Detach(b, src, b.vol * rng:Range(0.5, 0.9), px, py, pz, nx, ny, nz, bvx, bvy, bvz, 12)
	end

	-- a bead at a wound cannot grow without bound: past what the skin holds it runs off on its own
	if b.tethered and b.vol > B.holdMax then Untether(b) end

	-- pendant drop on undersides: the detach volume shrinks as the surface faces more downward;
	-- the drop visibly swells (hangK) before gravity beats surface tension
	b.hangK = 0
	if gn > 0.3 * gmag then
		local vd = B.pendant * gmag / gn * b.pendMul
		b.hangK = b.vol / vd
		if b.vol > vd and not b.tethered then
			b.hang = b.hang + dt
			-- a heavily fed drop lets go sooner and bigger: dripping turns into a stream
			if b.hang > 0.08 * min(1, 2 * vd / b.vol) then
				b.hang = 0
				local dv = min(max(vd, (b.vol - vd) * 0.6), 0.5)
				Detach(b, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 2, dv > vd * 2 and 1 or 0)
			end
		elseif b.tethered and b.vol > vd * 1.6 then
			-- a wound facing the floor drips directly
			Detach(b, src, vd, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 2)
		end
	else
		-- the drop does not un-form instantly when the bead sways off the underside
		b.hang = max(0, b.hang - dt * 0.5)
	end

	-- stick / slip on the surface (skin that is already wet lets new blood run easily)
	local wet = src.wetTri[tri] or 0
	local thresh = B.adhesion * (wet > 0.01 and B.wetAdhesion or 1)
	local drive = (max(b.vol, 0) ^ 0.6667) * tmag / gmag
	local k = min(1, dt / 0.12)
	if drive <= thresh or tmag < 1e-3 then
		b.vx, b.vy, b.vz = b.vx * (1 - k), b.vy * (1 - k), b.vz * (1 - k)
		b.moving = false
		b.stuckT = b.stuckT + dt
		if not b.tethered then
			-- a resting puddle soaks into cloth / dries on skin (faster the larger its footprint);
			-- the thin remnant a runnel leaves behind on a steep surface is just film and goes fast
			b.vol = b.vol - dt * (0.0008 + B.soak * max(b.vol, 0) ^ 0.6667 + (b.vol < 0.05 and 0.002 or 0))
			if b.stuckT > 40 and b.vol < 0.05 then b.vol = 0 end
			-- the soaked area stays on the body as a skinned engine decal
			local rad = PuddleRadius(b.vol)
			-- (bare skin takes nothing up: there the blood stays the film it is and dries in place)
			if rad > b.markR + 0.45 and src.lod >= C.LOD_HIGH and not F.OnSkin(src, b.tri) then
				b.markR = rad
				ABL.Stains.BodySoak(src.body, px, py, pz, nx, ny, nz, 1.2 + rad * 2.4)
			end
		end
		-- more than the patch can hold overflows from its downhill rim (random side when level)
		local cap = (b.tethered and b.tethered.profile and b.tethered.profile.spreadCap) or B.spreadCap
		if b.vol > cap and b.age - b.lastSpill > 0.3 and F.CanSpawn(src) then
			b.lastSpill = b.age
			local dx, dy, dz
			if tmag > gmag * 0.02 then
				dx, dy, dz = tx / tmag, ty / tmag, tz / tmag
			else
				local sx, sy, sz = ABL.Perp(nx, ny, nz)
				local qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
				local a = rng:Next() * 6.2831853
				local c, s = math.cos(a), math.sin(a)
				dx, dy, dz = sx * c + qx * s, sy * c + qy * s, sz * c + qz * s
			end
			local share = b.vol - cap * 0.6
			b.vol = b.vol - share
			local reach = PuddleRadius(cap) + 0.45
			local nb = NewBlob(src, tri, u, v, share)
			Walk(nb, pose, m, dx * reach, dy * reach, dz * reach)
			nb.vx, nb.vy, nb.vz = dx, dy, dz
			nb.noMerge = CurTime() + 1
			nb.lastSpill = 0
		end
	else
		local over = 1 - thresh / drive
		local sp = B.speed * (b.vol ^ 0.3333) * (tmag / gmag) * over * (1 + min(wet * 20, 1))
		local inv = sp / tmag
		-- runnels meander a little around the fall line (weave, folds, skin texture)
		b.mz = b.mz + (rng:Normal() * 1.1 - b.mz * 1.6) * dt
		local lx, ly, lz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
		local lat = b.mz * 0.35 * inv
		b.vx = b.vx + (tx * inv + lx * lat - b.vx) * k
		b.vy = b.vy + (ty * inv + ly * lat - b.vy) * k
		b.vz = b.vz + (tz * inv + lz * lat - b.vz) * k
		b.moving = true
		b.stuckT = 0
	end

	-- keep velocity tangent to the (rotating) surface
	local vn = b.vx * nx + b.vy * ny + b.vz * nz
	b.vx, b.vy, b.vz = b.vx - nx * vn, b.vy - ny * vn, b.vz - nz * vn

	if b.moving then
		local tw = SysTime()
		local d = Walk(b, pose, m, b.vx * dt, b.vy * dt, b.vz * dt)
		prof.walk = prof.walk + (SysTime() - tw) * 1000
		if d > 0 then
			-- film left behind: less on already-wet paths
			local loss = d * B.filmLoss * (wet > 0.01 and B.wetFilmLoss or 1)
			b.vol = b.vol - loss
			src.wet[bone] = min((src.wet[bone] or 0) + loss, 4)
			src.wetTri[b.tri] = min((src.wetTri[b.tri] or 0) + loss, 1)
			b.dist = b.dist + d
			b.travel = b.travel + d
			-- a bead that ran away from its wound becomes a free runnel; a new bead forms there
			if b.tethered and b.travel > 0.4 then Untether(b) end
			if b.dist >= B.trailSpacing then
				b.dist = 0
				TrailPoint(b, src, pose, m)
			end
		end
		if b.atEdge then
			-- the lip of a separate piece: continue on the piece right across the gap if there is one
			local sp = sqrt(b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
			local fx, fy, fz
			if sp > 1e-3 then fx, fy, fz = b.vx / sp, b.vy / sp, b.vz / sp
			elseif tmag > 1e-3 then fx, fy, fz = tx / tmag, ty / tmag, tz / tmag
			else fx, fy, fz = 0, 0, 0 end
			Bridge(b, src, pose, m, fx, fy, fz, gx / gmag, gy / gmag, gz / gmag)
		end
	end

	-- a runnel that keeps moving without getting anywhere is caught in a pit or fold of the mesh
	-- (a hem folding inward, the gap between two layers): that is a low point, and it drips there
	if b.moving and not b.tethered then
		if b.age - b.sampT >= 0.5 then
			local dx, dy, dz = px - b.sx, py - b.sy, pz - b.sz
			local went = b.travel - b.sampTravel
			if went > 1 and dx * dx + dy * dy + dz * dz < (went * 0.3) ^ 2 then
				b.trapT = b.trapT + (b.age - b.sampT)
			else
				b.trapT = 0
			end
			b.sampT, b.sampTravel, b.sx, b.sy, b.sz = b.age, b.travel, px, py, pz
		end
	else
		b.trapT = 0
	end
	if b.trapT >= 1 and b.vol > B.edgePendant then
		b.hangK = max(b.hangK, 1)
		local since = CurTime() - b.lastDrip
		if since > 0.06 then
			local dv = max(B.pendant, min(b.vol * 0.5, 0.3))
			Detach(b, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 1, since < 0.15 and 1 or 0, true)
		end
	end

	-- open edges and exhausted runnels
	if b.atEdge then
		-- a bead parked on an open edge no longer belongs to its wound: it drips from the lip
		if b.tethered then Untether(b) end
		if b.vol > B.edgePendant then
			-- a drop needs time to form on the lip; strong inflow makes bigger, faster drops that
			-- visually join into a stream
			b.hangK = max(b.hangK, b.vol / (B.edgePendant * 1.6))
			local since = CurTime() - (b.lastDrip or 0)
			if since > 0.06 then
				local dv = max(rng:Range(0.8, 1.2) * B.edgePendant, min(b.vol * 0.5, 0.3))
				Detach(b, src, dv, px, py, pz, nx, ny, nz, bvx, bvy, bvz, 3, since < 0.15 and 1 or 0)
			end
		end
	end
	if b.vol < B.minVol and not b.tethered then
		if b.moving and b.trail then TrailPoint(b, src, pose, m) end
		return false
	end
	return true
end

local wetDecayT = 0
local LAZY_DT = 0.16          -- resting beads are re-evaluated about 6 times a second
function F.Step(h)
	Drops = Drops or ABL.Drops
	local Sim = ABL.Sim
	local gx, gy, gz, gmag = ABL.Gravity()
	local now = CurTime()
	local decay = now > wetDecayT
	if decay then wetDecayT = now + 1 end
	for _, src in ipairs(ABL.Sources.list) do
		local tier = C.LODTiers[src.lod]
		local m = src.mesh
		local blobs = src.blobs
		-- each character's surface flow runs at its tier's rate (every tick up close)
		local run = false
		local dt = 0
		if tier and tier.bodyflow and m and IsValid(src.body) and #blobs > 0 then
			src.flowAcc = (src.flowAcc or (src.seed % 5) * 0.001) + h
			if src.flowAcc + 1e-6 >= Sim.Period(tier.flowHz) then
				dt = src.flowAcc
				src.flowAcc = 0
				run = true
			end
		end
		if run then
			local pose = src.pose
			local simT = Sim.t
			for i = #blobs, 1, -1 do
				local b = blobs[i]
				local keep = true
				if b.dead or not b.tri or b.tri > m.nt then
					keep = false
				else
					-- beads that have been stuck for a while (and are not being fed) are re-evaluated
					-- less often; any motion of the body wakes them through BoneVel/gravity
					local lazy = b.stuckT > 0.5 and not b.tethered
					local t0 = SysTime()
					local sdt = dt
					if lazy then
						b.skip = b.skip + dt
						if b.skip >= LAZY_DT then sdt = b.skip b.skip = 0 else sdt = nil end
					else
						b.skip = 0
					end
					if sdt then
						-- the state before this step, for drawing in between (interpolation)
						b.ptri, b.pu, b.pv = b.tri, b.u, b.v
						b.lt, b.sd = simT, sdt
						keep = StepBlob(b, src, pose, m, sdt, gx, gy, gz, gmag)
						prof.step, prof.steps = prof.step + (SysTime() - t0) * 1000, prof.steps + 1
					end
				end
				if not keep then
					if not b.dead then F.FreeBlob(b) end
					ABL.SwapRemove(blobs, i)
				end
			end
			-- coalescence: beads that meet on the same triangle merge into one (fresh overflow is
			-- given a moment to leave the puddle it came from). Blood welling up at a wound joins
			-- the free puddle or runnel already sitting there: the wound's bead hands over its
			-- volume and stays behind as the source point, so a puddle never gets pulled back into
			-- the wound and the puddle's own dynamics (overflow, dripping, running) carry it away.
			local occ = {}
			for i = #blobs, 1, -1 do
				local b = blobs[i]
				if not b.dead and now >= b.noMerge then
					local o = occ[b.tri]
					if not o then
						occ[b.tri] = b
					elseif o.tethered and b.tethered then
						-- two wounds on one triangle: both stay
					elseif o.tethered or b.tethered then
						local t, f = (o.tethered and o or b), (o.tethered and b or o)
						f.vol = f.vol + t.vol
						t.vol = 0
						f.skip = 0
						occ[b.tri] = f
					else
						local win, lose = (b.vol > o.vol) and b or o, (b.vol > o.vol) and o or b
						local tv = win.vol + lose.vol
						if tv > 0 then
							win.vx = (win.vx * win.vol + lose.vx * lose.vol) / tv
							win.vy = (win.vy * win.vol + lose.vy * lose.vol) / tv
							win.vz = (win.vz * win.vol + lose.vz * lose.vol) / tv
						end
						win.vol = tv
						win.skip, win.stuckT = 0, 0
						win.markR = max(win.markR, lose.markR)
						F.FreeBlob(lose)
						occ[b.tri] = win
					end
				end
			end
			for i = #blobs, 1, -1 do
				if blobs[i].dead then ABL.SwapRemove(blobs, i) end
			end
			local held = 0
			for i = 1, #blobs do held = held + blobs[i].vol end
			local gone = (src.lbk or 0) - held
			if gone > 0 then FC.Move("surface", "dried", gone) end
			src.lbk = held
		end
		if decay then
			-- body blood slowly dries: less wetting effect, less transfer
			for bone, w in pairs(src.wet) do
				w = w * 0.985
				if w < 0.005 then src.wet[bone] = nil else src.wet[bone] = w end
			end
			for tri, w in pairs(src.wetTri) do
				w = w * 0.99
				if w < 0.002 then src.wetTri[tri] = nil else src.wetTri[tri] = w end
			end
		end
	end
end

-- Impulse on a bone (ragdoll collision): blobs on that bone are shaken off.
function F.Shake(src, bone, speed, nx, ny, nz)
	Drops = Drops or ABL.Drops
	local m = src.mesh
	if not m then return end
	-- (a jolt of no size, or one that is no number, shakes nothing off)
	if not (speed > 0 and speed < 1e5 and ABL.Finite3(nx, ny, nz)) then return end
	FC.Shake(src, bone, speed, nx, ny, nz)
	FM.Shake(src, bone, speed, nx, ny, nz)
	local pose = src.pose
	for _, b in ipairs(src.blobs) do
		if not b.dead and m.tb[b.tri] == bone and b.vol > 0.015 then
			local frac = math.Clamp(speed / 600, 0.2, 0.9)
			local px, py, pz, snx, sny, snz = pose:Point(b.tri, b.u, b.v)
			local sp = speed * 0.25
			b.vx, b.vy, b.vz = -nx * sp * 0.3, -ny * sp * 0.3, -nz * sp * 0.3
			b.skip, b.stuckT = 0, 0
			Detach(b, src, b.vol * frac, px, py, pz, snx, sny, snz, 0, 0, 0, max(sp * 0.3, 4))
		end
	end
end

------------------------------------------------------------------------------------------
-- Rendering
-- What costs time here is every vertex pushed from Lua per frame, so as much as possible lives in
-- static meshes the GPU moves with the bone (cam.PushModelMatrix), and the per-frame part reuses
-- flat scratch arrays (no tables are created while drawing):
--   * settled blood: soaked streaks, static per bone,
--   * wet blood on skin that moves rigidly with one bone: static wet ribbons per bone plus a
--     static reflection mesh (its strength, Fresnel of the view angle, is set per draw),
--   * wet blood in joint regions (skin that bends between bones), segments newer than the last
--     rebuild and the tips growing behind running beads: re-skinned and drawn live every frame,
--   * beads, runnel heads, resting lenses and hanging drops: live liquid geometry.
------------------------------------------------------------------------------------------
local R = ABL.Render
local cols = C.Colors
local vec = Vector()
local boneMat = Matrix()
local Clamp = math.Clamp

local function V(x, y, z, u, v, r, g, b, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.TexCoord(0, u, v)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

local function TV(x, y, z, r, g, b, a)
	vec:SetUnpacked(x, y, z)
	mesh.Position(vec)
	mesh.Color(r, g, b, a)
	mesh.AdvanceVertex()
end

-- view and light of the character being drawn (set in F.DrawSource)
local VW = { ex = 0, ey = 0, ez = 0, ux = 0, uy = 0, uz = 1, lr = 1, lg = 1, lb = 1, sx = 0, sy = 0, sz = 1, sk = 0 }
F.VW = VW

-- Reflection of the surroundings (0..~1.5): Fresnel (n ~ 1.35) of the view angle times the sky or
-- ground it mirrors, plus a tight highlight of the key light (the sun, or the sky above).
local function Reflect(nx, ny, nz, x, y, z, gloss)
	local vx, vy, vz = VW.ex - x, VW.ey - y, VW.ez - z
	local vl = sqrt(vx * vx + vy * vy + vz * vz)
	if vl < 1e-4 then vl = 1e-4 end
	vx, vy, vz = vx / vl, vy / vl, vz / vl
	local ndv = nx * vx + ny * vy + nz * vz
	if ndv < 0 then ndv = 0 end
	local rx, ry, rz = 2 * ndv * nx - vx, 2 * ndv * ny - vy, 2 * ndv * nz - vz
	local rup = rx * VW.ux + ry * VW.uy + rz * VW.uz
	local k = 1 - ndv
	local fres = 0.022 + 0.978 * k * k * k * k * k
	local sky = rup > 0 and 0.45 + 0.9 * min(rup * 1.6, 1) or 0.15
	local rs = rx * VW.sx + ry * VW.sy + rz * VW.sz
	local spec = 0
	if rs > 0.9 then
		local q = (rs - 0.9) * 10
		q = q * q * q
		spec = VW.sk * q * q * 1.6
	end
	return gloss * (fres * sky + spec), fres
end
F.Reflect = Reflect

-- Shaded liquid (colour geometry): diffuse from the sky side, the reflection mixed in on top.
local function Shade(r, g, b, nx, ny, nz, x, y, z, gloss)
	local k = 0.5 + 0.5 * max(nx * VW.ux + ny * VW.uy + nz * VW.uz, -0.3)
	local env, fres = Reflect(nx, ny, nz, x, y, z, gloss)
	local s = env * 235
	local kd = k * (1 - fres * gloss * 0.8)
	return min(255, (r * kd + s) * VW.lr), min(255, (g * kd + s * 0.97) * VW.lg), min(255, (b * kd + s * 0.95) * VW.lb)
end

------------------------------------------------------------------------------------------
-- Streaks
------------------------------------------------------------------------------------------
-- How a segment is drawn near the camera:
--   1 soaked into the cloth (static),
--   2 wet, static: on skin that follows one bone rigidly, or on skin that bends between bones
--     while the body holds its pose (`quiet`: a corpse, someone standing still),
--   3 wet, live: on bending skin while the body moves.
-- Second result: its position has to come from the current pose (bending skin), not from the
-- bone-space position recorded when the blood ran there.
local function SegStyle(s, m, now, settle, quiet)
	local a1, a2 = s.a1, s.a2
	if not a1 or not a2 or a1[4] ~= m or a2[4] ~= m then
		-- no usable surface anchors: it lies flat as a stain
		s.settled = true
		return 1, false
	end
	if not s.settled and now - s.t > settle then s.settled = true end
	if not a1.ready then BM.PrepareAnchor(m, a1) end
	if not a2.ready then BM.PrepareAnchor(m, a2) end
	local rigid = a1.rigid == s.b and a2.rigid == s.b
	-- settled: soaked into cloth; on bare skin it stays the film it was (and dries)
	if s.settled then return s.skin and 2 or 1, not rigid end
	if rigid then return 2, false end
	if quiet then return 2, true end
	return 3, false
end

-- Pose of bone p relative to bone b (12 numbers into `out`).
local function RelPose(pose, b, p, out)
	local inv, e = pose:BoneInv(b), pose:Bone(p)
	if not inv or not e then return false end
	for r = 0, 8, 4 do
		local i1, i2, i3 = inv[r + 1], inv[r + 2], inv[r + 3]
		out[r + 1] = i1 * e[1] + i2 * e[5] + i3 * e[9]
		out[r + 2] = i1 * e[2] + i2 * e[6] + i3 * e[10]
		out[r + 3] = i1 * e[3] + i2 * e[7] + i3 * e[11]
		out[r + 4] = i1 * e[4] + i2 * e[8] + i3 * e[12] + inv[r + 4]
	end
	return true
end

-- How far the bones a bone's blood also hangs on have moved relative to it since its mesh was
-- built (0.02 ~ 1 degree, or 0.08 units). Also notes when they last moved at all (info.moveT).
local relTmp = {}
local POSE_TOL = 0.06
local function PoseDrift(pose, bone, info, rt, ft)
	local worst = 0
	local partners = info.partners
	for i = 1, #partners do
		if RelPose(pose, bone, partners[i], relTmp) then
			local bk, pv = info.rel[i], info.prev[i]
			local dB, dP = 0, 0
			for k = 1, 12 do
				local v = relTmp[k]
				local sc = (k % 4 == 0) and 0.25 or 1
				local a = abs(v - bk[k]) * sc
				if a > dB then dB = a end
				a = abs(v - pv[k]) * sc
				if a > dP then dP = a end
				pv[k] = v
			end
			-- moving: faster than ~17 degrees (or 1.2 units) per second against each other
			if dP > 0.3 * ft then info.moveT = rt end
			if dB > worst then worst = dB end
		end
	end
	return worst
end

-- Static meshes of one bone's streak segments, in that bone's local space.
--   filter mesh: soaked streaks (a wide, light halo of blood wicking into the cloth, widening over
--     the first seconds, under a narrower, denser core) and wet ribbons; drawn as a filter, so blood
--     darkens and tints what is under it (a dark wet patch on dark cloth, crimson on light cloth),
--   gloss mesh: the reflection of the wet ribbons.
-- near: wet segments on bending skin are left out while the body moves (drawn live, listed in
-- src.segDyn[bone]); far away everything is a soaked streak at a larger offset.
-- A run of segments ends in a tapered, fading tip instead of a cut.
-- EB: edges of the segments being built, 24 numbers per segment: the start edge ([1..3] halo left,
-- [4..6] halo right, [7..9] core left, [10..12] core right), then the end edge the same way.
local EB = {}
local buildSerial = 0
local TIP_W = 0.4          -- width of a run's tip relative to the streak
local function BuildBone(src, bone, lr, lg, lb, now, dryT, near, m, pose, quiet, fn)
	local old = src.segMesh[bone]
	if old then old:Destroy() src.segMesh[bone] = nil end
	local og = src.segGloss[bone]
	if og then og:Destroy() src.segGloss[bone] = nil end
	local list = src.segs[bone]
	src.segDirty[bone] = false
	src.segBuild[bone] = RealTime()
	src.segMode = src.segMode or {}
	src.segMode[bone] = near and 1 or 2
	local dyn = src.segDyn[bone]
	if dyn then
		for i = #dyn, 1, -1 do dyn[i] = nil end
	else
		dyn = {}
		src.segDyn[bone] = dyn
	end
	local info = src.segInfo[bone]
	if not info then info = { moveT = RealTime() } src.segInfo[bone] = info end
	info.period = 1e9
	info.quietBuild = quiet
	info.tipPending = false
	local partners = info.partners
	if partners then
		for i = #partners, 1, -1 do partners[i] = nil end
	else
		partners = {}
		info.partners, info.rel, info.prev = partners, {}, {}
	end
	if not list or #list == 0 then return end
	local settle = B.settleTime
	local inv = m and pose:BoneInv(bone)
	local nSoak, nWet = 0, 0
	local youngest = 1e9
	for i = 1, #list do
		local s = list[i]
		local st, bake = 1, false
		if m then st, bake = SegStyle(s, m, now, settle, quiet) end
		if not near then st = (s.skin and st ~= 1) and 2 or 1 end
		if not inv then bake = false end
		s.style, s.bake = st, bake
		if st == 1 then nSoak = nSoak + 1 elseif st == 2 then nWet = nWet + 1 else dyn[#dyn + 1] = s end
		-- the other bones this bone's blood hangs on (bending skin)
		if bake or st == 3 then
			for e = 1, 2 do
				local a = e == 1 and s.a1 or s.a2
				for k = 1, a.nb do
					local pb = (k == 1 and a.b1) or (k == 2 and a.b2) or a.b3
					if pb ~= bone and pb >= 0 then
						local found = false
						for j = 1, #partners do
							if partners[j] == pb then found = true break end
						end
						if not found and #partners < 6 then partners[#partners + 1] = pb end
					end
				end
			end
		end
		local age = now - s.t
		if age < youngest then youngest = age end
	end
	for i = 1, #partners do
		local rel = info.rel[i]
		if not rel then rel = {} info.rel[i] = rel info.prev[i] = {} end
		if RelPose(pose, bone, partners[i], rel) then
			local pv = info.prev[i]
			for k = 1, 12 do pv[k] = rel[k] end
		else
			for k = 1, 12 do rel[k] = 0 info.prev[i][k] = 0 end
		end
	end
	-- when it next needs rebuilding for its own sake: settling and wicking in the first seconds,
	-- ageing colours while it dries, never once it is dry
	info.period = (youngest < 20 and 2) or (youngest < dryT and 10) or 1e9
	if nSoak + nWet == 0 then return end
	buildSerial = buildSerial + 1
	local serial = buildSerial
	local tone = src.tone or 1
	local off = near and B.stainOffset or B.offset
	local ho = -0.03
	local mm = Mesh()
	mesh.Begin(mm, MATERIAL_QUADS, nSoak * 2 + nWet)
	local vacc = 0
	local o = 0
	local gnx, gny, gnz, gcx, gcy, gcz, glen = 0, 0, 0, 0, 0, 0, 0
	for i = 1, #list do
		local s = list[i]
		local st = s.style
		if st ~= 3 then
			local a1, a2 = s.a1, s.a2
			local x1, y1, z1, x2, y2, z2, nx, ny, nz
			if s.bake then
				-- on bending skin: where it is in this pose, expressed in the bone's space
				local wx1, wy1, wz1, n1x, n1y, n1z = pose:SkinPoint(a1)
				local wx2, wy2, wz2, n2x, n2y, n2z = pose:SkinPoint(a2)
				x1 = inv[1] * wx1 + inv[2] * wy1 + inv[3] * wz1 + inv[4]
				y1 = inv[5] * wx1 + inv[6] * wy1 + inv[7] * wz1 + inv[8]
				z1 = inv[9] * wx1 + inv[10] * wy1 + inv[11] * wz1 + inv[12]
				x2 = inv[1] * wx2 + inv[2] * wy2 + inv[3] * wz2 + inv[4]
				y2 = inv[5] * wx2 + inv[6] * wy2 + inv[7] * wz2 + inv[8]
				z2 = inv[9] * wx2 + inv[10] * wy2 + inv[11] * wz2 + inv[12]
				local mx, my, mz = n1x + n2x, n1y + n2y, n1z + n2z
				nx, ny, nz = ABL.Norm(inv[1] * mx + inv[2] * my + inv[3] * mz, inv[5] * mx + inv[6] * my + inv[7] * mz, inv[9] * mx + inv[10] * my + inv[11] * mz)
			else
				x1, y1, z1, x2, y2, z2, nx, ny, nz = s.x1, s.y1, s.z1, s.x2, s.y2, s.z2, s.nx, s.ny, s.nz
			end
			-- (blood baked onto bending skin sits a little higher: the skin may shift under it by the pose tolerance)
			local so = st == 2 and off + (s.bake and 0.05 or 0.02) or off
			x1, y1, z1 = x1 + nx * so, y1 + ny * so, z1 + nz * so
			x2, y2, z2 = x2 + nx * so, y2 + ny * so, z2 + nz * so
			local sx, sy, sz = x2 - x1, y2 - y1, z2 - z1
			local slen = sqrt(sx * sx + sy * sy + sz * sz)
			local wx, wy, wz = sy * nz - sz * ny, sz * nx - sx * nz, sx * ny - sy * nx
			local wl = sqrt(wx * wx + wy * wy + wz * wz)
			if wl < 1e-6 then wx, wy, wz, wl = 1, 0, 0, 1 end
			local age = now - s.t
			local dk = Clamp(age / dryT, 0, 1)
			local mr, mg, mb = R.FilterAge(dk, 0.5)
			mr = mr * tone
			local v1 = a1 and a1.tv or vacc
			local v2 = a2 and a2.tv or (vacc + slen / 6)
			-- the ends of a run: a tapered tip that fades out (no tip where a bead is still running on)
			local f1 = (a1 and not a1.pa) and 0 or 1
			local f2 = 1
			if a2 and not a2.na then
				if fn - (a2.tipF or -9) <= 2 then info.tipPending = true else f2 = 0 end
			end
			local t1, t2 = f1 == 0 and TIP_W or 1, f2 == 0 and TIP_W or 1
			-- halo (slightly below the core so the core wins in depth); cloth wicks the blood sideways
			local wick = 1.25 + 0.6 * Clamp(age / 12, 0, 1)
			local hh1, hh2 = s.w1 * wick * t1 / wl, s.w2 * wick * t2 / wl
			local h1, h2 = s.w1 * 0.5 * t1 / wl, s.w2 * 0.5 * t2 / wl
			-- start edge: where the previous segment of this run ended (one continuous ribbon instead
			-- of a row of overlapping rectangles), or this segment's own
			if a1 and a1.eid == serial then
				local p = a1.eo
				for k = 1, 12 do EB[o + k] = EB[p + k] end
			else
				EB[o + 1], EB[o + 2], EB[o + 3] = x1 - wx * hh1 + nx * ho, y1 - wy * hh1 + ny * ho, z1 - wz * hh1 + nz * ho
				EB[o + 4], EB[o + 5], EB[o + 6] = x1 + wx * hh1 + nx * ho, y1 + wy * hh1 + ny * ho, z1 + wz * hh1 + nz * ho
				EB[o + 7], EB[o + 8], EB[o + 9] = x1 - wx * h1, y1 - wy * h1, z1 - wz * h1
				EB[o + 10], EB[o + 11], EB[o + 12] = x1 + wx * h1, y1 + wy * h1, z1 + wz * h1
			end
			EB[o + 13], EB[o + 14], EB[o + 15] = x2 - wx * hh2 + nx * ho, y2 - wy * hh2 + ny * ho, z2 - wz * hh2 + nz * ho
			EB[o + 16], EB[o + 17], EB[o + 18] = x2 + wx * hh2 + nx * ho, y2 + wy * hh2 + ny * ho, z2 + wz * hh2 + nz * ho
			EB[o + 19], EB[o + 20], EB[o + 21] = x2 - wx * h2, y2 - wy * h2, z2 - wz * h2
			EB[o + 22], EB[o + 23], EB[o + 24] = x2 + wx * h2, y2 + wy * h2, z2 + wz * h2
			if a2 then a2.eid, a2.eo = serial, o + 12 end
			if st == 1 then
				-- halo: diluted blood wicked into the fabric around the streak
				local hr, hg, hb, ha = R.FilterColor(mr, mg * 1.05, mb, 0.4)
				V(EB[o + 1], EB[o + 2], EB[o + 3], 0, v1, hr * f1, hg * f1, hb * f1, ha * f1)
				V(EB[o + 4], EB[o + 5], EB[o + 6], 1, v1, hr * f1, hg * f1, hb * f1, ha * f1)
				V(EB[o + 16], EB[o + 17], EB[o + 18], 1, v2, hr * f2, hg * f2, hb * f2, ha * f2)
				V(EB[o + 13], EB[o + 14], EB[o + 15], 0, v2, hr * f2, hg * f2, hb * f2, ha * f2)
				-- core: dense while fresh, thins out as it soaks in / dries
				local cr, cg, cb, ca = R.FilterColor(mr, mg, mb, (s.a or 210) / 255 * (1 - 0.35 * dk))
				V(EB[o + 7], EB[o + 8], EB[o + 9], 0, v1, cr * f1, cg * f1, cb * f1, ca * f1)
				V(EB[o + 10], EB[o + 11], EB[o + 12], 1, v1, cr * f1, cg * f1, cb * f1, ca * f1)
				V(EB[o + 22], EB[o + 23], EB[o + 24], 1, v2, cr * f2, cg * f2, cb * f2, ca * f2)
				V(EB[o + 19], EB[o + 20], EB[o + 21], 0, v2, cr * f2, cg * f2, cb * f2, ca * f2)
			else
				-- wet ribbon: the liquid itself, its translucent thin edges from the film texture
				local cr, cg, cb, ca = R.FilterColor(mr, mg, mb, 0.95 * (1 - 0.3 * dk))
				V(EB[o + 7], EB[o + 8], EB[o + 9], 0.08, v1, cr * f1, cg * f1, cb * f1, ca * f1)
				V(EB[o + 10], EB[o + 11], EB[o + 12], 0.92, v1, cr * f1, cg * f1, cb * f1, ca * f1)
				V(EB[o + 22], EB[o + 23], EB[o + 24], 0.92, v2, cr * f2, cg * f2, cb * f2, ca * f2)
				V(EB[o + 19], EB[o + 20], EB[o + 21], 0.08, v2, cr * f2, cg * f2, cb * f2, ca * f2)
				s.gw, s.eo, s.f1, s.f2 = 1 - dk, o, f1, f2
				gnx, gny, gnz = gnx + nx * slen, gny + ny * slen, gnz + nz * slen
				gcx, gcy, gcz = gcx + (x1 + x2) * 0.5, gcy + (y1 + y2) * 0.5, gcz + (z1 + z2) * 0.5
				glen = glen + slen
			end
			vacc = v2 % 1
			o = o + 24
		end
	end
	mesh.End()
	src.segMesh[bone] = mm
	if nWet > 0 then
		-- reflection of the wet ribbons: wetness and light per vertex, the view-dependent strength
		-- per draw (from the mean normal of this bone's wet blood)
		local gm = Mesh()
		mesh.Begin(gm, MATERIAL_QUADS, nWet)
		for i = 1, #list do
			local s = list[i]
			if s.style == 2 then
				local p = s.eo
				local w = s.gw * 255
				local r, g, b = min(255, w * lr), min(255, w * lg), min(255, w * lb)
				local f1, f2 = s.f1, s.f2
				local v1, v2 = s.a1.tv or 0, s.a2.tv or 0
				V(EB[p + 7], EB[p + 8], EB[p + 9], 0.08, v1, r * f1, g * f1, b * f1, 215)
				V(EB[p + 10], EB[p + 11], EB[p + 12], 0.92, v1, r * f1, g * f1, b * f1, 215)
				V(EB[p + 22], EB[p + 23], EB[p + 24], 0.92, v2, r * f2, g * f2, b * f2, 215)
				V(EB[p + 19], EB[p + 20], EB[p + 21], 0.08, v2, r * f2, g * f2, b * f2, 215)
			end
		end
		mesh.End()
		src.segGloss[bone] = gm
		info.nx, info.ny, info.nz = ABL.Norm(gnx, gny, gnz)
		info.cx, info.cy, info.cz = gcx / nWet, gcy / nWet, gcz / nWet
		info.spread = Clamp(sqrt(gnx * gnx + gny * gny + gnz * gnz) / max(glen, 1e-3), 0, 1)
	end
end

-- Where to draw a bead: between its last two simulated positions (both in this frame's pose), so it
-- moves smoothly whatever its step rate. Returns world x, y, z and the surface normal.
function F.BeadPoint(pose, b, m)
	local px, py, pz, nx, ny, nz = pose:Point(b.tri, b.u, b.v)
	local a = ABL.Sim.Alpha(b.lt, b.sd)
	local pt = b.ptri
	if a < 1 and pt and m and pt <= m.nt and (pt ~= b.tri or b.pu ~= b.u or b.pv ~= b.v) then
		local qx, qy, qz = pose:Point(pt, b.pu, b.pv)
		px, py, pz = qx + (px - qx) * a, qy + (py - qy) * a, qz + (pz - qz) * a
	end
	return px, py, pz, nx, ny, nz
end

-- A trail point this frame: its position lifted off the skin, the side vector across the rivulet,
-- the reflection it shows and whether it faces the camera at all. Computed once per frame per point
-- and shared by the segments meeting there, so a rivulet has no steps or gaps however its segments
-- are ordered. The run direction comes from the neighbouring trail points (tx, ty, tz: the point
-- ahead when the trail ends here and a bead is still running on).
local edgeN = 0
local function AnchorEdge(pose, a, m, fn, off, gloss, tx, ty, tz)
	if a.sf == fn then return end
	a.sf = fn
	edgeN = edgeN + 1
	local x, y, z, nx, ny, nz = pose:SkinPoint(a)
	local p, n = a.pa, a.na
	local x1, y1, z1, x2, y2, z2 = x, y, z, x, y, z
	if p and p[4] == m then x1, y1, z1 = pose:SkinPoint(p) end
	if n and n[4] == m then x2, y2, z2 = pose:SkinPoint(n) elseif tx then x2, y2, z2 = tx, ty, tz end
	local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
	local wx, wy, wz = dy * nz - dz * ny, dz * nx - dx * nz, dx * ny - dy * nx
	local wl = sqrt(wx * wx + wy * wy + wz * wz)
	if wl < 1e-6 then
		wx, wy, wz = ABL.Perp(nx, ny, nz)
	else
		wx, wy, wz = wx / wl, wy / wl, wz / wl
	end
	a.sx, a.sy, a.sz = wx, wy, wz
	a.ox, a.oy, a.oz = x + nx * off, y + ny * off, z + nz * off
	-- skin turned away from the camera is hidden by its own body part
	local vx, vy, vz = VW.ex - x, VW.ey - y, VW.ez - z
	a.vis = nx * vx + ny * vy + nz * vz > -0.25 * (abs(vx) + abs(vy) + abs(vz))
	-- (a rivulet on cloth is not a mirror: its reflection is kept modest)
	a.gl = gloss and Reflect(nx, ny, nz, x, y, z, 1) * 0.4 or 0
end

-- Quads of the live strips, 22 numbers each: corners left 1, right 1, right 2, left 2 ([1..12]),
-- texture v at both ends ([13], [14]), the filter colour ([15..18]), the reflection at both ends
-- ([19], [20]) and how much of each end shows ([21], [22]: 0 at a run's fading tip).
local LQ = {}
local LQS = 22

-- Filter colour of a wet segment (ageing is slow: refreshed once a second).
local function SegColour(s, now, dryT, tone)
	if now > (s.fT or 0) then
		local dk = Clamp((now - s.t) / dryT, 0, 1)
		local mr, mg, mb = R.FilterAge(dk, 0.5)
		s.fr, s.fg, s.fb, s.fa = R.FilterColor(mr * tone, mg, mb, 0.95 * (1 - 0.3 * dk))
		s.fw = 1 - dk
		s.fT = now + 1
	end
end

-- Live strips: wet segments on bending skin of a moving body, segments not yet in their bone's
-- static mesh, and the tip from each running bead's last trail point to the bead itself (so a
-- rivulet grows continuously). Pass 1 draws the blood as a film over the cloth / skin (dark on dark
-- cloth, crimson on light cloth and skin: the real surface under it, lit as it is), pass 2 its wet
-- reflection.
local WHITE = Vector(1, 1, 1)
local function DrawLiveStrips(src, pose, m, now, dryT, off, gloss, fn)
	local tone = src.tone or 1
	local nq, o = 0, 0
	-- tips behind running beads first: they give the trail's last point its direction
	local blobs = src.blobs
	local tr, tg, tb, ta
	for i = 1, #blobs do
		local b = blobs[i]
		local t = b.trail
		local an = not b.dead and b.moving and t and t.anchor
		if an and an[4] == m then
			local bx, by, bz, bnx, bny, bnz = F.BeadPoint(pose, b, m)
			AnchorEdge(pose, an, m, fn, off, gloss, bx, by, bz)
			an.tipF = fn
			local ax, ay, az = an.ox, an.oy, an.oz
			bx, by, bz = bx + bnx * off, by + bny * off, bz + bnz * off
			local dx, dy, dz = bx - ax, by - ay, bz - az
			local dd = sqrt(dx * dx + dy * dy + dz * dz)
			if dd > 0.02 and an.vis then
				if not tr then
					local Ff = C.Filter.fresh
					tr, tg, tb, ta = R.FilterColor(Ff[1] * tone, Ff[2], Ff[3], 0.95)
				end
				local wx, wy, wz = dy * bnz - dz * bny, dz * bnx - dx * bnz, dx * bny - dy * bnx
				local wl = sqrt(wx * wx + wy * wy + wz * wz)
				if wl < 1e-6 then wx, wy, wz, wl = an.sx, an.sy, an.sz, 1 end
				local h1 = (t.w or 0.3) * 0.5
				local h2 = (0.2 + 0.42 * (max(b.vol, 0) ^ 0.3333)) * 0.5 / wl
				local sx, sy, sz = an.sx * h1, an.sy * h1, an.sz * h1
				LQ[o + 1], LQ[o + 2], LQ[o + 3] = ax - sx, ay - sy, az - sz
				LQ[o + 4], LQ[o + 5], LQ[o + 6] = ax + sx, ay + sy, az + sz
				LQ[o + 7], LQ[o + 8], LQ[o + 9] = bx + wx * h2, by + wy * h2, bz + wz * h2
				LQ[o + 10], LQ[o + 11], LQ[o + 12] = bx - wx * h2, by - wy * h2, bz - wz * h2
				local tv = an.tv or 0
				LQ[o + 13], LQ[o + 14] = tv, tv + dd / 6
				LQ[o + 15], LQ[o + 16], LQ[o + 17], LQ[o + 18] = tr, tg, tb, ta
				LQ[o + 19] = min(an.gl, 0.28) * 255
				LQ[o + 20] = gloss and min(Reflect(bnx, bny, bnz, bx, by, bz, 1) * 0.4, 0.28) * 255 or 0
				-- a trail that starts right here begins with a fading tip
				LQ[o + 21], LQ[o + 22] = an.pa and 1 or 0, 1
				nq, o = nq + 1, o + LQS
			end
		end
	end
	for _, dyn in pairs(src.segDyn) do
		for i = 1, #dyn do
			local s = dyn[i]
			local a1, a2 = s.a1, s.a2
			if not s.gone and a1 and a2 and a1[4] == m and a2[4] == m then
				AnchorEdge(pose, a1, m, fn, off, gloss)
				AnchorEdge(pose, a2, m, fn, off, gloss)
				if a1.vis or a2.vis then
					SegColour(s, now, dryT, tone)
					-- the ends of a run: a tapered tip that fades out (not where a bead is running on)
					local f1 = a1.pa and 1 or 0
					local f2 = (a2.na or a2.tipF == fn) and 1 or 0
					local h1, h2 = s.w1 * (f1 == 0 and TIP_W or 1) * 0.5, s.w2 * (f2 == 0 and TIP_W or 1) * 0.5
					local x1, y1, z1, x2, y2, z2 = a1.ox, a1.oy, a1.oz, a2.ox, a2.oy, a2.oz
					local sx, sy, sz = a1.sx * h1, a1.sy * h1, a1.sz * h1
					local ex, ey, ez = a2.sx * h2, a2.sy * h2, a2.sz * h2
					LQ[o + 1], LQ[o + 2], LQ[o + 3] = x1 - sx, y1 - sy, z1 - sz
					LQ[o + 4], LQ[o + 5], LQ[o + 6] = x1 + sx, y1 + sy, z1 + sz
					LQ[o + 7], LQ[o + 8], LQ[o + 9] = x2 + ex, y2 + ey, z2 + ez
					LQ[o + 10], LQ[o + 11], LQ[o + 12] = x2 - ex, y2 - ey, z2 - ez
					LQ[o + 13], LQ[o + 14] = a1.tv or 0, a2.tv or 0
					LQ[o + 15], LQ[o + 16], LQ[o + 17], LQ[o + 18] = s.fr, s.fg, s.fb, s.fa
					local fw = s.fw
					LQ[o + 19], LQ[o + 20] = min(a1.gl * fw, 0.28) * 255, min(a2.gl * fw, 0.28) * 255
					LQ[o + 21], LQ[o + 22] = f1, f2
					nq, o = nq + 1, o + LQS
				end
			end
		end
	end
	if nq == 0 then return 0 end
	render.SetMaterial(ABL.Mat.filmFilter)
	R.BeginFilter()
	mesh.Begin(MATERIAL_QUADS, nq)
	for q = 0, (nq - 1) * LQS, LQS do
		local v1, v2, r, g, b, a = LQ[q + 13], LQ[q + 14], LQ[q + 15], LQ[q + 16], LQ[q + 17], LQ[q + 18]
		local f1, f2 = LQ[q + 21], LQ[q + 22]
		V(LQ[q + 1], LQ[q + 2], LQ[q + 3], 0.08, v1, r * f1, g * f1, b * f1, a * f1)
		V(LQ[q + 4], LQ[q + 5], LQ[q + 6], 0.92, v1, r * f1, g * f1, b * f1, a * f1)
		V(LQ[q + 7], LQ[q + 8], LQ[q + 9], 0.92, v2, r * f2, g * f2, b * f2, a * f2)
		V(LQ[q + 10], LQ[q + 11], LQ[q + 12], 0.08, v2, r * f2, g * f2, b * f2, a * f2)
	end
	mesh.End()
	R.EndFilter()
	if gloss then
		local lr, lg, lb = VW.lr, VW.lg, VW.lb
		local gm = ABL.Mat.bodyGloss
		gm:SetVector("$color", WHITE)
		render.SetMaterial(gm)
		mesh.Begin(MATERIAL_QUADS, nq)
		for q = 0, (nq - 1) * LQS, LQS do
			local v1, v2 = LQ[q + 13], LQ[q + 14]
			local e1, e2 = LQ[q + 19] * LQ[q + 21], LQ[q + 20] * LQ[q + 22]
			local r1, g1, b1 = min(255, e1 * lr), min(255, e1 * lg), min(255, e1 * lb)
			local r2, g2, b2 = min(255, e2 * lr), min(255, e2 * lg), min(255, e2 * lb)
			V(LQ[q + 1], LQ[q + 2], LQ[q + 3], 0.08, v1, r1, g1, b1, 215)
			V(LQ[q + 4], LQ[q + 5], LQ[q + 6], 0.92, v1, r1, g1, b1, 215)
			V(LQ[q + 7], LQ[q + 8], LQ[q + 9], 0.92, v2, r2, g2, b2, 215)
			V(LQ[q + 10], LQ[q + 11], LQ[q + 12], 0.08, v2, r2, g2, b2, 215)
		end
		mesh.End()
	end
	return nq
end

------------------------------------------------------------------------------------------
-- Beads: liquid volume on the skin
------------------------------------------------------------------------------------------
local DOME_N = 6
local cosT, sinT = {}, {}
for i = 0, DOME_N do cosT[i] = math.cos(i / DOME_N * 6.2831853) sinT[i] = math.sin(i / DOME_N * 6.2831853) end

-- Drop shapes from the ground stain atlas give lenses and runnel heads an organic, soft outline
-- (the texture's coverage shapes the edge, its thickness the depth) instead of a polygon.
-- DROP_FRAC: radius of the drop shape in a cell, in half-cell units.
local DROP_FRAC = 0.53
local function DropCell(i)
	local c = 8 + i % 8
	local cx, cy = c % 8, math.floor(c / 8)
	local mu, mv = 6 / 2048, 6 / 1024
	local u0, v0, u1, v1 = cx / 8 + mu, cy / 4 + mv, (cx + 1) / 8 - mu, (cy + 1) / 4 - mv
	return (u0 + u1) * 0.5, (v0 + v1) * 0.5, (u1 - u0) * 0.5, (v1 - v0) * 0.5
end

-- scratch: ring of a dome, rings of a pendant, the beads being drawn
local DS = {
	x = {}, y = {}, z = {}, u = {}, v = {}, g = {},
	px = {}, py = {}, pz = {}, pr = {}, pg = {}, pb = {},
	b = {}, bx = {}, by = {}, bz = {}, bnx = {}, bny = {}, bnz = {}, hang = {},
	hb = {}, hs = {}, flat = {},
}

-- Low dome on the surface at p (normal n), axis f (unit, in plane) with visible radii ra (along f,
-- the front half stretched by `front`) and rb, height h, textured with drop shape `cell`. Written
-- into the open MATERIAL_TRIANGLES mesh: a fan of DOME_N triangles, or 2 (a quad) when `flat` (far
-- enough that its relief cannot be seen). pass 1: the film (one colour); pass 2: its reflection,
-- per vertex over the dome, so the highlight shows the volume.
-- (the reflection is capped low: a bead's facets are few, and a bright one reads as a white
-- triangle, not as a highlight)
local BEAD_GLOSS = 0.16
local function Dome(pass, flat, px, py, pz, nx, ny, nz, fx, fy, fz, ra, rb, h, front, r, g, b, a, gloss, cell)
	local qx, qy, qz = ny * fz - nz * fy, nz * fx - nx * fz, nx * fy - ny * fx
	local cu, cv, hu, hv = DropCell(cell or 0)
	-- geometry spans the whole cell; the drop's outline is DROP_FRAC of it
	ra, rb = ra / DROP_FRAC, rb / DROP_FRAC
	local lr, lg, lb = VW.lr, VW.lg, VW.lb
	if flat then
		if pass == 2 then
			local e = min(Reflect(nx, ny, nz, px, py, pz, gloss), BEAD_GLOSS) * 255
			r, g, b = min(255, e * lr), min(255, e * lg), min(255, e * lb)
		end
		local fa, fb = ra * front, ra
		local x1, y1, z1 = px - fx * fb - qx * rb, py - fy * fb - qy * rb, pz - fz * fb - qz * rb
		local x2, y2, z2 = px + fx * fa - qx * rb, py + fy * fa - qy * rb, pz + fz * fa - qz * rb
		local x3, y3, z3 = px + fx * fa + qx * rb, py + fy * fa + qy * rb, pz + fz * fa + qz * rb
		local x4, y4, z4 = px - fx * fb + qx * rb, py - fy * fb + qy * rb, pz - fz * fb + qz * rb
		V(x1, y1, z1, cu - hu, cv - hv, r, g, b, a) V(x2, y2, z2, cu + hu, cv - hv, r, g, b, a) V(x3, y3, z3, cu + hu, cv + hv, r, g, b, a)
		V(x1, y1, z1, cu - hu, cv - hv, r, g, b, a) V(x3, y3, z3, cu + hu, cv + hv, r, g, b, a) V(x4, y4, z4, cu - hu, cv + hv, r, g, b, a)
		return
	end
	local X, Y, Z, U, Vv, G = DS.x, DS.y, DS.z, DS.u, DS.v, DS.g
	for i = 0, DOME_N do
		local c, s = cosT[i], sinT[i]
		local rr = (c > 0) and ra * front or ra
		local x, y, z = px + fx * c * rr + qx * s * rb, py + fy * c * rr + qy * s * rb, pz + fz * c * rr + qz * s * rb
		X[i], Y[i], Z[i] = x, y, z
		U[i], Vv[i] = cu + c * hu, cv + s * hv
		if pass == 2 then
			-- the rim of the fan lies outside the visible drop: shaded like the drop's flank
			local inx, iny, inz = ABL.Norm(nx + (fx * c + qx * s) * 0.55, ny + (fy * c + qy * s) * 0.55, nz + (fz * c + qz * s) * 0.55)
			G[i] = min(Reflect(inx, iny, inz, x, y, z, gloss), BEAD_GLOSS) * 255
		end
	end
	local tx, ty, tz = px + nx * h, py + ny * h, pz + nz * h
	if pass == 1 then
		for i = 0, DOME_N - 1 do
			local j = i + 1
			V(X[i], Y[i], Z[i], U[i], Vv[i], r, g, b, a)
			V(X[j], Y[j], Z[j], U[j], Vv[j], r, g, b, a)
			V(tx, ty, tz, cu, cv, r, g, b, a)
		end
	else
		local e = min(Reflect(nx, ny, nz, tx, ty, tz, gloss), BEAD_GLOSS) * 255
		local tr, tg, tb = min(255, e * lr), min(255, e * lg), min(255, e * lb)
		for i = 0, DOME_N - 1 do
			local j = i + 1
			local e1, e2 = G[i], G[j]
			V(X[i], Y[i], Z[i], U[i], Vv[i], min(255, e1 * lr), min(255, e1 * lg), min(255, e1 * lb), a)
			V(X[j], Y[j], Z[j], U[j], Vv[j], min(255, e2 * lr), min(255, e2 * lg), min(255, e2 * lb), a)
			V(tx, ty, tz, cu, cv, tr, tg, tb, a)
		end
	end
end

-- Teardrop hanging from p along gravity d: a neck on the skin swelling into a bulb.
-- Profile rings (distance along d, radius), the tip as a last ring of radius 0. Written into the
-- open triangle strip: band after band (a closed band ends where the next begins), `join` repeats
-- the first vertex so this drop connects to the one before it in the strip.
local PEND = { { 0, 0.5 }, { 0.32, 0.45 }, { 0.7, 0.95 }, { 1.0, 0.45 }, { 1.12, 0 } }
local NPEND = #PEND
local PSTR = DOME_N + 1
local PEND_VERTS = (NPEND - 1) * PSTR * 2
-- gl: how strongly it mirrors its surroundings (1.2 when not given)
local function Pendant(px, py, pz, dx, dy, dz, rad, len, r, g, b, a, join, more, gl)
	gl = gl or 1.2
	local sx, sy, sz = ABL.Perp(dx, dy, dz)
	local qx, qy, qz = dy * sz - dz * sy, dz * sx - dx * sz, dx * sy - dy * sx
	local X, Y, Z, CR, CG, CB = DS.px, DS.py, DS.pz, DS.pr, DS.pg, DS.pb
	for k = 1, NPEND do
		local pk = PEND[k]
		-- the neck starts on the skin: ring 1 is centred on the surface point
		local t = k < NPEND and pk[1] * len or len + rad * 0.12
		local rr = pk[2] * rad
		local cx, cy, cz = px + dx * t, py + dy * t, pz + dz * t
		local base = (k - 1) * PSTR
		if rr > 0 then
			local slope = (PEND[k + 1][2] - pk[2]) * rad / max((PEND[k + 1][1] - pk[1]) * len, 1e-3)
			for i = 0, DOME_N - 1 do
				local c, s = cosT[i], sinT[i]
				local ox, oy, oz = sx * c + qx * s, sy * c + qy * s, sz * c + qz * s
				local wnx, wny, wnz = ABL.Norm(ox - dx * slope, oy - dy * slope, oz - dz * slope)
				local vx, vy, vz = cx + ox * rr, cy + oy * rr, cz + oz * rr
				local id = base + i
				X[id], Y[id], Z[id] = vx, vy, vz
				CR[id], CG[id], CB[id] = Shade(r, g, b, wnx, wny, wnz, vx, vy, vz, gl)
			end
		else
			local tr, tg, tb = Shade(r, g, b, dx, dy, dz, cx, cy, cz, gl)
			for i = 0, DOME_N - 1 do
				local id = base + i
				X[id], Y[id], Z[id], CR[id], CG[id], CB[id] = cx, cy, cz, tr, tg, tb
			end
		end
		local i0, i1 = base, base + DOME_N
		X[i1], Y[i1], Z[i1], CR[i1], CG[i1], CB[i1] = X[i0], Y[i0], Z[i0], CR[i0], CG[i0], CB[i0]
	end
	if join then TV(X[PSTR], Y[PSTR], Z[PSTR], CR[PSTR], CG[PSTR], CB[PSTR], a) end
	for k = 1, NPEND - 1 do
		local b1, b2 = (k - 1) * PSTR, k * PSTR
		for i = 0, DOME_N do
			local p, q = b2 + i, b1 + i
			TV(X[p], Y[p], Z[p], CR[p], CG[p], CB[p], a)
			TV(X[q], Y[q], Z[q], CR[q], CG[q], CB[q], a)
		end
	end
	if more then
		local id = (NPEND - 2) * PSTR + DOME_N
		TV(X[id], Y[id], Z[id], CR[id], CG[id], CB[id], a)
	end
end
F.Pendant, F.PEND_VERTS = Pendant, PEND_VERTS

local function DrawBeads(src, pose, off, gloss)
	local blobs = src.blobs
	local nb = #blobs
	if nb == 0 then return end
	local m = src.mesh
	local gx, gy, gz, gmag = ABL.Gravity()
	local gdx, gdy, gdz = gx / gmag, gy / gmag, gz / gmag
	-- 3D hanging drops are the costly shape: the fullest few hang in 3D, the rest are beads
	local maxPend = src.dist < 250 and 4 or 2
	local HB, HS = DS.hb, DS.hs
	for k = 1, 4 do HB[k], HS[k] = nil, 0 end
	for i = 1, nb do
		local b = blobs[i]
		if not b.dead and b.tri and b.vol > 0.008 and b.hangK > 0.25 then
			local sc = b.hangK * b.vol
			-- insert into the top list
			local k = maxPend
			if sc > HS[k] then
				while k > 1 and sc > HS[k - 1] do HB[k], HS[k] = HB[k - 1], HS[k - 1] k = k - 1 end
				HB[k], HS[k] = b, sc
			end
		end
	end
	local BB, BX, BY, BZ, BNX, BNY, BNZ, HG, FL = DS.b, DS.bx, DS.by, DS.bz, DS.bnx, DS.bny, DS.bnz, DS.hang, DS.flat
	local n, nDome, nFlat, nPend = 0, 0, 0, 0
	local far = src.dist >= 300
	local ex, ey, ez = VW.ex, VW.ey, VW.ez
	-- beyond this distance a dome's relief (a few hundredths of a unit) is below a pixel
	local flat2 = B.domeDist * B.domeDist
	for i = 1, nb do
		local b = blobs[i]
		if not b.dead and b.tri and b.vol > 0.008 then
			local hang = b == HB[1] or b == HB[2] or b == HB[3] or b == HB[4]
			-- far away small resting beads are not worth drawing as geometry
			if not far or b.vol > 0.1 or b.moving or hang then
				local px, py, pz, nx, ny, nz = F.BeadPoint(pose, b, m)
				local vx, vy, vz = ex - px, ey - py, ez - pz
				-- a bead on skin turned away from the camera is hidden by its own body part (a hanging
				-- drop sticks out and shows from the side)
				if hang or nx * vx + ny * vy + nz * vz > -0.25 * (abs(vx) + abs(vy) + abs(vz)) then
					n = n + 1
					BB[n], HG[n] = b, hang
					BX[n], BY[n], BZ[n], BNX[n], BNY[n], BNZ[n] = px + nx * off, py + ny * off, pz + nz * off, nx, ny, nz
					if hang then
						nPend = nPend + 1
					else
						local fl = vx * vx + vy * vy + vz * vz > flat2
						FL[n] = fl
						if fl then nFlat = nFlat + 1 else nDome = nDome + 1 end
					end
				end
			end
		end
	end
	if n == 0 then return end
	ABL.Prof.Count("beads", nDome + nFlat) ABL.Prof.Count("hanging drops", nPend)
	local tone = src.tone or 1
	-- liquid on the surface: runnel heads and resting lenses, outlined by drop shapes. Pass 1: the
	-- blood as a film over the cloth / skin (the drop outline from the filter atlas); pass 2: its
	-- wet reflection.
	if nDome + nFlat > 0 then
		local Ff = C.Filter.fresh
		local hr, hg, hb, ha = R.FilterColor(Ff[1] * tone, Ff[2], Ff[3], 0.97)
		for pass = 1, gloss and 2 or 1 do
			render.SetMaterial(pass == 1 and ABL.Mat.groundFilter or ABL.Mat.groundGloss)
			if pass == 1 then R.BeginFilter() else R.EndFilter() end
			mesh.Begin(MATERIAL_TRIANGLES, nDome * DOME_N + nFlat * 2)
			for i = 1, n do
				if not HG[i] then
					local b = BB[i]
					local flat = FL[i]
					local px, py, pz, nx, ny, nz = BX[i], BY[i], BZ[i], BNX[i], BNY[i], BNZ[i]
					local cell = math.floor(b.rot * 1.2732) -- a fixed drop shape per bead (b.rot in 0..2pi)
					if b.moving or b.tethered then
						-- runnel head: a small elongated bead, bulging at its front
						local sp = sqrt(b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
						local fx, fy, fz
						if sp > 0.05 then fx, fy, fz = b.vx / sp, b.vy / sp, b.vz / sp else fx, fy, fz = ABL.Perp(nx, ny, nz) end
						local rad = 0.1 + 0.26 * (min(b.vol, 0.6) ^ 0.3333)
						local stretch = 1 + min(sp * 0.25, 0.9)
						Dome(pass, flat, px, py, pz, nx, ny, nz, fx, fy, fz, rad * stretch * 0.8, rad * 0.8, rad * 0.55, 1.2, hr, hg, hb, pass == 1 and ha or 240, 1, cell)
					else
						-- resting lens: a thin layer of blood lying in the cloth (the soaked stain itself is
						-- the skinned engine decal under it), fading and flattening as it soaks in
						-- (capped: a flat lens wider than this would lift off a curved limb at its rim)
						local pr = min(PuddleRadius(b.vol) * 1.15 + 0.15, 0.6)
						local ca, sa = math.cos(b.rot), math.sin(b.rot)
						local sx, sy, sz = ABL.Perp(nx, ny, nz)
						local qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
						local fx, fy, fz = sx * ca + qx * sa, sy * ca + qy * sa, sz * ca + qz * sa
						local h = pr * 0.12 * Clamp(b.vol / 0.1, 0.2, 1)
						local k = Clamp(b.vol / 0.12, 0.3, 1)
						if pass == 1 then
							local cr, cg, cb, cal = R.FilterColor(Ff[1] * tone, Ff[2], Ff[3], 0.9 * k)
							Dome(1, flat, px, py, pz, nx, ny, nz, fx, fy, fz, pr, pr * 0.85, h, 1, cr, cg, cb, cal, 0.7, cell)
						else
							Dome(2, flat, px, py, pz, nx, ny, nz, fx, fy, fz, pr, pr * 0.85, h, 1, 0, 0, 0, k * 220, 0.7, cell)
						end
					end
				end
			end
			mesh.End()
		end
		R.EndFilter()
	end
	-- hanging drops: 3D teardrops along world gravity, all in one triangle strip
	if nPend > 0 then
		local fresh = cols.fresh
		local r, g, b0 = fresh[1] * tone, fresh[2], fresh[3]
		render.SetColorMaterial()
		mesh.Begin(MATERIAL_TRIANGLE_STRIP, nPend * (PEND_VERTS + 2) - 4)
		local done = 0
		for i = 1, n do
			if HG[i] then
				local b = BB[i]
				done = done + 1
				-- the neck stays on the skin, the bulb swells and stretches along gravity
				local k = min(b.hangK, 1.3)
				local rad = 0.12 + 0.3 * (min(b.vol, 0.15) ^ 0.3333) * (0.75 + 0.3 * k)
				local len = rad * (1.3 + 1.5 * k)
				Pendant(BX[i], BY[i], BZ[i], gdx, gdy, gdz, rad, len, r, g, b0, 245, done > 1, done < nPend)
			end
		end
		mesh.End()
	end
	for i = 1, n do BB[i] = nil end
end

------------------------------------------------------------------------------------------
-- One character
------------------------------------------------------------------------------------------
local glossCol = Vector()

-- Draw one character's body blood. Called from Z-City's PostDrawAppearance (same render pass
-- as the body, right after it) or from the fallback in the main render hook.
function F.DrawSource(src, body, immediate)
	-- body blood is drawn at most once per frame per character, whoever asks
	local fn = FrameNumber()
	if src.dsFrame == fn then
		prof.dupes = (prof.dupes or 0) + 1
		if not F.dupeTraced and ABL.Config.cl.debug:GetInt() ~= 0 or (not F.dupeTraced and ABL.testRun) then
			F.dupeTraced = true
			ABL.Print("body blood drawn twice in one frame, second caller:\n%s", debug.traceback())
		end
		return
	end
	src.dsFrame = fn
	local Prof = ABL.Prof
	Prof.Heap()
	local t0 = SysTime()
	local pose = src.pose
	-- fresh bone matrices for this frame's render: the body as it is drawn (a head Z-City hides for
	-- the camera in it is a point, and what is drawn on it goes with it). Whatever reads the pose
	-- after this drawing, and before the next step of the simulation says its own frame, reads the
	-- body as it is again (a hit that comes over the net: its wound is anchored then), and reads it
	-- anew: fn + 0.5 is no frame that anything was read for.
	pose:Begin(-fn)
	local c = src.bodyCenter or body:WorldSpaceCenter()
	local lr, lg, lb = R.Light(c.x, c.y, c.z)
	local now, rt = CurTime(), RealTime()
	local dryT = 160 * C.sv.drying:GetFloat()

	-- the character renderer may leave colour modulation / blend changed
	if F.buildFrame ~= fn then F.buildFrame = fn F.buildsThisFrame = 0 end
	local cr, cg, cb = render.GetColorModulation()
	local blend = render.GetBlend()
	render.SetColorModulation(1, 1, 1)
	render.SetBlend(1)

	-- near the camera: wet blood as liquid on the skin; farther away everything as soaked streaks
	local m = src.mesh
	local near = m ~= nil and src.dist < B.nearDist
	local mode = near and 1 or 2
	local gloss = near and src.dist < B.glossDist
	src.tone = src.tone or math.Rand(C.ToneRange[1], 1)

	VW.lr, VW.lg, VW.lb = lr, lg, lb
	if near then
		local gx, gy, gz, gmag = ABL.Gravity()
		VW.ux, VW.uy, VW.uz = -gx / gmag, -gy / gmag, -gz / gmag
		VW.ex, VW.ey, VW.ez = L.eyeX, L.eyeY, L.eyeZ
		local sx, sy, sz, vis = R.Sun()
		if sx then VW.sx, VW.sy, VW.sz, VW.sk = sx, sy, sz, vis else VW.sx, VW.sy, VW.sz, VW.sk = VW.ux, VW.uy, VW.uz, 0.35 end
	end
	-- tight to the skin, a little more with distance against depth fighting
	local off = 0.035 + src.dist * 0.00035

	-- gunshot wound marks first: blood runs over them. (Their openings are cut out of the picture
	-- when the body's blood is on it, further down: what is seen in a wound that bleeds is its own
	-- blood, ABL.WoundFX.DrawOpenings. They were cut here and the blood kept out of them.)
	local cut = false
	if src.marks and #src.marks > 0 and m then cut = ABL.WoundFX.Draw(src, pose, off) end
	local tMarks = SysTime()

	if src.segs then
		local builds = F.buildsThisFrame or 0
		local ft = max(RealFrameTime(), 0.002)
		local filt, glossMat = ABL.Mat.filmFilter, ABL.Mat.bodyGloss
		for bone, list in pairs(src.segs) do
			if #list > 0 then
				-- rebuild when blood was added (at most twice a second: until then new segments are
				-- drawn live), when the drawing mode changed, and at the pace its ageing needs
				local built = src.segBuild[bone]
				local since = rt - (built or 0)
				local info = src.segInfo[bone]
				local stale = src.segMode and src.segMode[bone] ~= mode
				-- Blood on skin that bends between bones is part of the static mesh while the body
				-- holds its pose (a corpse, someone standing still) and drawn live while it moves:
				-- the mesh is rebuilt when the bones it hangs on have moved against each other, or
				-- have come to rest again.
				local quiet, force = false, false
				if near and info and #info.partners > 0 then
					local drift = PoseDrift(pose, bone, info, rt, ft)
					quiet = rt - info.moveT > 0.5
					if info.quietBuild then
						force = drift > POSE_TOL and (since > 0.5 or drift > POSE_TOL * 2.5)
					else
						force = quiet and since > 0.3 and (drift > POSE_TOL or #src.segDyn[bone] > 0)
					end
					if not info.quietBuild then Prof.Count("live bones", 1) end
				end
				if (not built or stale or force or (src.segDirty[bone] and since > 0.5) or since > (info and info.period or 4)
					or (info and info.tipPending and since > 1)) and builds < 3 then
					local tbld = SysTime()
					BuildBone(src, bone, lr, lg, lb, now, dryT, near, m, pose, quiet, fn)
					if force then Prof.Count("pose rebuilds", 1) end
					prof.build = (prof.build or 0) + (SysTime() - tbld) * 1000
					prof.builds = (prof.builds or 0) + 1
					builds = builds + 1
					Prof.Count("mesh builds", 1)
					info = src.segInfo[bone]
				end
				local fm, gm = src.segMesh[bone], gloss and src.segGloss[bone]
				if fm or gm then
					local ok
					if body.CopyBoneMatrix then
						body:CopyBoneMatrix(bone, boneMat)
						ok = true
					else
						local bm = body:GetBoneMatrix(bone)
						if bm then boneMat = bm ok = true end
					end
					if ok then
						cam.PushModelMatrix(boneMat)
						if fm then R.FilterDraw(filt, fm) Prof.Count("static meshes", 1) end
						if gm then
							-- the reflection's strength from the view onto this bone's wet blood
							local e = pose:Bone(bone)
							if e then
								local nx, ny, nz, px, py, pz = info.nx, info.ny, info.nz, info.cx, info.cy, info.cz
								local wnx, wny, wnz = ABL.Norm(e[1] * nx + e[2] * ny + e[3] * nz, e[5] * nx + e[6] * ny + e[7] * nz, e[9] * nx + e[10] * ny + e[11] * nz)
								local wx = e[1] * px + e[2] * py + e[3] * pz + e[4]
								local wy = e[5] * px + e[6] * py + e[7] * pz + e[8]
								local wz = e[9] * px + e[10] * py + e[11] * pz + e[12]
								-- (blood running all around a limb has no one direction: a plain sheen then)
								local sp = info.spread or 1
								local k = min(Reflect(wnx, wny, wnz, wx, wy, wz, 1) * 0.4, 0.28) * sp + 0.07 * (1 - sp)
								if k > 0.004 then
									R.EndFilter()
									glossCol:SetUnpacked(k, k, k)
									glossMat:SetVector("$color", glossCol)
									render.SetMaterial(glossMat)
									gm:Draw()
								end
							end
						end
						cam.PopModelMatrix()
					end
				end
			end
		end
		R.EndFilter()
		F.buildsThisFrame = builds
	end
	local tStatic = SysTime()

	-- the continuous liquid (cl_flowcore.lua), drawn by cl_flowdraw.lua
	if src.fc and m then ABL.FlowDraw.Source(src, pose, m, near, gloss, off, now, dryT) end
	-- the film on the body's surface (cl_film.lua): drawn by the body's own model, cl_filmdraw.lua
	if src.film then
		local tf = SysTime()
		FMD.Source(src, body, immediate)
		Prof.Add("sub.body.film", SysTime() - tf)
		-- (phase 19: the blood that waits at an edge of the film to drop hangs there as a drop, in the
		-- pose the body was drawn in: cl_filmpendant.lua)
		local FP = ABL.FilmPendant
		if FP and FP.Draw and C.V19On("pendant") then FP.Draw(src, body, pose) end
	end

	if near then
		local nq = src.segs and DrawLiveStrips(src, pose, m, now, dryT, off, gloss, fn) or 0
		local tStrips = SysTime()
		DrawBeads(src, pose, off, gloss)
		local tBeads = SysTime()
		prof.dyn = (prof.dyn or 0) + (tStrips - tStatic) * 1000
		prof.beadDraw = (prof.beadDraw or 0) + (tBeads - tStrips) * 1000
		prof.live = (prof.live or 0) + (nq or 0)
		Prof.Count("live quads", nq or 0) Prof.Count("trail points", edgeN) edgeN = 0
		Prof.Add("sub.body.marks", tMarks - t0) Prof.Add("sub.body.static", tStatic - tMarks)
		Prof.Add("sub.body.live", tStrips - tStatic) Prof.Add("sub.body.beads", tBeads - tStrips)
		-- (the wounds' openings, cut out of the body with its blood on it, and their rims: light and
		-- shade over the blood that has run over them)
		if cut then ABL.WoundFX.DrawOpenings(src) ABL.WoundFX.DrawRelief(src) end
		render.SetColorModulation(cr, cg, cb)
		render.SetBlend(blend)
		pose:Begin(fn + 0.5)
		local dtDraw = SysTime() - t0
		Prof.Heap("draw body")
		F.drawAcc = (F.drawAcc or 0) + dtDraw * 1000
		Prof.Add("draw.body", dtDraw)
		prof.draws = (prof.draws or 0) + 1
		return
	end

	-- far away: runnel heads and beads at wounds are small lit drops; resting puddles are wet soaked
	-- patches; beads on undersides and edges hang as drops along gravity. The sprites and the atlas
	-- carry the blood colour; vertex colours are light x tone.
	local tone = src.tone
	local lcr, lcg, lcb = min(255, 255 * lr * tone), min(255, 255 * lg), min(255, 255 * lb)
	off = B.offset + 0.06
	local gx, gy, gz, gmag = ABL.Gravity()
	local gdx, gdy, gdz = gx / gmag, gy / gmag, gz / gmag
	local atlas, soakCell = ABL.Mat.atlas, ABL.Mat.AtlasCell("soak", 1)
	local queued = false
	local blobs = src.blobs
	-- (beads sit on triangles of the body mesh: a body whose mesh is not there, because its model
	-- has just changed and the new one is not built yet, has none to draw them on)
	local pm = pose.mesh
	for i = 1, (pm and #blobs or 0) do
		local b = blobs[i]
		if not b.dead and b.tri and b.tri <= pm.nt and b.vol > 0.01 then
			local px, py, pz, nx, ny, nz = F.BeadPoint(pose, b, m)
			-- a bead's visible size saturates: surface tension cannot hold a bigger drop together,
			-- more volume shows up as flow and streaks instead
			local rad = 0.1 + 0.3 * (min(b.vol, 0.6) ^ 0.3333)
			if b.hangK > 0.25 then
				-- pendant drop: a bead pulled out along gravity, longer as it nears detachment
				rad = 0.1 + 0.3 * (min(b.vol, 0.15) ^ 0.3333)
				local k = min(b.hangK, 1.3)
				local len = rad * (1.1 + 1.6 * k)
				local w = rad * (1.3 + 0.5 * k)
				local hx, hy, hz = px + nx * off + gdx * len * 0.4, py + ny * off + gdy * len * 0.4, pz + nz * off + gdz * len * 0.4
				R.Streak(ABL.Mat.droplet, hx, hy, hz, gdx, gdy, gdz, len, w, lcr, lcg, lcb, 240)
				queued = true
			elseif b.moving or b.tethered then
				local sp = sqrt(b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
				local sx, sy, sz, qx, qy, qz
				if sp > 0.05 then
					sx, sy, sz = b.vx / sp, b.vy / sp, b.vz / sp
				else
					sx, sy, sz = ABL.Perp(nx, ny, nz)
				end
				qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
				local stretch = 1 + min(sp * 0.3, 1.2)
				R.PlaneQuad(ABL.Mat.droplet, px + nx * off, py + ny * off, pz + nz * off,
					sx * rad * stretch, sy * rad * stretch, sz * rad * stretch, qx * rad * 0.8, qy * rad * 0.8, qz * rad * 0.8,
					lcr, lcg, lcb, 225)
				queued = true
			else
				-- resting puddle: a wet patch the size of its footprint, fading as it soaks in
				local pr = PuddleRadius(b.vol) * 1.35 + 0.2
				local sx, sy, sz = ABL.Perp(nx, ny, nz)
				local qx, qy, qz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
				local ca, sa = math.cos(b.rot), math.sin(b.rot)
				local ux, uy, uz = (sx * ca + qx * sa) * pr, (sy * ca + qy * sa) * pr, (sz * ca + qz * sa) * pr
				local wx, wy, wz = (qx * ca - sx * sa) * pr, (qy * ca - sy * sa) * pr, (qz * ca - sz * sa) * pr
				local a = Clamp(b.vol / 0.12, 0.25, 1) * 200
				local cx, cy, cz = px + nx * off, py + ny * off, pz + nz * off
				R.Quad(atlas,
					cx - ux - wx, cy - uy - wy, cz - uz - wz,
					cx + ux - wx, cy + uy - wy, cz + uz - wz,
					cx + ux + wx, cy + uy + wy, cz + uz + wz,
					cx - ux + wx, cy - uy + wy, cz - uz + wz,
					lcr * 0.72, lcg * 0.72, lcb * 0.72, a,
					soakCell[1], soakCell[2], soakCell[3], soakCell[4])
				queued = true
			end
		end
	end
	if queued and immediate then R.Flush() end
	if cut then ABL.WoundFX.DrawOpenings(src) ABL.WoundFX.DrawRelief(src) end

	render.SetColorModulation(cr, cg, cb)
	render.SetBlend(blend)
	pose:Begin(fn + 0.5)
	-- body blood is drawn from the character renderer, outside the main draw timing
	local dtDraw = SysTime() - t0
	Prof.Heap("draw body")
	F.drawAcc = (F.drawAcc or 0) + dtDraw * 1000
	Prof.Add("draw.body", dtDraw)
	prof.draws = (prof.draws or 0) + 1
end

-- Z-City fires this right after it draws a character (player or ragdoll).
hook.Add("PostDrawAppearance", "ABL_BodyBlood", function(ent, ply)
	if not ABL.Enabled() or not IsValid(ent) then return end
	local src = ABL.Sources.byBody and ABL.Sources.byBody[ent]
	if not src or src.body ~= ent then return end
	if (src.segCount or 0) == 0 and #src.blobs == 0 and not (src.marks and #src.marks > 0) and not FC.Active(src) and not FM.Active(src) then return end
	local frame = FrameNumber()
	-- (this body is one that Z-City's renderer draws: its blood is drawn from here, and only from here)
	src.appearFrame, src.appearBody = frame, ent
	-- (called from within the fallback's own drawing of this body: a body that is new was not
	-- known to be Z-City's, and its film's drawing of the model has run Z-City's renderer. It
	-- is known now; the fallback finishes what it began, once.)
	if F.fallbackSrc == src then return end
	-- (why its blood was not drawn in a frame, for cl_trace.lua: said where this hook leaves)
	if src.dist > 1600 then src.skipFrame, src.skipWhy = frame, "its body is more than 1600 units away" return end
	-- views rendered into a texture (water reflection / refraction, cameras) do not get body
	-- blood: it would double the cost for a detail nobody can make out there. (Asked first: where
	-- water is in sight its mirrored view asks for every body on the ground once a frame, and the
	-- view setup below is a new table of about 1 KB at every call.)
	if render.GetRenderTarget() ~= nil then return end
	-- the character renderer also runs for shadow maps and other render-target views: body blood
	-- belongs to screen-sized views only
	local vs = render.GetViewSetup()
	if vs and vs.width and (vs.width ~= ScrW() or vs.height ~= ScrH()) then return end
	-- and a character drawn more than once in the main view (appearance layers) gets it once.
	-- All but the film: that lies exactly in the skin (it is the body's own model), so a further
	-- drawing of the body covers it wherever the two agree to the last digit and lets shreds of it
	-- through wherever they do not. The film is drawn again over each further drawing.
	if src.drawnFrame == frame then
		if src.film and src.dsBody == ent then
			src.againN = (src.againN or 0) + 1
			prof.again = (prof.again or 0) + 1
			FMD.Source(src, ent, true)
		end
		return
	end
	src.drawnFrame, src.dsBody = frame, ent
	-- The body is being drawn in the player's own view: it is in sight. What the LOD made of it
	-- is up to a fifth of a second old (cl_lod.lua looks at a character five times a second, with
	-- the view of the frame before): a body that came into the picture as the camera turned was
	-- drawn without its blood until the LOD looked again. The LOD is told, and looks now.
	src.seenFrame = frame
	if not src.visible then src.nextEval = 0 end
	ABL.Prof.MemBegin()
	F.DrawSource(src, ent, true)
	ABL.Prof.MemEnd()
end)

-- Fallback for bodies that are not drawn through Z-City's renderer.
function F.Draw()
	-- the translucent pass runs for every view; body blood belongs to the main one (a full-size
	-- reflection or refraction view would otherwise take the once-per-frame draw)
	if render.GetRenderTarget() ~= nil then return end
	local lp = LocalPlayer()
	local frame = FrameNumber()
	F.fallbackSrc = nil
	for _, src in ipairs(ABL.Sources.list) do
		local body = src.body
		-- A body that Z-City's renderer has drawn gets its blood there, in the frames in which the
		-- engine draws it, and in no other. (This asked whether it had been drawn in the last two
		-- frames: a body out of the picture had not, so its blood was drawn from here, and the
		-- film is the body's model drawn again, which runs Z-City's renderer for it, hook and all.
		-- Every body near the camera and out of its sight was drawn in full, with its clothes and
		-- its blood, every third frame.)
		local viaZCity = src.appearBody == body
		-- the local player's upright body is usually not rendered in first person: its bones are stale
		local hidden = body == lp and not lp:ShouldDrawLocalPlayer()
		if not viaZCity and IsValid(body) and not hidden and src.dist < 1600 and ((src.segCount or 0) > 0 or #src.blobs > 0 or (src.marks and #src.marks > 0) or FC.Active(src) or FM.Active(src))
			and not body:IsDormant() and not body:GetNoDraw() then
			-- In sight? What the LOD made of it is up to a fifth of a second old: a body that came
			-- into the picture as the camera turned was drawn without its blood until the LOD
			-- looked again (measured on a body 150 units away: up to nine frames). Asked here for
			-- this frame's view when the LOD has it out of sight, and the LOD is told.
			local vis = src.visible
			if not vis then
				local c = src.bodyCenter
				if c then
					local _, on = L.View(c.x, c.y, c.z, 48)
					if on then
						vis = true
						src.seenFrame, src.nextEval = frame, 0
					end
				end
			end
			if vis then
				F.fallbackSrc = src
				F.DrawSource(src, body, false)
				F.fallbackSrc = nil
			end
		end
	end
end
