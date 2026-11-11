-- Body surface model.
-- Builds, per model (+bodygroups), a welded triangle mesh of the character's real render mesh
-- (util.GetModelMeshes) with bone weights, triangle adjacency and per-bone triangle lists.
-- At runtime points on that mesh are skinned with the entity's current bone matrices, so blood
-- on the body sits exactly on the skin and follows every animation and ragdoll pose.
-- Meshes are built in a time-sliced coroutine; until ready, emission falls back to direct drips.

ABL.NoJIT()
ABL.BodyMesh = ABL.BodyMesh or {}
local BM = ABL.BodyMesh
local Z = ABL.ZC
local sqrt, floor, abs, min, max = math.sqrt, math.floor, math.abs, math.min, math.max
local yield = coroutine.yield

BM.cache = BM.cache or {}
local jobs = {}

local SKIP_MATERIAL = { "eye", "teeth", "tongue", "iris", "cornea", "glasses", "lens" }
-- materials of bare skin (blood stays on it as a film; into everything else it soaks like cloth)
local SKIN_MATERIAL = { "face", "skin", "head", "flesh", "hands" }
-- How much blood a covering takes up, by a word in its material's name (the first that matches;
-- anything else is ordinary cloth, 1). Leather, rubber and coated or hard things take up little:
-- blood stays on them and runs off.
local ABSORB = {
	{ "leather", 0.3 }, { "rubber", 0.15 }, { "latex", 0.15 }, { "plastic", 0.1 }, { "metal", 0.05 }, { "helmet", 0.1 },
	{ "armor", 0.25 }, { "armour", 0.25 }, { "kevlar", 0.3 }, { "vest", 0.45 }, { "boot", 0.3 }, { "shoe", 0.3 }, { "glove", 0.4 },
	{ "jacket", 0.6 }, { "coat", 0.6 }, { "nylon", 0.4 },
}

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------
local function WeldKey(x, y, z) return ABL.CellKey(x, y, z, 1 / 32) end

local GRID = 2
local function GridKey(gx, gy, gz) return ((gx + 32768) * 65536 + (gy + 32768)) * 65536 + (gz + 32768) end

local function MatrixRows(m)
	local a11, a12, a13, a14, a21, a22, a23, a24, a31, a32, a33, a34 = m:Unpack()
	return { a11, a12, a13, a14, a21, a22, a23, a24, a31, a32, a33, a34 }
end

-- General 3x4 affine inverse (handles scaled bones).
-- out: the table to fill (a caller that inverts every frame hands in the one it had: a new table
-- per bone per frame was a third of a megabyte of garbage a second); without it a new one.
local function Invert(t, out)
	local a, b, c, d = t[1], t[2], t[3], t[4]
	local e, f, g, h = t[5], t[6], t[7], t[8]
	local i, j, k, l = t[9], t[10], t[11], t[12]
	local c11, c12, c13 = f * k - g * j, c * j - b * k, b * g - c * f
	local c21, c22, c23 = g * i - e * k, a * k - c * i, c * e - a * g
	local c31, c32, c33 = e * j - f * i, b * i - a * j, a * f - b * e
	local det = a * c11 + b * c21 + c * c31
	if abs(det) < 1e-12 then det = 1e-12 end
	local inv = 1 / det
	c11, c12, c13 = c11 * inv, c12 * inv, c13 * inv
	c21, c22, c23 = c21 * inv, c22 * inv, c23 * inv
	c31, c32, c33 = c31 * inv, c32 * inv, c33 * inv
	out = out or { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	out[1], out[2], out[3], out[4] = c11, c12, c13, -(c11 * d + c12 * h + c13 * l)
	out[5], out[6], out[7], out[8] = c21, c22, c23, -(c21 * d + c22 * h + c23 * l)
	out[9], out[10], out[11], out[12] = c31, c32, c33, -(c31 * d + c32 * h + c33 * l)
	return out
end
BM.Invert = Invert

local function Xform(t, x, y, z)
	return t[1] * x + t[2] * y + t[3] * z + t[4],
		t[5] * x + t[6] * y + t[7] * z + t[8],
		t[9] * x + t[10] * y + t[11] * z + t[12]
end
BM.Xform = Xform

local function BuildJob(m, model, mask)
	local lod = 0
	local meshes, binds = util.GetModelMeshes(model, lod, mask)
	if not meshes or not binds then m.failed = true return end
	yield()

	-- bind poses: detect 0- or 1-based indexing
	local base = binds[0] and 0 or 1
	local bindT = {}
	for k, bp in pairs(binds) do
		if istable(bp) and bp.matrix then bindT[k - base] = MatrixRows(bp.matrix) end
	end

	local vx, vy, vz = {}, {}, {}
	local b1, w1, b2, w2, b3, w3 = {}, {}, {}, {}, {}, {}
	local nx, ny, nz = {}, {}, {}
	local weld = {}
	local nv = 0
	local t1, t2, t3, tb, tsg, tskin = {}, {}, {}, {}, {}, {}
	local tabs = {}
	local matNames = {}
	-- where each triangle lies in its material's texture (the corners' texture coordinates; welding
	-- by position has taken them off the vertices) and which material that is: the blood film is
	-- painted there (cl_filmchart.lua)
	local tm, tu1, tv1, tu2, tv2, tu3, tv3 = {}, {}, {}, {}, {}, {}, {}
	local mats, matIdx = {}, {}
	local nt = 0
	local work = 0

	local function Vid(v)
		local p = v.pos
		local key = WeldKey(p.x, p.y, p.z)
		local id = weld[key]
		if id then return id end
		nv = nv + 1
		id = nv
		weld[key] = id
		vx[id], vy[id], vz[id] = p.x, p.y, p.z
		local n = v.normal or vector_up
		nx[id], ny[id], nz[id] = n.x, n.y, n.z
		-- up to three strongest weights, renormalised
		local ws = v.weights
		local bb1, ww1, bb2, ww2, bb3, ww3 = 0, 1, -1, 0, -1, 0
		if istable(ws) and #ws > 0 then
			local list = {}
			for _, bw in ipairs(ws) do list[#list + 1] = bw end
			table.sort(list, function(a, b) return (a.weight or 0) > (b.weight or 0) end)
			bb1, ww1 = list[1].bone or 0, list[1].weight or 1
			if list[2] and (list[2].weight or 0) > 0.02 then bb2, ww2 = list[2].bone, list[2].weight end
			if list[3] and (list[3].weight or 0) > 0.02 then bb3, ww3 = list[3].bone, list[3].weight end
			local s = ww1 + ww2 + ww3
			if s <= 0 then s = 1 end
			ww1, ww2, ww3 = ww1 / s, ww2 / s, ww3 / s
		end
		b1[id], w1[id], b2[id], w2[id], b3[id], w3[id] = bb1, ww1, bb2, ww2, bb3, ww3
		return id
	end

	for _, sub in ipairs(meshes) do
		local matName = string.lower(sub.material or "")
		matNames[#matNames + 1] = string.match(matName, "([^/\\]+)$") or matName
		local skip = false
		for _, pat in ipairs(SKIP_MATERIAL) do
			if string.find(matName, pat, 1, true) then skip = true break end
		end
		local skin = false
		for _, pat in ipairs(SKIN_MATERIAL) do
			if string.find(matNames[#matNames], pat, 1, true) then skin = true break end
		end
		local absorb = 1
		for _, e in ipairs(ABSORB) do
			if string.find(matNames[#matNames], e[1], 1, true) then absorb = e[2] break end
		end
		local mi = matIdx[matName]
		if not mi then
			mi = #mats + 1
			mats[mi] = { path = matName, name = matNames[#matNames], skin = skin, absorb = absorb, tris = 0 }
			matIdx[matName] = mi
		end
		local tv = sub.triangles
		if not skip and istable(tv) then
			for i = 1, #tv - 2, 3 do
				local A, B, Cc = tv[i], tv[i + 1], tv[i + 2]
				if A and B and Cc and A.pos and B.pos and Cc.pos then
					local ia, ib, ic = Vid(A), Vid(B), Vid(Cc)
					if ia ~= ib and ib ~= ic and ia ~= ic then
						-- bind-space face normal vs vertex normals -> winding sign
						local ex, ey, ez = vx[ib] - vx[ia], vy[ib] - vy[ia], vz[ib] - vz[ia]
						local fx, fy, fz = vx[ic] - vx[ia], vy[ic] - vy[ia], vz[ic] - vz[ia]
						local cx, cy, cz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
						local area2 = cx * cx + cy * cy + cz * cz
						if area2 > 1e-8 then
							nt = nt + 1
							t1[nt], t2[nt], t3[nt] = ia, ib, ic
							local sn = cx * (nx[ia] + nx[ib] + nx[ic]) + cy * (ny[ia] + ny[ib] + ny[ic]) + cz * (nz[ia] + nz[ib] + nz[ic])
							tsg[nt] = sn >= 0 and 1 or -1
							if skin then tskin[nt] = true end
							if absorb ~= 1 then tabs[nt] = absorb end
							tm[nt] = mi
							tu1[nt], tv1[nt], tu2[nt], tv2[nt], tu3[nt], tv3[nt] = A.u or 0, A.v or 0, B.u or 0, B.v or 0, Cc.u or 0, Cc.v or 0
							mats[mi].tris = mats[mi].tris + 1
							-- dominant bone
							local acc = {}
							for _, vid in ipairs({ ia, ib, ic }) do
								acc[b1[vid]] = (acc[b1[vid]] or 0) + w1[vid]
								if b2[vid] >= 0 then acc[b2[vid]] = (acc[b2[vid]] or 0) + w2[vid] end
								if b3[vid] >= 0 then acc[b3[vid]] = (acc[b3[vid]] or 0) + w3[vid] end
							end
							local bestB, bestW = 0, -1
							for bb, ww in pairs(acc) do if ww > bestW then bestB, bestW = bb, ww end end
							tb[nt] = bestB
						end
					end
				end
				work = work + 1
				if work % 400 == 0 then yield() end
			end
		end
	end
	if nt == 0 then m.failed = true return end

	-- Decide whether bind matrices are bone->model (expected) or model->bone, by checking which
	-- interpretation keeps vertices close to their dominant bone.
	local invT = {}
	for b, t in pairs(bindT) do invT[b] = Invert(t) end
	local sumA, sumB, cnt = 0, 0, 0
	for i = 1, nv, max(1, floor(nv / 300)) do
		local bt, it = bindT[b1[i]], invT[b1[i]]
		if bt and it then
			local ax, ay, az = Xform(it, vx[i], vy[i], vz[i])
			local bx, by, bz = Xform(bt, vx[i], vy[i], vz[i])
			sumA = sumA + sqrt(ax * ax + ay * ay + az * az)
			sumB = sumB + sqrt(bx * bx + by * by + bz * bz)
			cnt = cnt + 1
		end
	end
	if sumB < sumA then
		-- the table already holds model->bone matrices
		invT, bindT = bindT, invT
		m.bindInverted = true
	end
	yield()

	-- adjacency
	local edges = {}
	local n1, n2, n3 = {}, {}, {}
	local function Link(t, slot, a, b)
		local lo, hi = a, b
		if lo > hi then lo, hi = hi, lo end
		local key = lo * 1048576 + hi
		local other = edges[key]
		if other then
			local ot, os = floor(other / 4), other % 4
			if os == 1 then n1[ot] = t elseif os == 2 then n2[ot] = t else n3[ot] = t end
			if slot == 1 then n1[t] = ot elseif slot == 2 then n2[t] = ot else n3[t] = ot end
			edges[key] = nil
		else
			edges[key] = t * 4 + slot
		end
	end
	for t = 1, nt do
		n1[t], n2[t], n3[t] = 0, 0, 0
	end
	for t = 1, nt do
		Link(t, 1, t1[t], t2[t])
		Link(t, 2, t2[t], t3[t])
		Link(t, 3, t3[t], t1[t])
		if t % 800 == 0 then yield() end
	end

	-- per bone triangle lists (dominant) and bind-space centroids
	local boneTris = {}
	local tcx, tcy, tcz = {}, {}, {}
	for t = 1, nt do
		local a, b, c = t1[t], t2[t], t3[t]
		tcx[t] = (vx[a] + vx[b] + vx[c]) / 3
		tcy[t] = (vy[a] + vy[b] + vy[c]) / 3
		tcz[t] = (vz[a] + vz[b] + vz[c]) / 3
		local list = boneTris[tb[t]]
		if not list then list = {} boneTris[tb[t]] = list end
		list[#list + 1] = t
	end

	-- connected pieces ("shells"): clothing layers, zipper strips, pockets and separately modelled
	-- body parts are separate shells whose open edges touch other shells without sharing vertices
	local shell = {}
	local ns = 0
	for t = 1, nt do
		if not shell[t] then
			ns = ns + 1
			shell[t] = ns
			local stack, sp = { t }, 1
			while sp > 0 do
				local c = stack[sp]
				stack[sp] = nil
				sp = sp - 1
				local a, b, d = n1[c], n2[c], n3[c]
				if a > 0 and not shell[a] then shell[a] = ns sp = sp + 1 stack[sp] = a end
				if b > 0 and not shell[b] then shell[b] = ns sp = sp + 1 stack[sp] = b end
				if d > 0 and not shell[d] then shell[d] = ns sp = sp + 1 stack[sp] = d end
			end
		end
		if t % 1500 == 0 then yield() end
	end

	-- bind-space grid of triangles (2 unit cells) for fast "closest surface near a point" queries
	local grid = {}
	for t = 1, nt do
		local a, b, c = t1[t], t2[t], t3[t]
		local x0, x1 = floor(min(vx[a], vx[b], vx[c]) / GRID), floor(max(vx[a], vx[b], vx[c]) / GRID)
		local y0, y1 = floor(min(vy[a], vy[b], vy[c]) / GRID), floor(max(vy[a], vy[b], vy[c]) / GRID)
		local z0, z1 = floor(min(vz[a], vz[b], vz[c]) / GRID), floor(max(vz[a], vz[b], vz[c]) / GRID)
		-- degenerate giant triangles (rare) only go into the cells around their corners
		if x1 - x0 > 6 or y1 - y0 > 6 or z1 - z0 > 6 then x1, y1, z1 = x0, y0, z0 end
		for gx = x0, x1 do
			for gy = y0, y1 do
				for gz = z0, z1 do
					local k = GridKey(gx, gy, gz)
					local l = grid[k]
					if not l then l = {} grid[k] = l end
					l[#l + 1] = t
				end
			end
		end
		if t % 800 == 0 then yield() end
	end

	m.vx, m.vy, m.vz, m.nx, m.ny, m.nz = vx, vy, vz, nx, ny, nz
	m.b1, m.w1, m.b2, m.w2, m.b3, m.w3 = b1, w1, b2, w2, b3, w3
	m.t1, m.t2, m.t3, m.tb, m.tsg, m.tskin = t1, t2, t3, tb, tsg, tskin
	m.tabs = tabs
	m.tm, m.tu1, m.tv1, m.tu2, m.tv2, m.tu3, m.tv3 = tm, tu1, tv1, tu2, tv2, tu3, tv3
	m.mats = mats
	m.n1, m.n2, m.n3 = n1, n2, n3
	m.tcx, m.tcy, m.tcz = tcx, tcy, tcz
	m.boneTris = boneTris
	m.shell, m.nshell = shell, ns
	m.grid = grid
	m.stamp, m.stampN = {}, 0
	m.bind, m.inv = bindT, invT
	m.nv, m.nt = nv, nt
	m.ready = true
	local nskin = 0
	for _ in pairs(tskin) do nskin = nskin + 1 end
	m.nskin = nskin
	ABL.Print("body mesh ready: %s (%d verts, %d tris, %d on bare skin, %d shells%s; materials: %s)", model, nv, nt, nskin, ns, m.bindInverted and ", inverted binds" or "", table.concat(matNames, ", "))
end

-- Cache key and the engine's studio body index for the entity's current bodygroups. The body
-- index (what util.GetModelMeshes takes) is sum(value_i * stride_i), stride_i being the product
-- of the variant counts of all earlier groups. With the wrong index the simulated surface is a
-- different outfit than the one drawn (blood running inside wide trousers, over a bare arm).
function BM.KeyFor(ent)
	local model = ent:GetModel()
	if not model then return nil end
	local body, stride = 0, 1
	local n = ent:GetNumBodyGroups() or 0
	for i = 0, n - 1 do
		local v = ent:GetBodygroup(i) or 0
		local count = ent:GetBodygroupCount(i) or 1
		if count < 1 then count = 1 end
		body = body + v * stride
		stride = stride * count
	end
	return model .. "|" .. body, model, body
end

-- Surface models are kept by model and outfit, about 1.7 MB of Lua tables each. A long session
-- sees many outfits: beyond C.MESH_KEEP the ones longest unasked for go, unless a character still
-- works with them (what lies on such a body keeps its own reference: nothing is pulled away under it).
local cacheN = 0
local function Older(a, b) return a.used < b.used end
local function Trim()
	local Cf = ABL.Config
	local inUse = {}
	for _, src in ipairs(ABL.Sources and ABL.Sources.list or {}) do
		if src.mesh then inUse[src.mesh] = true end
	end
	local now = RealTime()
	local list = {}
	cacheN = 0
	for _, m in pairs(BM.cache) do
		cacheN = cacheN + 1
		m.used = m.used or 0
		-- (a model a character works with was asked for just now, in effect)
		if inUse[m] then
			m.used = now
		elseif (m.ready or m.failed) and now - m.used > Cf.MESH_IDLE then
			list[#list + 1] = m
		end
	end
	table.sort(list, Older)
	for i = 1, #list do
		if cacheN <= Cf.MESH_KEEP * 0.75 then break end
		BM.cache[list[i].key] = nil
		cacheN = cacheN - 1
	end
end

-- Returns a ready mesh for the entity or nil (and schedules a build).
function BM.Get(ent)
	if not IsValid(ent) then return nil end
	local key, model, mask = BM.KeyFor(ent)
	if not key then return nil end
	local m = BM.cache[key]
	if m then
		m.used = RealTime()
		if m.ready then return m end
		return nil
	end
	if cacheN >= ABL.Config.MESH_KEEP then Trim() end
	m = { key = key, model = model, used = RealTime() }
	cacheN = cacheN + 1
	BM.cache[key] = m
	jobs[#jobs + 1] = { m = m, co = coroutine.create(function() BuildJob(m, model, mask) end) }
	return nil
end

-- Time-sliced job runner (called every frame from the sim loop).
function BM.RunJobs(budgetMs)
	if #jobs == 0 then return end
	local t0 = SysTime()
	while #jobs > 0 and (SysTime() - t0) * 1000 < budgetMs do
		local job = jobs[1]
		local ok, err = coroutine.resume(job.co)
		if not ok then
			job.m.failed = true
			ABL.Print("body mesh build failed for %s: %s", tostring(job.m.model), tostring(err))
			table.remove(jobs, 1)
		elseif coroutine.status(job.co) == "dead" then
			table.remove(jobs, 1)
		end
	end
end

------------------------------------------------------------------------------------------
-- Pose: per-entity, per-frame cache of bone matrices, skin matrices and bone velocities.
------------------------------------------------------------------------------------------
-- the same class table across Lua refreshes, so poses created before a reload get its new methods
local Pose = BM.PoseClass or {}
BM.PoseClass = Pose
Pose.__index = Pose

function BM.NewPose()
	return setmetatable({ ent = nil, frame = -1, bones = {}, skins = {}, vel = {}, mesh = nil, cx = {}, cy = {}, cz = {}, cf = {} }, Pose)
end

function Pose:Bind(ent, m)
	if self.ent ~= ent or self.mesh ~= m then
		self.bones = {}
		self.skins = {}
		self.cx, self.cy, self.cz, self.cf = {}, {}, {}, {}
		-- (the bones watched for the strips on it: cl_flowdraw.lua)
		self.wlist, self.wset = nil, nil
	end
	if self.ent ~= ent then self.vel = {} end
	self.ent = ent
	self.mesh = m
end

-- frame: the number of the frame for what the simulation reads (the body as it is), its negative
-- for what is read to draw on the body (the body as it is drawn: ABL.Flow.DrawSource, which hands
-- the pose back to the simulation when it is done).
function Pose:Begin(frame)
	self.frame = frame
end

-- A bone that is drawn scaled away though the part is there. Z-City hides the head of the body
-- the camera is in by writing a hundredth into its matrix before it draws the body, and the
-- matrix stays that way until the engine sets the bones up again: whether the simulation found
-- the head at its size or as a point at the neck was a matter of the moment it looked. As a
-- point, a wound of that head could not be anchored on the skin (its place in the world lay a
-- hundred head's lengths outside the model), and its blood came out at the neck.
-- Only the head is hidden that way. Every other bone that is scaled away is a part that is gone
-- (Z-City writes a scale of next to nothing into an amputated limb's matrix at every drawing as
-- well, its GoreCalc), and so is the head of a body that has lost it: one a gore system has
-- scaled away for good, an amputated one, or that of a body Z-City keeps a fountain for (the
-- neck stump the server tells of, sh_zcity.lua). Those stay the points they are drawn as.
local function DrawnAway(ent, b)
	-- (abl_film_bones 0: as it was before, for comparison)
	local cv = ABL.FilmDraw and ABL.FilmDraw.cvBones
	if cv and not cv:GetBool() then return false end
	local name = ent:GetBoneName(b)
	if not name or Z.BoneLimb(name) ~= "head" then return false end
	if Z.BoneHidden(ent, b) then return false end
	local org = ent.new_organism or ent.organism
	if not istable(org) then
		local owner = Z.GetOwner(ent)
		org = IsValid(owner) and owner.organism or nil
	end
	if istable(org) and org.headamputated then return false end
	if not ent:GetNW2Vector("ABL_Neck", vector_origin):IsZero() then return false end
	local fl = GetNetVar and GetNetVar("fountains")
	return not (istable(fl) and fl[ent])
end

-- Raw bone matrix rows (12 numbers) for this frame, plus bone linear velocity tracking.
function Pose:Bone(b)
	local e = self.bones[b]
	if e and e.f == self.frame then return e end
	local ent = self.ent
	if not IsValid(ent) then return nil end
	local M = ent:GetBoneMatrix(b)
	if not M then return nil end
	local a11, a12, a13, a14, a21, a22, a23, a24, a31, a32, a33, a34 = M:Unpack()
	if self.frame >= 0 then
		-- (the simulation's reading: the bone at its size)
		local s2 = a11 * a11 + a21 * a21 + a31 * a31
		if s2 < 0.25 and s2 > 1e-10 and DrawnAway(ent, b) then
			local k1 = 1 / sqrt(s2)
			local k2 = 1 / sqrt(max(a12 * a12 + a22 * a22 + a32 * a32, 1e-12))
			local k3 = 1 / sqrt(max(a13 * a13 + a23 * a23 + a33 * a33, 1e-12))
			a11, a21, a31 = a11 * k1, a21 * k1, a31 * k1
			a12, a22, a32 = a12 * k2, a22 * k2, a32 * k2
			a13, a23, a33 = a13 * k3, a23 * k3, a33 * k3
			BM.unscaled = (BM.unscaled or 0) + 1
		end
	end
	if not e then e = { f = -1 } self.bones[b] = e end
	local now = CurTime()
	-- velocity (EMA) from translation delta
	local v = self.vel[b]
	if not v then v = { x = a14, y = a24, z = a34, t = now, vx = 0, vy = 0, vz = 0, ax = 0, ay = 0, az = 0 } self.vel[b] = v end
	local dt = now - v.t
	if dt > 0.0005 then
		local nvx, nvy, nvz = (a14 - v.x) / dt, (a24 - v.y) / dt, (a34 - v.z) / dt
		if nvx * nvx + nvy * nvy + nvz * nvz > 4000 * 4000 then nvx, nvy, nvz = v.vx, v.vy, v.vz end -- teleport
		local k = min(1, dt / 0.06)
		local ovx, ovy, ovz = v.vx, v.vy, v.vz
		v.vx = ovx + (nvx - ovx) * k
		v.vy = ovy + (nvy - ovy) * k
		v.vz = ovz + (nvz - ovz) * k
		local ka = min(1, dt / 0.08)
		v.ax = v.ax + (((v.vx - ovx) / dt) - v.ax) * ka
		v.ay = v.ay + (((v.vy - ovy) / dt) - v.ay) * ka
		v.az = v.az + (((v.vz - ovz) / dt) - v.az) * ka
		v.x, v.y, v.z, v.t = a14, a24, a34, now
	end
	-- (ver counts the readings at which a bone was not where it was at its reading before: a
	-- body at rest is one whose count stands still, and what lies on it need not be looked at)
	if e[4] ~= a14 or e[8] ~= a24 or e[12] ~= a34 or e[1] ~= a11 or e[2] ~= a12 or e[3] ~= a13 or e[5] ~= a21 or e[6] ~= a22 or e[7] ~= a23
		or e[9] ~= a31 or e[10] ~= a32 or e[11] ~= a33 then
		self.ver = (self.ver or 0) + 1
	end
	e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], e[11], e[12] =
		a11, a12, a13, a14, a21, a22, a23, a24, a31, a32, a33, a34
	e.invOk = false
	e.f = self.frame
	return e
end

function Pose:BoneVel(b)
	self:Bone(b)
	local v = self.vel[b]
	if not v then return 0, 0, 0, 0, 0, 0 end
	return v.vx, v.vy, v.vz, v.ax, v.ay, v.az
end

function Pose:BoneInv(b)
	local e = self:Bone(b)
	if not e then return nil end
	if not e.invOk then e.inv, e.invOk = Invert(e, e.inv), true end
	return e.inv
end

-- Skin matrix = BoneMatrix * inverse(bind) for this frame.
function Pose:Skin(b)
	local s = self.skins[b]
	if s and s.f == self.frame then return s end
	local e = self:Bone(b)
	local m = self.mesh
	if not e or not m then return nil end
	local i = m.inv[b]
	if not i then return nil end
	if not s then s = {} self.skins[b] = s end
	local a11, a12, a13, a14 = e[1], e[2], e[3], e[4]
	local a21, a22, a23, a24 = e[5], e[6], e[7], e[8]
	local a31, a32, a33, a34 = e[9], e[10], e[11], e[12]
	s[1] = a11 * i[1] + a12 * i[5] + a13 * i[9]
	s[2] = a11 * i[2] + a12 * i[6] + a13 * i[10]
	s[3] = a11 * i[3] + a12 * i[7] + a13 * i[11]
	s[4] = a11 * i[4] + a12 * i[8] + a13 * i[12] + a14
	s[5] = a21 * i[1] + a22 * i[5] + a23 * i[9]
	s[6] = a21 * i[2] + a22 * i[6] + a23 * i[10]
	s[7] = a21 * i[3] + a22 * i[7] + a23 * i[11]
	s[8] = a21 * i[4] + a22 * i[8] + a23 * i[12] + a24
	s[9] = a31 * i[1] + a32 * i[5] + a33 * i[9]
	s[10] = a31 * i[2] + a32 * i[6] + a33 * i[10]
	s[11] = a31 * i[3] + a32 * i[7] + a33 * i[11]
	s[12] = a31 * i[4] + a32 * i[8] + a33 * i[12] + a34
	s.f = self.frame
	return s
end

-- World position of welded vertex `id` (cached per frame: neighbouring queries share vertices).
function Pose:Vertex(id)
	local cf = self.cf
	if cf[id] == self.frame then return self.cx[id], self.cy[id], self.cz[id], true end
	local m = self.mesh
	local px, py, pz = m.vx[id], m.vy[id], m.vz[id]
	-- (a bone's skin matrix of this frame is read where it is kept, without a call)
	local skins, fr = self.skins, self.frame
	local bb = m.b1[id]
	local s = skins[bb]
	if not s or s.f ~= fr then s = self:Skin(bb) end
	if not s then
		-- (no matrix for its bone this frame: it stays where it last was, not at its place in the
		-- bind pose, which is a point near the origin of the map)
		if cf[id] then return self.cx[id], self.cy[id], self.cz[id], false end
		return px, py, pz, false
	end
	local w = m.w1[id]
	local x = w * (s[1] * px + s[2] * py + s[3] * pz + s[4])
	local y = w * (s[5] * px + s[6] * py + s[7] * pz + s[8])
	local z = w * (s[9] * px + s[10] * py + s[11] * pz + s[12])
	bb = m.b2[id]
	if bb >= 0 then
		s = skins[bb]
		if not s or s.f ~= fr then s = self:Skin(bb) end
		if s then
			w = m.w2[id]
			x = x + w * (s[1] * px + s[2] * py + s[3] * pz + s[4])
			y = y + w * (s[5] * px + s[6] * py + s[7] * pz + s[8])
			z = z + w * (s[9] * px + s[10] * py + s[11] * pz + s[12])
		end
		bb = m.b3[id]
		if bb >= 0 then
			s = skins[bb]
			if not s or s.f ~= fr then s = self:Skin(bb) end
			if s then
				w = m.w3[id]
				x = x + w * (s[1] * px + s[2] * py + s[3] * pz + s[4])
				y = y + w * (s[5] * px + s[6] * py + s[7] * pz + s[8])
				z = z + w * (s[9] * px + s[10] * py + s[11] * pz + s[12])
			end
		end
	end
	cf[id] = self.frame
	self.cx[id], self.cy[id], self.cz[id] = x, y, z
	return x, y, z, true
end

-- World triangle: A, B, C and outward unit normal.
function Pose:Tri(t)
	local m = self.mesh
	-- (a corner worked out earlier in this frame is read where it is kept, without a call:
	-- neighbouring anchors share corners)
	local cf, fr, kx, ky, kz = self.cf, self.frame, self.cx, self.cy, self.cz
	local ia, ib, ic = m.t1[t], m.t2[t], m.t3[t]
	local ax, ay, az, bx, by, bz, cx, cy, cz
	if cf[ia] == fr then ax, ay, az = kx[ia], ky[ia], kz[ia] else ax, ay, az = self:Vertex(ia) end
	if cf[ib] == fr then bx, by, bz = kx[ib], ky[ib], kz[ib] else bx, by, bz = self:Vertex(ib) end
	if cf[ic] == fr then cx, cy, cz = kx[ic], ky[ic], kz[ic] else cx, cy, cz = self:Vertex(ic) end
	local ex, ey, ez = bx - ax, by - ay, bz - az
	local fx, fy, fz = cx - ax, cy - ay, cz - az
	local nx, ny, nz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
	local l = sqrt(nx * nx + ny * ny + nz * nz)
	if l < 1e-9 then l = 1e-9 end
	l = m.tsg[t] / l
	return ax, ay, az, bx, by, bz, cx, cy, cz, nx * l, ny * l, nz * l
end

-- A surface anchor { tri, u, v, mesh }: its bind-space position and normal and the bones it hangs
-- on are computed once (a.px .. a.nz, a.b1: the bone that carries most of it).
-- a.rigid: the bone the point follows rigidly (one bone carries >= 97 % of its weight), or false.
local accB, accW = {}, {}
local function PrepareAnchor(m, a)
	local t, u, v = a[1], a[2], a[3]
	local i1, i2, i3 = m.t1[t], m.t2[t], m.t3[t]
	local w0 = 1 - u - v
	a.px = m.vx[i1] * w0 + m.vx[i2] * u + m.vx[i3] * v
	a.py = m.vy[i1] * w0 + m.vy[i2] * u + m.vy[i3] * v
	a.pz = m.vz[i1] * w0 + m.vz[i2] * u + m.vz[i3] * v
	a.nx, a.ny, a.nz = BM.BindNormal(m, t)
	-- accumulate the bone weights of the three corners (up to 9 entries, merged by bone)
	local n = 0
	local b1, w1, b2, w2, b3, w3 = m.b1, m.w1, m.b2, m.w2, m.b3, m.w3
	for c = 1, 3 do
		local id = (c == 1 and i1) or (c == 2 and i2) or i3
		local k = (c == 1 and w0) or (c == 2 and u) or v
		for s = 1, 3 do
			local b = (s == 1 and b1[id]) or (s == 2 and b2[id]) or b3[id]
			local w = ((s == 1 and w1[id]) or (s == 2 and w2[id]) or w3[id]) * k
			if b >= 0 and w > 0 then
				local found = false
				for j = 1, n do
					if accB[j] == b then accW[j] = accW[j] + w found = true break end
				end
				if not found then n = n + 1 accB[n], accW[n] = b, w end
			end
		end
	end
	-- the three heaviest
	local sb1, sw1, sb2, sw2, sb3, sw3 = -1, 0, -1, 0, -1, 0
	for j = 1, n do
		local b, w = accB[j], accW[j]
		if w > sw1 then sb3, sw3 = sb2, sw2 sb2, sw2 = sb1, sw1 sb1, sw1 = b, w
		elseif w > sw2 then sb3, sw3 = sb2, sw2 sb2, sw2 = b, w
		elseif w > sw3 then sb3, sw3 = b, w end
	end
	if sw2 < 0.01 then sb2, sw2 = -1, 0 end
	if sw3 < 0.01 then sb3, sw3 = -1, 0 end
	local sum = sw1 + sw2 + sw3
	if sum <= 0 then sum = 1 end
	a.b1, a.w1, a.b2, a.w2, a.b3, a.w3 = sb1, sw1 / sum, sb2, sw2 / sum, sb3, sw3 / sum
	a.nb = (sb3 >= 0 and 3) or (sb2 >= 0 and 2) or 1
	a.rigid = (sw1 / sum >= 0.97) and sb1 or false
	a.ready = true
end
BM.PrepareAnchor = PrepareAnchor

-- Where the anchor is in this frame's pose: world x, y, z and the surface normal there. The point
-- of its triangle as the engine draws it: between the triangle's three skinned corners (cached per
-- frame, neighbouring anchors share them). Skinning the point itself with the corners' weights
-- mixed is not the same thing: where the body bends (a ragdoll's trunk) it leaves the surface by
-- tenths of a unit, and what is drawn there sinks into the cloth or floats over it.
function Pose:SkinPoint(a)
	if a.f == self.frame then return a.x, a.y, a.z, a.wnx, a.wny, a.wnz end
	if not a.ready then PrepareAnchor(self.mesh, a) end
	local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = self:Tri(a[1])
	local u, v = a[2], a[3]
	local x, y, z = ax + u * (bx - ax) + v * (cx - ax), ay + u * (by - ay) + v * (cy - ay), az + u * (bz - az) + v * (cz - az)
	a.f, a.x, a.y, a.z, a.wnx, a.wny, a.wnz = self.frame, x, y, z, nx, ny, nz
	return x, y, z, nx, ny, nz
end

-- World point from (tri, u, v)
function Pose:Point(t, u, v)
	local ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz = self:Tri(t)
	return ax + u * (bx - ax) + v * (cx - ax), ay + u * (by - ay) + v * (cy - ay), az + u * (bz - az) + v * (cz - az), nx, ny, nz
end

------------------------------------------------------------------------------------------
-- Closest point on triangle (Ericson). Returns barycentric (u, v) for vertices B and C.
------------------------------------------------------------------------------------------
local function ClosestOnTri(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz)
	local abx, aby, abz = bx - ax, by - ay, bz - az
	local acx, acy, acz = cx - ax, cy - ay, cz - az
	local apx, apy, apz = px - ax, py - ay, pz - az
	local d1 = abx * apx + aby * apy + abz * apz
	local d2 = acx * apx + acy * apy + acz * apz
	if d1 <= 0 and d2 <= 0 then return 0, 0 end
	local bpx, bpy, bpz = px - bx, py - by, pz - bz
	local d3 = abx * bpx + aby * bpy + abz * bpz
	local d4 = acx * bpx + acy * bpy + acz * bpz
	if d3 >= 0 and d4 <= d3 then return 1, 0 end
	local vc = d1 * d4 - d3 * d2
	if vc <= 0 and d1 >= 0 and d3 <= 0 then return d1 / (d1 - d3), 0 end
	local cpx, cpy, cpz = px - cx, py - cy, pz - cz
	local d5 = abx * cpx + aby * cpy + abz * cpz
	local d6 = acx * cpx + acy * cpy + acz * cpz
	if d6 >= 0 and d5 <= d6 then return 0, 1 end
	local vb = d5 * d2 - d1 * d6
	if vb <= 0 and d2 >= 0 and d6 <= 0 then return 0, d2 / (d2 - d6) end
	local va = d3 * d6 - d5 * d4
	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return 1 - w, w
	end
	local denom = 1 / (va + vb + vc)
	return vb * denom, vc * denom
end
BM.ClosestOnTri = ClosestOnTri

-- Outward unit normal of triangle t in bind space.
local function BindNormal(m, t)
	local vx, vy, vz = m.vx, m.vy, m.vz
	local a, b, c = m.t1[t], m.t2[t], m.t3[t]
	local ex, ey, ez = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
	local fx, fy, fz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
	local nx, ny, nz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
	local l = sqrt(nx * nx + ny * ny + nz * nz)
	if l < 1e-9 then return 0, 0, 0 end
	l = m.tsg[t] / l
	return nx * l, ny * l, nz * l
end
BM.BindNormal = BindNormal

-- Closest triangle to the bind-space point (px,py,pz) within maxDist, through the triangle grid.
-- skipShell: ignore that shell. rnx..: only triangles whose normal satisfies n.r >= minDot.
-- Returns tri, u, v, squared distance.
local BIND_MAX = 4096   -- no point of a character's bind pose lies further from its origin (units)
local function Closest(m, px, py, pz, maxDist, skipShell, rnx, rny, rnz, minDot)
	local grid = m.grid
	local vx, vy, vz, t1, t2, t3, shell, tsg = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3, m.shell, m.tsg
	m.stampN = m.stampN + 1
	local sn, stamp = m.stampN, m.stamp
	local best, bu, bv, bd = nil, 0, 0, maxDist * maxDist
	-- A point far outside the model (the inverse of a bone that has been scaled away blows a
	-- position up beyond all bounds), or no number at all: nothing of the mesh is near it. This is
	-- also what keeps the cell loops below finite.
	if not (px > -BIND_MAX and px < BIND_MAX and py > -BIND_MAX and py < BIND_MAX and pz > -BIND_MAX and pz < BIND_MAX) then return nil, 0, 0, bd end
	local x0, x1 = floor((px - maxDist) / GRID), floor((px + maxDist) / GRID)
	local y0, y1 = floor((py - maxDist) / GRID), floor((py + maxDist) / GRID)
	local z0, z1 = floor((pz - maxDist) / GRID), floor((pz + maxDist) / GRID)
	for gx = x0, x1 do
		for gy = y0, y1 do
			for gz = z0, z1 do
				local l = grid[GridKey(gx, gy, gz)]
				if l then
					for i = 1, #l do
						local t = l[i]
						if stamp[t] ~= sn then
							stamp[t] = sn
							if shell[t] ~= skipShell then
								local a, b, c = t1[t], t2[t], t3[t]
								local ok = true
								if rnx then
									local ex, ey, ez = vx[b] - vx[a], vy[b] - vy[a], vz[b] - vz[a]
									local fx, fy, fz = vx[c] - vx[a], vy[c] - vy[a], vz[c] - vz[a]
									local cx, cy, cz = ey * fz - ez * fy, ez * fx - ex * fz, ex * fy - ey * fx
									local cl = sqrt(cx * cx + cy * cy + cz * cz)
									ok = cl > 1e-9 and (cx * rnx + cy * rny + cz * rnz) * tsg[t] / cl >= minDot
								end
								if ok then
									local u, v = ClosestOnTri(px, py, pz, vx[a], vy[a], vz[a], vx[b], vy[b], vz[b], vx[c], vy[c], vz[c])
									local qx = vx[a] + u * (vx[b] - vx[a]) + v * (vx[c] - vx[a])
									local qy = vy[a] + u * (vy[b] - vy[a]) + v * (vy[c] - vy[a])
									local qz = vz[a] + u * (vz[b] - vz[a]) + v * (vz[c] - vz[a])
									local d = (qx - px) ^ 2 + (qy - py) ^ 2 + (qz - pz) ^ 2
									if d < bd then best, bu, bv, bd = t, u, v, d end
								end
							end
						end
					end
				end
			end
		end
	end
	return best, bu, bv, bd
end
BM.Closest = Closest

-- Nudge barycentrics off exact edges/vertices so edge crossing logic starts inside the triangle.
local function Inset(u, v)
	local eps = 0.02
	if u < eps then u = eps end
	if v < eps then v = eps end
	if 1 - u - v < eps then local s2 = (1 - eps) / (u + v) u, v = u * s2, v * s2 end
	return u, v
end

-- Blood that reaches an open edge of one mesh piece (a zipper strip, a clothing layer, a pocket)
-- continues on another piece right across the gap, if one faces roughly the same way.
local INV_S = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }   -- the inverse of a skin matrix, used on the spot
function BM.Bridge(pose, bone, wx, wy, wz, fromTri, maxDist)
	local m = pose.mesh
	if not m or not m.ready or not m.grid then return nil end
	local s = pose:Skin(bone)
	if not s then return nil end
	local px, py, pz = Xform(Invert(s, INV_S), wx, wy, wz)
	local rnx, rny, rnz = BindNormal(m, fromTri)
	local t, u, v, d2 = Closest(m, px, py, pz, maxDist, m.shell[fromTri], rnx, rny, rnz, -0.35)
	if not t then return nil end
	u, v = Inset(u, v)
	return t, u, v, sqrt(d2)
end

-- Möller–Trumbore ray / triangle test. Returns t, u, v (u, v: weights of B and C) or nil.
local function RayTri(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, cx, cy, cz)
	local e1x, e1y, e1z = bx - ax, by - ay, bz - az
	local e2x, e2y, e2z = cx - ax, cy - ay, cz - az
	local px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
	local det = e1x * px + e1y * py + e1z * pz
	if det > -1e-9 and det < 1e-9 then return nil end
	local inv = 1 / det
	local tx, ty, tz = ox - ax, oy - ay, oz - az
	local u = (tx * px + ty * py + tz * pz) * inv
	if u < 0 or u > 1 then return nil end
	local qx, qy, qz = ty * e1z - tz * e1y, tz * e1x - tx * e1z, tx * e1y - ty * e1x
	local v = (dx * qx + dy * qy + dz * qz) * inv
	if v < 0 or u + v > 1 then return nil end
	return (e2x * qx + e2y * qy + e2z * qz) * inv, u, v
end

-- The outermost outward-facing surface along direction (dx,dy,dz) (world) through a point: a wound
-- belongs on the jacket, not on the shirt under it or the inside of a collar. A ray is cast from
-- `reach` units outside inward, a little past the point. Returns tri, u, v or nil.
function BM.AnchorOuter(pose, bone, wx, wy, wz, dx, dy, dz, reach)
	local m = pose.mesh
	if not m or not m.ready or not m.grid then return nil end
	local s = pose:Skin(bone)
	if not s then return nil end
	local inv = Invert(s, INV_S)
	local px, py, pz = Xform(inv, wx, wy, wz)
	local ddx = inv[1] * dx + inv[2] * dy + inv[3] * dz
	local ddy = inv[5] * dx + inv[6] * dy + inv[7] * dz
	local ddz = inv[9] * dx + inv[10] * dy + inv[11] * dz
	local l = sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
	if l < 1e-6 then return nil end
	ddx, ddy, ddz = ddx / l, ddy / l, ddz / l
	if not (px > -BIND_MAX and px < BIND_MAX and py > -BIND_MAX and py < BIND_MAX and pz > -BIND_MAX and pz < BIND_MAX) then return nil end
	local ox, oy, oz = px + ddx * reach, py + ddy * reach, pz + ddz * reach
	local ex, ey, ez = px - ddx * reach * 0.5, py - ddy * reach * 0.5, pz - ddz * reach * 0.5
	local vx, vy, vz, t1, t2, t3 = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3
	m.stampN = m.stampN + 1
	local sn, stamp, grid = m.stampN, m.stamp, m.grid
	local best, bu, bv, bt = nil, 0, 0, reach * 1.5
	for gx = floor((min(ox, ex) - 0.5) / GRID), floor((max(ox, ex) + 0.5) / GRID) do
		for gy = floor((min(oy, ey) - 0.5) / GRID), floor((max(oy, ey) + 0.5) / GRID) do
			for gz = floor((min(oz, ez) - 0.5) / GRID), floor((max(oz, ez) + 0.5) / GRID) do
				local list = grid[GridKey(gx, gy, gz)]
				if list then
					for i = 1, #list do
						local t = list[i]
						if stamp[t] ~= sn then
							stamp[t] = sn
							local nx, ny, nz = BindNormal(m, t)
							if nx * ddx + ny * ddy + nz * ddz > 0.2 then
								local a, b, c = t1[t], t2[t], t3[t]
								local ht, u, v = RayTri(ox, oy, oz, -ddx, -ddy, -ddz, vx[a], vy[a], vz[a], vx[b], vy[b], vz[b], vx[c], vy[c], vz[c])
								if ht and ht >= 0 and ht < bt then best, bu, bv, bt = t, u, v, ht end
							end
						end
					end
				end
			end
		end
	end
	if not best then return nil end
	bu, bv = Inset(bu, bv)
	return best, bu, bv
end

-- Anchor a world point to the mesh near `bone`. Works in bind space so no skinning is needed
-- for the search. Returns tri, u, v, distance (bind units) or nil.
function BM.Anchor(pose, bone, wx, wy, wz, maxDist)
	local m = pose.mesh
	if not m or not m.ready then return nil end
	local s = pose:Skin(bone)
	if not s then return nil end
	local inv = Invert(s, INV_S)
	local px, py, pz = Xform(inv, wx, wy, wz)
	-- the triangle grid finds the nearest surface in a few cells: first close by, then wider
	if m.grid then
		local md = maxDist or 12
		local t, u, v, d = Closest(m, px, py, pz, math.min(md, 2.4))
		if not t and md > 2.4 then t, u, v, d = Closest(m, px, py, pz, math.min(md, 7)) end
		if t then
			u, v = Inset(u, v)
			return t, u, v, sqrt(d)
		end
		if md <= 7 then return nil end
	end
	local best, bu, bv, bd = nil, 0, 0, (maxDist or 12) ^ 2

	local function Scan(list)
		if not list then return end
		local vx, vy, vz, t1, t2, t3 = m.vx, m.vy, m.vz, m.t1, m.t2, m.t3
		local tcx, tcy, tcz = m.tcx, m.tcy, m.tcz
		for i = 1, #list do
			local t = list[i]
			local dx, dy, dz = tcx[t] - px, tcy[t] - py, tcz[t] - pz
			if dx * dx + dy * dy + dz * dz < bd + 36 then
				local a, b, c = t1[t], t2[t], t3[t]
				local u, v = ClosestOnTri(px, py, pz, vx[a], vy[a], vz[a], vx[b], vy[b], vz[b], vx[c], vy[c], vz[c])
				local qx = vx[a] + u * (vx[b] - vx[a]) + v * (vx[c] - vx[a])
				local qy = vy[a] + u * (vy[b] - vy[a]) + v * (vy[c] - vy[a])
				local qz = vz[a] + u * (vz[b] - vz[a]) + v * (vz[c] - vz[a])
				local d = (qx - px) ^ 2 + (qy - py) ^ 2 + (qz - pz) ^ 2
				if d < bd then best, bu, bv, bd = t, u, v, d end
			end
		end
	end
	Scan(m.boneTris[bone])
	if not best then
		-- the point may sit on a triangle dominated by a neighbouring bone
		if m.grid then
			local t, u, v, d = Closest(m, px, py, pz, maxDist or 12)
			if t then best, bu, bv, bd = t, u, v, d end
		else
			for _, list in pairs(m.boneTris) do Scan(list) end
		end
	end
	if not best then return nil end
	bu, bv = Inset(bu, bv)
	return best, bu, bv, sqrt(bd)
end

-- All triangles with a corner within `r` of bind-space point (px,py,pz) (through the grid).
function BM.TrisNear(m, px, py, pz, r)
	local out = {}
	if not m or not m.grid then return out end
	if not (px > -BIND_MAX and px < BIND_MAX and py > -BIND_MAX and py < BIND_MAX and pz > -BIND_MAX and pz < BIND_MAX and r < BIND_MAX) then return out end
	local grid, vx, vy, vz, t1, t2, t3 = m.grid, m.vx, m.vy, m.vz, m.t1, m.t2, m.t3
	m.stampN = m.stampN + 1
	local sn, stamp = m.stampN, m.stamp
	local r2 = r * r
	for gx = floor((px - r) / GRID), floor((px + r) / GRID) do
		for gy = floor((py - r) / GRID), floor((py + r) / GRID) do
			for gz = floor((pz - r) / GRID), floor((pz + r) / GRID) do
				local l = grid[GridKey(gx, gy, gz)]
				if l then
					for i = 1, #l do
						local t = l[i]
						if stamp[t] ~= sn then
							stamp[t] = sn
							for _, id in ipairs({ t1[t], t2[t], t3[t] }) do
								local dx, dy, dz = vx[id] - px, vy[id] - py, vz[id] - pz
								if dx * dx + dy * dy + dz * dz < r2 then out[#out + 1] = t break end
							end
						end
					end
				end
			end
		end
	end
	return out
end

-- Bind-space point of an anchor (tri, u, v) and a world direction expressed in bind space at `bone`.
function BM.BindPoint(m, t, u, v)
	local a, b, c = m.t1[t], m.t2[t], m.t3[t]
	local w = 1 - u - v
	return m.vx[a] * w + m.vx[b] * u + m.vx[c] * v, m.vy[a] * w + m.vy[b] * u + m.vy[c] * v, m.vz[a] * w + m.vz[b] * u + m.vz[c] * v
end
function BM.WorldDirToBind(pose, bone, dx, dy, dz)
	local s = pose:Skin(bone)
	if not s then return nil end
	local inv = Invert(s, INV_S)
	return inv[1] * dx + inv[2] * dy + inv[3] * dz, inv[5] * dx + inv[6] * dy + inv[7] * dz, inv[9] * dx + inv[10] * dy + inv[11] * dz
end

------------------------------------------------------------------------------------------
-- Hitbox proxies (for droplet vs body collisions): cached per model.
------------------------------------------------------------------------------------------
BM.hitboxes = BM.hitboxes or {}
function BM.Hitboxes(ent)
	local model = ent:GetModel()
	if not model then return nil end
	local hb = BM.hitboxes[model]
	if hb then return hb end
	hb = {}
	local set = ent:GetHitboxSet() or 0
	for i = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
		local bone = ent:GetHitBoxBone(i, set)
		local mins, maxs = ent:GetHitBoxBounds(i, set)
		if bone and mins and maxs then
			hb[#hb + 1] = { bone = bone, x0 = mins.x, y0 = mins.y, z0 = mins.z, x1 = maxs.x, y1 = maxs.y, z1 = maxs.z }
		end
	end
	BM.hitboxes[model] = hb
	return hb
end

-- How far a place in a bone's space lies outside that bone's hitbox (0: inside it), and the
-- nearest place inside it. A bone without a hitbox: a ball of 8 units round its origin.
-- (Z-City books a wound whose bone it does not know on a bone drawn at random, at the offset of
-- the true place from that bone: such a place is not on the part it names, and as the body moves
-- it swings through the air beside it.)
function BM.OffBone(ent, bone, x, y, z)
	local hbs = BM.Hitboxes(ent)
	local best, bx, by, bz
	for i = 1, hbs and #hbs or 0 do
		local h = hbs[i]
		if h.bone == bone then
			local cx = x < h.x0 and h.x0 or (x > h.x1 and h.x1 or x)
			local cy = y < h.y0 and h.y0 or (y > h.y1 and h.y1 or y)
			local cz = z < h.z0 and h.z0 or (z > h.z1 and h.z1 or z)
			local d = sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2)
			if not best or d < best then best, bx, by, bz = d, cx, cy, cz end
		end
	end
	if best then return best, bx, by, bz end
	local l = sqrt(x * x + y * y + z * z)
	if l <= 8 then return 0, x, y, z end
	return l - 8, x * 8 / l, y * 8 / l, z * 8 / l
end

-- Segment (p0 -> p1) against the entity's hitboxes. Segments that START inside a box ignore it
-- (blood emitted from a wound starts inside the wound's hitbox). Returns bone, t, hit point.
function BM.SegmentHitboxes(pose, ent, x0, y0, z0, x1, y1, z1)
	local hbs = BM.Hitboxes(ent)
	if not hbs then return nil end
	-- once per frame: each hitbox's centre in world space and bounding radius, so most boxes are
	-- rejected with a sphere test before the exact slab test
	if pose.hbFrame ~= pose.frame or pose.hbEnt ~= ent then
		pose.hbFrame, pose.hbEnt = pose.frame, ent
		local cx, cy, cz, cr = pose.hbx or {}, pose.hby or {}, pose.hbz or {}, pose.hbr or {}
		pose.hbx, pose.hby, pose.hbz, pose.hbr = cx, cy, cz, cr
		for i = 1, #hbs do
			local h = hbs[i]
			local e = pose:Bone(h.bone)
			if e then
				local mx, my, mz = (h.x0 + h.x1) * 0.5, (h.y0 + h.y1) * 0.5, (h.z0 + h.z1) * 0.5
				cx[i] = e[1] * mx + e[2] * my + e[3] * mz + e[4]
				cy[i] = e[5] * mx + e[6] * my + e[7] * mz + e[8]
				cz[i] = e[9] * mx + e[10] * my + e[11] * mz + e[12]
				cr[i] = 0.5 * sqrt((h.x1 - h.x0) ^ 2 + (h.y1 - h.y0) ^ 2 + (h.z1 - h.z0) ^ 2)
			else
				cx[i] = false
			end
		end
	end
	local hx, hy, hz, hr = pose.hbx, pose.hby, pose.hbz, pose.hbr
	local smx, smy, smz = (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5
	local sr = 0.5 * sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2)
	local bestT, bestBone = 2, nil
	for i = 1, #hbs do
		local h = hbs[i]
		local inv
		local c = hx[i]
		if c then
			local dx, dy, dz = c - smx, hy[i] - smy, hz[i] - smz
			local rr = hr[i] + sr
			if dx * dx + dy * dy + dz * dz < rr * rr then inv = pose:BoneInv(h.bone) end
		end
		if inv then
			local ax, ay, az = Xform(inv, x0, y0, z0)
			local bx, by, bz = Xform(inv, x1, y1, z1)
			local inside = ax > h.x0 and ax < h.x1 and ay > h.y0 and ay < h.y1 and az > h.z0 and az < h.z1
			if not inside then
				local dx, dy, dz = bx - ax, by - ay, bz - az
				local tmin, tmax = 0, 1
				local ok = true
				-- slab test
				if abs(dx) < 1e-9 then
					if ax < h.x0 or ax > h.x1 then ok = false end
				else
					local t1, t2 = (h.x0 - ax) / dx, (h.x1 - ax) / dx
					if t1 > t2 then t1, t2 = t2, t1 end
					tmin, tmax = max(tmin, t1), min(tmax, t2)
				end
				if ok and tmin <= tmax then
					if abs(dy) < 1e-9 then
						if ay < h.y0 or ay > h.y1 then ok = false end
					else
						local t1, t2 = (h.y0 - ay) / dy, (h.y1 - ay) / dy
						if t1 > t2 then t1, t2 = t2, t1 end
						tmin, tmax = max(tmin, t1), min(tmax, t2)
					end
				end
				if ok and tmin <= tmax then
					if abs(dz) < 1e-9 then
						if az < h.z0 or az > h.z1 then ok = false end
					else
						local t1, t2 = (h.z0 - az) / dz, (h.z1 - az) / dz
						if t1 > t2 then t1, t2 = t2, t1 end
						tmin, tmax = max(tmin, t1), min(tmax, t2)
					end
				end
				if ok and tmin <= tmax and tmin < bestT then bestT, bestBone = tmin, h.bone end
			end
		end
	end
	if not bestBone then return nil end
	return bestBone, bestT, x0 + (x1 - x0) * bestT, y0 + (y1 - y0) * bestT, z0 + (z1 - z0) * bestT
end

function BM.Clear()
	BM.cache = {}
	jobs = {}
end
