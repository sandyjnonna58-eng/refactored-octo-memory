-- What a path through a body meets. The interface a ballistic system asks; it simulates nothing.
--
-- Bones are stood for by proxies: simple solids measured on the stock model's own pieces by the
-- generator (capsules along long bones, boxes for plates, ellipsoids for lumps), and for the skull
-- its outside as a shell with the regions of its bones. They are kept apart from what is drawn: a
-- server has no meshes, and a query should not cost what a mesh costs. How well each kind of
-- proxy agrees with the mesh it stands for is in the generator's report
-- (tools/harness/results/skeleton_generator_report_*.txt) and in docs/SKELETON_PHASE2.md.
--
-- A path is a straight segment in the world. It is carried into each bone's rest pose (the inverse
-- of the bone's matrix: sh_pose.lua), where the proxies are, so the proxies never move.
--
--   SK.Trace(who, a, b, opts)   -> list of { id, idx, tIn, tOut, kind, thick, exit }, nearest first.
--        who: a body (entity) or a pose; a, b: Vectors or { x, y, z }.
--        tIn, tOut: where along the segment (0 at a, 1 at b) the bone is entered and left.
--        kind: "proxy", or "shell" for a bone of the skull (thick: that bone's thickness in units,
--        an assumed number; exit: true for the place the path leaves the skull again).
--        opts.bones: a list of ids to ask about and no others; opts.first: stop at the nearest.
--   SK.Nearest(who, a, b, bones) -> the id of the bone of the list whose proxy comes nearest the path, and how near.
--   SK.Cranial.*                 the skull: which bone a place or a direction of the head is.

local SK = HemoSkeleton
local M, P, ST = SK.M, SK.Pose, SK.Stock
local sqrt, abs, max, min, floor = math.sqrt, math.abs, math.max, math.min, math.floor
SK.Proxy = SK.Proxy or {}
SK.Cranial = SK.Cranial or {}
local X, CR = SK.Proxy, SK.Cranial

------------------------------------------------------------------------------------------
-- A segment against one solid, both in the rest pose. Returns tIn, tOut or nil.
-- The same arithmetic as tools/offline/SkelGenProxy.cs (the offline check compares the two).
------------------------------------------------------------------------------------------
local function SegBall(px, py, pz, dx, dy, dz, cx, cy, cz, r)
	local mx, my, mz = px - cx, py - cy, pz - cz
	local A = dx * dx + dy * dy + dz * dz
	if A < 1e-18 then return nil end
	local B = 2 * (mx * dx + my * dy + mz * dz)
	local C = mx * mx + my * my + mz * mz - r * r
	local disc = B * B - 4 * A * C
	if disc < 0 then return nil end
	local sq = sqrt(disc)
	local ta, tb = (-B - sq) / (2 * A), (-B + sq) / (2 * A)
	if tb < 0 or ta > 1 then return nil end
	return max(ta, 0), min(tb, 1)
end

local function SegShape(s, px, py, pz, qx, qy, qz)
	local kind = s[1]
	local dx, dy, dz = qx - px, qy - py, qz - pz
	if kind == "c" then
		local ax, ay, az, bx, by, bz, r = s[2], s[3], s[4], s[5], s[6], s[7], s[8]
		local lo, hi = 2, -1
		local t0, t1 = SegBall(px, py, pz, dx, dy, dz, ax, ay, az, r)
		if t0 then lo, hi = t0, t1 end
		local ux, uy, uz = bx - ax, by - ay, bz - az
		local L = sqrt(ux * ux + uy * uy + uz * uz)
		if L > 1e-9 then
			t0, t1 = SegBall(px, py, pz, dx, dy, dz, bx, by, bz, r)
			if t0 then if t0 < lo then lo = t0 end if t1 > hi then hi = t1 end end
			ux, uy, uz = ux / L, uy / L, uz / L
			local mx, my, mz = px - ax, py - ay, pz - az
			local md, dd = mx * ux + my * uy + mz * uz, dx * ux + dy * uy + dz * uz
			local mpx, mpy, mpz = mx - ux * md, my - uy * md, mz - uz * md
			local dpx, dpy, dpz = dx - ux * dd, dy - uy * dd, dz - uz * dd
			local A = dpx * dpx + dpy * dpy + dpz * dpz
			local B = 2 * (mpx * dpx + mpy * dpy + mpz * dpz)
			local C = mpx * mpx + mpy * mpy + mpz * mpz - r * r
			local ta, tb, any = 0, 0, false
			if A < 1e-18 then
				if C <= 0 then ta, tb, any = 0, 1, true end
			else
				local disc = B * B - 4 * A * C
				if disc >= 0 then
					local sq = sqrt(disc)
					ta, tb, any = (-B - sq) / (2 * A), (-B + sq) / (2 * A), true
				end
			end
			if any then
				-- between the two end planes
				if abs(dd) < 1e-12 then
					if md < 0 or md > L then any = false end
				else
					local pa, pb = (0 - md) / dd, (L - md) / dd
					if pa > pb then pa, pb = pb, pa end
					if pa > ta then ta = pa end
					if pb < tb then tb = pb end
				end
				if any then
					if ta < 0 then ta = 0 end
					if tb > 1 then tb = 1 end
					if ta <= tb then
						if ta < lo then lo = ta end
						if tb > hi then hi = tb end
					end
				end
			end
		end
		if hi < lo then return nil end
		return lo, hi
	end
	-- a box or an ellipsoid: centre, three axes, three half sizes
	local ox, oy, oz = px - s[2], py - s[3], pz - s[4]
	local o1, o2, o3 = ox * s[5] + oy * s[6] + oz * s[7], ox * s[8] + oy * s[9] + oz * s[10], ox * s[11] + oy * s[12] + oz * s[13]
	local d1, d2, d3 = dx * s[5] + dy * s[6] + dz * s[7], dx * s[8] + dy * s[9] + dz * s[10], dx * s[11] + dy * s[12] + dz * s[13]
	local h1, h2, h3 = s[14], s[15], s[16]
	if kind == "e" then
		-- in the frame in which it is a ball of radius one
		return SegBall(o1 / h1, o2 / h2, o3 / h3, d1 / h1, d2 / h2, d3 / h3, 0, 0, 0, 1)
	end
	local t0, t1 = 0, 1
	if abs(d1) < 1e-12 then if o1 < -h1 or o1 > h1 then return nil end
	else
		local ta, tb = (-h1 - o1) / d1, (h1 - o1) / d1
		if ta > tb then ta, tb = tb, ta end
		if ta > t0 then t0 = ta end
		if tb < t1 then t1 = tb end
		if t0 > t1 then return nil end
	end
	if abs(d2) < 1e-12 then if o2 < -h2 or o2 > h2 then return nil end
	else
		local ta, tb = (-h2 - o2) / d2, (h2 - o2) / d2
		if ta > tb then ta, tb = tb, ta end
		if ta > t0 then t0 = ta end
		if tb < t1 then t1 = tb end
		if t0 > t1 then return nil end
	end
	if abs(d3) < 1e-12 then if o3 < -h3 or o3 > h3 then return nil end
	else
		local ta, tb = (-h3 - o3) / d3, (h3 - o3) / d3
		if ta > tb then ta, tb = tb, ta end
		if ta > t0 then t0 = ta end
		if tb < t1 then t1 = tb end
		if t0 > t1 then return nil end
	end
	return t0, t1
end
X.SegShape = SegShape

------------------------------------------------------------------------------------------
-- The bones that have proxies, and the ball each one's proxy lies in (rest pose)
------------------------------------------------------------------------------------------
X.list, X.ball = {}, {}
X.shellBones = {}
for _, b in ipairs(SK.BoneList) do
	local st = ST.bones[b.id]
	if st and type(st.proxy) == "table" then
		local c = st.c
		local r = 0
		for _, s in ipairs(st.proxy) do
			local d
			if s[1] == "c" then
				d = max(sqrt((s[2] - c[1]) ^ 2 + (s[3] - c[2]) ^ 2 + (s[4] - c[3]) ^ 2), sqrt((s[5] - c[1]) ^ 2 + (s[6] - c[2]) ^ 2 + (s[7] - c[3]) ^ 2)) + s[8]
			else
				d = sqrt((s[2] - c[1]) ^ 2 + (s[3] - c[2]) ^ 2 + (s[4] - c[3]) ^ 2) + sqrt(s[14] ^ 2 + s[15] ^ 2 + s[16] ^ 2)
			end
			if d > r then r = d end
		end
		X.list[#X.list + 1] = b.id
		X.ball[b.id] = r
	elseif st and st.proxy == "shell" then
		X.shellBones[b.id] = true
	end
end

------------------------------------------------------------------------------------------
-- The skull. Places are in the head frame about the brain's centre (the brain module's own rule,
-- lua/neurotrauma/sv_zcity.lua): side (the character's left positive), face, up; in units.
------------------------------------------------------------------------------------------
local seeds = ST.cranial.seeds
local shell = ST.cranial.shell
local SN, SM = shell.n, shell.m
local PI = math.pi

-- The bone whose region of the skull's outside a place belongs to (the nearest seed's). only: a
-- set of ids to choose among (the bones of the braincase, for what lies under the skull).
function CR.BoneAt(x, y, z, only)
	local best, bd
	for i = 1, #seeds do
		local s = seeds[i]
		if not only or only[s[1]] then
			local d = (x - s[2]) ^ 2 + (y - s[3]) ^ 2 + (z - s[4]) ^ 2
			if not bd or d < bd then best, bd = s[1], d end
		end
	end
	return best
end

-- How far out the skull's outside is along the direction of (x, y, z) from the brain's centre.
function CR.Radius(x, y, z)
	local l = sqrt(x * x + y * y + z * z)
	if l < 1e-9 then return 0 end
	local el = math.asin(max(-1, min(1, z / l)))
	local az = math.atan2(x, y)
	if az < 0 then az = az + 2 * PI end
	local fi, fj = (el + PI / 2) / PI * (SM - 1), az / (2 * PI) * SN
	local i0 = floor(fi)
	if i0 > SM - 2 then i0 = SM - 2 end
	if i0 < 0 then i0 = 0 end
	local j0 = floor(fj) % SN
	local j1 = (j0 + 1) % SN
	local wi, wj = fi - i0, fj - floor(fj)
	local r00, r01 = shell[i0 * SN + j0 + 1], shell[i0 * SN + j1 + 1]
	local r10, r11 = shell[(i0 + 1) * SN + j0 + 1], shell[(i0 + 1) * SN + j1 + 1]
	return (r00 * (1 - wj) + r01 * wj) * (1 - wi) + (r10 * (1 - wj) + r11 * wj) * wi
end

-- The place on the skull's outside along a direction from the brain's centre, and its bone.
-- (What a blow is to the brain module: its events carry the direction of the hit in this frame.)
function CR.FromDir(x, y, z, only)
	local l = sqrt(x * x + y * y + z * z)
	if l < 1e-9 then return nil end
	local r = CR.Radius(x, y, z)
	local sx, sy, sz = x / l * r, y / l * r, z / l * r
	return CR.BoneAt(sx, sy, sz, only), sx, sy, sz
end

-- The thickness assumed for a skull bone (units).
function CR.Thick(id)
	local base = string.gsub(id, "_[lr]$", "")
	return ST.cranial.thick[base] or 0.3
end

-- The head frame in the reference rig's rest pose: the brain's centre and the three directions.
do
	local m = ST.restInv.head          -- bone -> model
	local ux, uy, uz = M.Rot(m, 1, 0, 0)            -- up: the bone's first axis
	local fx, fy, fz = M.Rot(m, 0, -1, 0)           -- face: minus its second
	local lx, ly, lz = M.Rot(m, 0, 0, 1)            -- left: its third, by the side the left collar bone is on
	local jl, jr = ST.joint.clavicle_l, ST.joint.clavicle_r
	if (jl[1] - jr[1]) * lx + (jl[2] - jr[2]) * ly + (jl[3] - jr[3]) * lz < 0 then lx, ly, lz = -lx, -ly, -lz end
	local hx, hy, hz = m[4], m[8], m[12]
	local up, face = ST.head.up, ST.head.face
	CR.rest = {
		c = { hx + ux * up + fx * face, hy + uy * up + fy * face, hz + uz * up + fz * face },
		up = { ux, uy, uz }, face = { fx, fy, fz }, left = { lx, ly, lz },
	}
end
-- a place of the rest pose in the head frame, and back
function CR.ToHead(x, y, z)
	local h = CR.rest
	local dx, dy, dz = x - h.c[1], y - h.c[2], z - h.c[3]
	return dx * h.left[1] + dy * h.left[2] + dz * h.left[3], dx * h.face[1] + dy * h.face[2] + dz * h.face[3], dx * h.up[1] + dy * h.up[2] + dz * h.up[3]
end
function CR.FromHead(s, f, u)
	local h = CR.rest
	return h.c[1] + h.left[1] * s + h.face[1] * f + h.up[1] * u, h.c[2] + h.left[2] * s + h.face[2] * f + h.up[2] * u, h.c[3] + h.left[3] * s + h.face[3] * f + h.up[3] * u
end

-- A segment of the rest pose against the shell. Returns tIn, the bone entered, tOut, the bone left
-- by (tOut nil: it ends inside); nil: it does not meet the skull.
local function SegShell(px, py, pz, qx, qy, qz)
	local ax, ay, az = CR.ToHead(px, py, pz)
	local bx, by, bz = CR.ToHead(qx, qy, qz)
	local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2 + (bz - az) ^ 2)
	local steps = max(8, math.ceil(len / SK.Config.ShellStep))
	local function F(t)
		local x, y, z = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
		return sqrt(x * x + y * y + z * z) - CR.Radius(x, y, z), x, y, z
	end
	-- where the sign changes between two steps, to a fine point
	local function Cross(lo, hi, inside)
		for _ = 1, 12 do
			local mid = (lo + hi) / 2
			if (F(mid) <= 0) == inside then hi = mid else lo = mid end
		end
		return hi
	end
	local tIn, bIn
	local f0, x0, y0, z0 = F(0)
	local from = 0
	if f0 <= 0 then
		tIn, bIn = 0, CR.BoneAt(x0, y0, z0)
	else
		for i = 1, steps do
			local t = i / steps
			if F(t) <= 0 then
				tIn = Cross((i - 1) / steps, t, true)
				local _, x, y, z = F(tIn)
				bIn = CR.BoneAt(x, y, z)
				from = i
				break
			end
		end
	end
	if not tIn then return nil end
	for i = max(from, 1), steps do
		local t = i / steps
		if t > tIn and F(t) > 0 then
			local tOut = Cross(max((i - 1) / steps, tIn), t, false)
			local _, x, y, z = F(tOut)
			return tIn, bIn, tOut, CR.BoneAt(x, y, z)
		end
	end
	return tIn, bIn, nil, nil
end
X.SegShell = SegShell

------------------------------------------------------------------------------------------
-- Tracing
------------------------------------------------------------------------------------------
local function XYZ(v)
	if type(v) == "table" then return v[1], v[2], v[3] end
	return v.x, v.y, v.z
end

local function PoseFor(who)
	if type(who) == "table" and who.Bone then return who end
	return SK.PoseOf(who)
end

local function ByT(a, b) return a.tIn < b.tIn end

function SK.Trace(who, a, b, opts)
	local pose, why = PoseFor(who)
	if not pose then return nil, why end
	local ax, ay, az = XYZ(a)
	local bx, by, bz = XYZ(b)
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local len2 = dx * dx + dy * dy + dz * dz
	local hits = {}
	if len2 < 1e-12 then return hits end
	local list = opts and opts.bones or X.list
	local skull = false
	for i = 1, #list do
		local id = list[i]
		local ball = X.ball[id]
		if ball then
			local m = pose:Bone(id)
			if m then
				local st = ST.bones[id]
				-- the ball the proxy lies in, against the segment
				local cx, cy, cz = M.Xf(m, st.c[1], st.c[2], st.c[3])
				local t = ((cx - ax) * dx + (cy - ay) * dy + (cz - az) * dz) / len2
				if t < 0 then t = 0 elseif t > 1 then t = 1 end
				local ex, ey, ez = ax + dx * t - cx, ay + dy * t - cy, az + dz * t - cz
				local reach = ball * M.Scale(m)
				if ex * ex + ey * ey + ez * ez <= reach * reach then
					local inv = pose:BoneInv(id)
					if inv then
						local px, py, pz = M.Xf(inv, ax, ay, az)
						local qx, qy, qz = M.Xf(inv, bx, by, bz)
						local lo, hi
						for _, s in ipairs(st.proxy) do
							local t0, t1 = SegShape(s, px, py, pz, qx, qy, qz)
							if t0 then
								if not lo or t0 < lo then lo = t0 end
								if not hi or t1 > hi then hi = t1 end
							end
						end
						if lo then hits[#hits + 1] = { id = id, idx = SK.Bones[id].idx, tIn = lo, tOut = hi, kind = "proxy" } end
					end
				end
			end
		elseif X.shellBones[id] then
			skull = true
		end
	end
	-- the skull: once, for all its bones (asked for when the list has any of them, or is everything)
	if skull or not (opts and opts.bones) then
		local m = pose:Skin("head")
		local inv = m and M.Inv(m)
		if inv then
			local px, py, pz = M.Xf(inv, ax, ay, az)
			local qx, qy, qz = M.Xf(inv, bx, by, bz)
			local tIn, bIn, tOut, bOut = SegShell(px, py, pz, qx, qy, qz)
			if tIn then
				local len = sqrt(len2) / max(M.Scale(m), 1e-6)
				local want
				if opts and opts.bones then want = {} for _, id in ipairs(opts.bones) do want[id] = true end end
				local function Add(id, t0, isExit)
					if want and not want[id] then return end
					local thick = CR.Thick(id)
					local dt = thick / max(len, 1e-6)
					hits[#hits + 1] = { id = id, idx = SK.Bones[id].idx, tIn = isExit and max(t0 - dt, 0) or t0, tOut = isExit and t0 or min(t0 + dt, 1), kind = "shell", thick = thick, exit = isExit or nil }
				end
				Add(bIn, tIn, false)
				if tOut then Add(bOut, tOut, true) end
			end
		end
	end
	table.sort(hits, ByT)
	if opts and opts.first and #hits > 1 then return { hits[1] } end
	return hits
end

-- The bone of a list whose proxy comes nearest a path that crosses none of them: by the distance
-- from the path to the middle line of each proxy, less its thickness. Returns id, distance.
function SK.Nearest(who, a, b, bones)
	local pose = PoseFor(who)
	if not pose then return nil end
	local ax, ay, az = XYZ(a)
	local bx, by, bz = XYZ(b)
	local best, bd
	for _, id in ipairs(bones) do
		local st = ST.bones[id]
		local inv = st and type(st.proxy) == "table" and pose:BoneInv(id)
		if inv then
			local px, py, pz = M.Xf(inv, ax, ay, az)
			local qx, qy, qz = M.Xf(inv, bx, by, bz)
			local dx, dy, dz = qx - px, qy - py, qz - pz
			local l2 = dx * dx + dy * dy + dz * dz
			for _, s in ipairs(st.proxy) do
				-- a few places along the solid's middle line against the segment
				local cx0, cy0, cz0, cx1, cy1, cz1, r
				if s[1] == "c" then cx0, cy0, cz0, cx1, cy1, cz1, r = s[2], s[3], s[4], s[5], s[6], s[7], s[8]
				else cx0, cy0, cz0, cx1, cy1, cz1, r = s[2] - s[5] * s[14], s[3] - s[6] * s[14], s[4] - s[7] * s[14], s[2] + s[5] * s[14], s[3] + s[6] * s[14], s[4] + s[7] * s[14], (s[15] + s[16]) / 2 end
				for k = 0, 4 do
					local cx, cy, cz = cx0 + (cx1 - cx0) * k / 4, cy0 + (cy1 - cy0) * k / 4, cz0 + (cz1 - cz0) * k / 4
					local t = l2 > 1e-12 and ((cx - px) * dx + (cy - py) * dy + (cz - pz) * dz) / l2 or 0
					if t < 0 then t = 0 elseif t > 1 then t = 1 end
					local d = sqrt((px + dx * t - cx) ^ 2 + (py + dy * t - cy) ^ 2 + (pz + dz * t - cz) ^ 2) - r
					if not bd or d < bd then best, bd = id, d end
				end
			end
		end
	end
	return best, bd
end
