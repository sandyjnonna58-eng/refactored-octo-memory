-- How skull, lower jaw and brain lie in a head. The one place for it: the sizes measured for each
-- model are in sh_headdata.lua (generated); corrections by hand go into HF.Adjust below, or are
-- tried out in the game with skel_head_set (cl_headview.lua); the pose (sh_pose.lua) and the brain
-- module's drawing (lua/neurotrauma/cl_brain3d.lua) ask this file and nothing else.
--
-- The chain, once, for a thing of the skull:
--     the body's head bone  x  [ its head frame  <-  the fit  <-  the reference head frame ]  x  reference rig's model -> bone
-- The head frame is the brain module's (origin 4.2 up and 0.8 toward the face from the head bone;
-- side: the character's left positive; face; up). In it
--   the skull     is sized along the head's own level axes (which are tilted against the bone's by
--                 `tilt`), pitched and shifted: three sizes, a pitch, a shift. Its landmarks were
--                 laid on the head's by the generator: eye sockets on the eyeballs, the edge of the
--                 upper teeth on the line of the lips, the jaw's joint by the ear, crown and back
--                 under the scalp;
--   the lower jaw takes the skull's fit and three sizes of its own about its hinge;
--   the brain     is placed inside the fitted skull: one size, a centre and a pitch. It is not placed
--                 against the head bone on its own, and its shape is not changed.
-- Every map is made from those numbers when it is first asked for and kept by model. Nothing is
-- added to a placed thing afterwards and nothing is kept from one frame to the next.
--
-- A model the generator has not measured (HF.For(model).src == "fallback") gets the stock skull as
-- the reference rig carries it on its head bone, at its own size, and the brain as it lies in that
-- skull: skull and brain belong together, but neither is fitted to that head's surface. Such a
-- model is fitted by a line in HF.Adjust.

local SK = HemoSkeleton
SK.HeadFit = SK.HeadFit or {}
local HF = SK.HeadFit
local rad, cos, sin, sqrt, abs = math.rad, math.cos, math.sin, math.sqrt, math.abs

local HD = SK.HeadData or {}
local UP, FACE = SK.Stock.head.up, SK.Stock.head.face
local REF = HD.ref or { lsign = -1, hinge = { 0, -1.9 }, bite = { 3, -2.1 } }
HF.REF = REF

-- Corrections by hand, by model: { pattern (a plain piece of the model's path, lower case),
-- skull = { tilt, pitch, side, along, high, fwd, up }, jaw = { long, high, broad },
-- brain = { k, f, u, pitch } }: any of the three, any of their numbers; what is not named stays as
-- measured (or as the fallback has it). The first that fits is taken.
--   e.g. { pattern = "models/player/somebody.mdl", skull = { side = 0.82, up = -1.1 } }
HF.Adjust = HF.Adjust or {}

-- A turn in the plane of (face, up), nose down for a positive angle (degrees). The same numbers read
-- a place of the head frame in the head's own level frame (along, height) when the angle is its tilt.
local function Turn(deg, f, u)
	local a = rad(deg)
	local c, s = cos(a), sin(a)
	return f * c + u * s, -f * s + u * c
end
HF.Turn = Turn

-- the head frame <-> the head bone's own space (x up, y against the face, z to a side: lsign says which)
local function ToBone(lsign, s, f, u) return u + UP, -f - FACE, s * lsign end
local function FromBone(lsign, x, y, z) return z * lsign, -y - FACE, x - UP end
HF.ToBone, HF.FromBone = ToBone, FromBone

-- A place of the stock skull (reference head frame) in a head's frame.
function HF.Skull(p, s, f, u)
	local m, k = p.m2, p.skull
	return s * k.side, m[1] * f + m[2] * u + k.fwd, m[3] * f + m[4] * u + k.up
end

-- The same for a place of the lower jaw: the skull's fit, then its own sizes about the hinge, in the
-- head's level frame (its height about the level at which the teeth meet, so that they go on meeting).
function HF.Jaw(p, s, f, u)
	local qs, qf, qu = HF.Skull(p, s, f, u)
	local l, h = Turn(p.skull.tilt, qf, qu)
	local a = p.hingeL + (l - p.hingeL) * p.jaw.long
	local b = p.biteH + (h - p.biteH) * p.jaw.high
	local bf, bu = Turn(-p.skull.tilt, a, b)
	return qs * p.jaw.broad, bf, bu
end

-- A place of the brain module's mesh (its own units: x to the left, y to the face, z up) in a head's frame.
function HF.Brain(p, x, y, z)
	local b = p.brain
	local f, u = Turn(b.pitch, y, z)
	return x * b.k, b.f + b.k * f, b.u + b.k * u
end

local function Compose(p)
	local s = p.skull
	-- Rn(-tilt) x diag(along, high) x Rn(tilt + pitch): sized along the head's level axes, after the pitch
	local a, b = rad(s.tilt + s.pitch), rad(-s.tilt)
	local c1, s1, c2, s2 = cos(a), sin(a), cos(b), sin(b)
	local p00, p01, p10, p11 = s.along * c1, s.along * s1, -s.high * s1, s.high * c1
	p.m2 = { c2 * p00 + s2 * p10, c2 * p01 + s2 * p11, -s2 * p00 + c2 * p10, -s2 * p01 + c2 * p11 }
	-- the jaw's hinge and the level at which the teeth meet, as the skull's fit has them, in the level frame
	local _, hf, hu = HF.Skull(p, 0, REF.hinge[1], REF.hinge[2])
	p.hingeL = Turn(s.tilt, hf, hu)
	local _, bf, bu = HF.Skull(p, 0, REF.bite[1], REF.bite[2])
	local _, bh = Turn(s.tilt, bf, bu)
	p.biteH = bh
	p.head12, p.jaw12, p.brain12 = nil, nil, nil
end
HF.Compose = Compose

local SKULL0 = { tilt = 0, pitch = 0, side = 1, along = 1, high = 1, fwd = 0, up = 0 }
local JAW0 = { long = 1, high = 1, broad = 1 }

local function Copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end
local function Merge(into, from)
	local n = 0
	if type(from) ~= "table" then return 0 end
	for k, v in pairs(from) do
		if type(v) == "number" and into[k] ~= nil then into[k] = v n = n + 1 end
	end
	return n
end

local cache = {}
HF.cache = cache

-- What a model's head is given: { model, src ("measured", "fallback"; with ", adjusted by hand"),
-- lsign, skull, jaw, brain, cord, marks, fit (the generator's own figures), and the composed numbers }.
function HF.For(model)
	model = string.lower(model or "")
	local p = cache[model]
	if p then return p end
	local d = HD.models and HD.models[model]
	p = { model = model, src = d and "measured" or "fallback", measured = d ~= nil, lsign = d and d.lsign or REF.lsign }
	p.skull = Copy(d and d.skull or SKULL0)
	p.jaw = Copy(d and d.jaw or JAW0)
	p.brain = Copy(d and d.brain or HD.brain or { k = 2.58, f = 0, u = 0, pitch = 0 })
	p.cord, p.marks, p.fit = d and d.cord, d and d.marks, d and d.fit
	for _, a in ipairs(HF.Adjust) do
		if type(a.pattern) == "string" and string.find(model, a.pattern, 1, true) then
			local n = Merge(p.skull, a.skull) + Merge(p.jaw, a.jaw) + Merge(p.brain, a.brain)
			if n > 0 then p.src = p.src .. ", adjusted by hand" p.adjusted = true end
			break
		end
	end
	Compose(p)
	cache[model] = p
	return p
end

-- (after HF.Adjust has been changed: every model is made again when next asked for)
function HF.Forget()
	for k in pairs(cache) do cache[k] = nil end
	if SK.Pose and SK.Pose.Forget then SK.Pose.Forget() end
end

-- A model's numbers have been changed in place (the fitting view's skel_head_set): its maps are made
-- again and the fit every pose of that model holds is given the new ones.
function HF.Changed(p)
	Compose(p)
	p.adjusted = true
	if not string.find(p.src, "by hand", 1, true) then p.src = p.src .. ", adjusted by hand" end
	local f = SK.Fit and SK.Fit.cache and SK.Fit.cache[p.model]
	if f then
		f.keys.head, f.keys.jaw = HF.Maps(p)
		f.head = p.src
	end
	if SK.Pose then SK.Pose.gen = (SK.Pose.gen or 0) + 1 end
end

-- A map of the head frame as twelve numbers in the head bone's own space (3 x 4, rows): what the
-- pose multiplies between the body's head bone and the reference rig's.
local function Twelve(fn, p, srcSign, dstSign)
	local function F(x, y, z) return ToBone(dstSign, fn(p, FromBone(srcSign, x, y, z))) end
	local ox, oy, oz = F(0, 0, 0)
	local xx, xy, xz = F(1, 0, 0)
	local yx, yy, yz = F(0, 1, 0)
	local zx, zy, zz = F(0, 0, 1)
	return { xx - ox, yx - ox, zx - ox, ox, xy - oy, yy - oy, zy - oy, oy, xz - oz, yz - oz, zz - oz, oz }
end

-- The skull's and the lower jaw's maps for a model, or nil for both (nothing to do: the fallback as it is).
function HF.Maps(p)
	if not p.measured and not p.adjusted then return nil, nil end
	if not p.head12 then
		p.head12 = Twelve(HF.Skull, p, REF.lsign, p.lsign)
		p.jaw12 = Twelve(HF.Jaw, p, REF.lsign, p.lsign)
	end
	return p.head12, p.jaw12
end

-- The brain's mesh in the head bone's own space (3 x 4, rows).
function HF.BrainRows(p)
	if p.brain12 then return p.brain12 end
	local function F(x, y, z) return ToBone(p.lsign, HF.Brain(p, x, y, z)) end
	local ox, oy, oz = F(0, 0, 0)
	local xx, xy, xz = F(1, 0, 0)
	local yx, yy, yz = F(0, 1, 0)
	local zx, zy, zz = F(0, 0, 1)
	p.brain12 = { xx - ox, yx - ox, zx - ox, ox, xy - oy, yy - oy, zy - oy, oy, xz - oz, yz - oz, zz - oz, oz }
	return p.brain12
end

-- The brain as it lies in the stock skull (the reference head frame): a place of its mesh there.
-- What the references between skull bones and brain regions go by (sh_brain.lua).
do
	local c = HD.brain or { k = 2.58, f = 0, u = 0, pitch = 0 }
	HF.canon = c
	function HF.BrainCanon(x, y, z)
		local f, u = Turn(c.pitch, y, z)
		return x * c.k, c.f + c.k * f, c.u + c.k * u
	end
end

-- The landmarks the generator laid on each other, for a model: a list of { name, skull = { s, f, u }
-- (the stock skull's, through this model's fit), head = { s, f, u } (the head's own, where it has
-- one), want (the tissue that belongs between, units) }, in the head frame. For looking at a fit.
local PAIRS = {
	{ "eye socket, left", "orbit_l", "eye_l", jaw = false },
	{ "eye socket, right", "orbit_r", "eye_r", jaw = false },
	{ "edge of the upper teeth", "incisal", "stomion", jaw = false },
	{ "brow", "brow", "brow", jaw = false },
	{ "crown", "crown", "crown", jaw = false },
	{ "back of the head", "back", "back", jaw = false },
	{ "jaw's joint, left", "jaw_joint_l", "ear_l", jaw = false },
	{ "jaw's joint, right", "jaw_joint_r", "ear_r", jaw = false },
	{ "chin, front", "chin_front", "chin_front", jaw = true },
	{ "chin, underside", "chin_under", "chin_under", jaw = true },
}
function HF.Marks(p)
	local out = {}
	local rm, hm = REF.marks or {}, p.marks or {}
	for _, pr in ipairs(PAIRS) do
		local a, b = rm[pr[2]], hm[pr[3]]
		if a then
			local s, f, u
			if pr.jaw then s, f, u = HF.Jaw(p, a[1], a[2], a[3]) else s, f, u = HF.Skull(p, a[1], a[2], a[3]) end
			local e = { name = pr[1], skull = { s, f, u }, head = b and { b[1], b[2], b[3] } or nil }
			if b then e.dist = sqrt((s - b[1]) ^ 2 + (f - b[2]) ^ 2 + (u - b[3]) ^ 2) end
			out[#out + 1] = e
		end
	end
	return out
end

-- A model's numbers as a line for HF.Adjust (what skel_head_set prints).
function HF.Line(p)
	local s, j, b = p.skull, p.jaw, p.brain
	return string.format("{ pattern = %q, skull = { tilt = %.2f, pitch = %.2f, side = %.4f, along = %.4f, high = %.4f, fwd = %.4f, up = %.4f }, jaw = { long = %.4f, high = %.4f, broad = %.4f }, brain = { k = %.4f, f = %.4f, u = %.4f, pitch = %.2f } },",
		p.model, s.tilt, s.pitch, s.side, s.along, s.high, s.fwd, s.up, j.long, j.high, j.broad, b.k, b.f, b.u, b.pitch)
end

if SK.offline then return end

------------------------------------------------------------------------------------------
-- In the game: where the brain's mesh goes in the world
------------------------------------------------------------------------------------------
-- (the rows-of-twelve arithmetic is sh_pose.lua's, which is loaded after this file: asked for when used)
local M

-- The brain in a body's head, for whoever draws it: nil (this body has no skeleton, or its head bone
-- cannot be asked for now), or
--   { rows  the mesh's own units -> world (3 x 4, rows), from the head bone as it is now;
--     k     units a mesh unit;  src  where the numbers are from;
--     cord  nil, or { rows (the same for what lies beyond the bend), hx, hy, hz (the bend, in the
--           world), nx, ny, nz (the plane the two parts meet in: its normal, toward the cord) } }
-- The cord is the lower part of the brain module's stem. It is turned about the skull's base so that
-- it runs down the neck's canal, by the neck bone as it is now: it follows the neck when the head turns.
local STEM = HD.stem
function SK.BrainPlace(ent)
	M = M or SK.M
	local pose = SK.PoseOf(ent)
	if not pose then return nil end
	local idx = pose.prof.bone.head
	local vm = idx and ent:GetBoneMatrix(idx)
	if not vm then return nil end
	local head = M.FromMatrix(vm)
	-- (a head that gore has scaled away has no brain to show)
	if head[1] * head[1] + head[5] * head[5] + head[9] * head[9] < 0.01 then return nil end
	local p = HF.For(pose.prof.model)
	local rows = M.Mul(head, HF.BrainRows(p))
	local out = { rows = rows, k = p.brain.k, src = p.src, params = p }
	local ni = pose.prof.bone.neck
	local nm = STEM and p.cord and ni and ent:GetBoneMatrix(ni)
	if nm then
		local neck = M.FromMatrix(nm)
		local tx, ty, tz = M.Xf(neck, p.cord[1], p.cord[2], p.cord[3])
		local hx, hy, hz = M.Xf(rows, 0, STEM.hinge[1], STEM.hinge[2])
		local ax, ay, az = M.Rot(rows, 0, STEM.dir[1], STEM.dir[2])
		local la = sqrt(ax * ax + ay * ay + az * az)
		local bx, by, bz = tx - hx, ty - hy, tz - hz
		local lb = sqrt(bx * bx + by * by + bz * bz)
		if la > 1e-6 and lb > 1e-6 then
			ax, ay, az = ax / la, ay / la, az / la
			bx, by, bz = bx / lb, by / lb, bz / lb
			-- the least turn that takes the cord's own way onto the way to the canal, about the bend
			local kx, ky, kz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
			local sn = sqrt(kx * kx + ky * ky + kz * kz)
			local cs = ax * bx + ay * by + az * bz
			local R
			if sn < 1e-6 then
				R = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }
			else
				kx, ky, kz = kx / sn, ky / sn, kz / sn
				local C = 1 - cs
				R = { cs + kx * kx * C, kx * ky * C - kz * sn, kx * kz * C + ky * sn, 0,
					ky * kx * C + kz * sn, cs + ky * ky * C, ky * kz * C - kx * sn, 0,
					kz * kx * C - ky * sn, kz * ky * C + kx * sn, cs + kz * kz * C, 0 }
			end
			local rx, ry, rz = M.Rot(R, hx, hy, hz)
			R[4], R[8], R[12] = hx - rx, hy - ry, hz - rz
			local nx, ny, nz = ax + bx, ay + by, az + bz
			local ln = sqrt(nx * nx + ny * ny + nz * nz)
			if ln > 1e-6 then
				out.cord = { rows = M.Mul(R, rows), hx = hx, hy = hy, hz = hz, nx = nx / ln, ny = ny / ln, nz = nz / ln, bent = math.deg(math.atan2(sn, cs)) }
			end
		end
	end
	return out
end
