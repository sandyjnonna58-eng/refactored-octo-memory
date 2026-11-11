-- Where a bone is now. A pose is a body's animation bones read for this frame (client) or tick
-- (server) and what follows from them for the registry's bones; nothing is stored between frames
-- and nothing is ever sent: both sides work it out from the entity they have.
--
-- A bone of the registry stands in the reference rig's rest pose at a place sh_stock.lua gives, and
-- hangs on one or more rig keys. Its matrix (rest pose -> world) is
--     body's bone matrix  x  the body model's fit for that key  x  the reference rig's model -> bone
-- for one key, and for several the blend of those, made rigid again about the bone's own middle.
-- Arithmetic is on plain rows of twelve numbers (3 x 4), so that the same code runs in the offline
-- checks with no game behind it; vectors and matrices of the engine appear only at the door.
--
--   SK.PoseOf(ent)              the pose of a body (a player's body: SK.BodyOf(ply)), or nil, why
--   SK.BonePos(ent, id)         where a bone's middle is (Vector), or nil
--   SK.BoneEnds(ent, id)        the two ends of its long axis
--   SK.BoneMatrix(ent, id)      its own frame in the world (VMatrix): origin its middle, forward its long axis
--   SK.BoneCarriers(ent, id)    what it hangs on on this body, and how sure that is

local SK = HemoSkeleton
SK.M = SK.M or {}
SK.Pose = SK.Pose or {}
SK.Fit = SK.Fit or {}
local M, P, F, R = SK.M, SK.Pose, SK.Fit, SK.Rig
local sqrt, abs = math.sqrt, math.abs

------------------------------------------------------------------------------------------
-- Rows of twelve
------------------------------------------------------------------------------------------
function M.Ident() return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 } end

-- a x b (b is applied first)
function M.Mul(a, b, o)
	o = o or {}
	local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12]
	o[1], o[2], o[3], o[4] = a1 * b1 + a2 * b5 + a3 * b9, a1 * b2 + a2 * b6 + a3 * b10, a1 * b3 + a2 * b7 + a3 * b11, a1 * b4 + a2 * b8 + a3 * b12 + a4
	o[5], o[6], o[7], o[8] = a5 * b1 + a6 * b5 + a7 * b9, a5 * b2 + a6 * b6 + a7 * b10, a5 * b3 + a6 * b7 + a7 * b11, a5 * b4 + a6 * b8 + a7 * b12 + a8
	o[9], o[10], o[11], o[12] = a9 * b1 + a10 * b5 + a11 * b9, a9 * b2 + a10 * b6 + a11 * b10, a9 * b3 + a10 * b7 + a11 * b11, a9 * b4 + a10 * b8 + a11 * b12 + a12
	return o
end

function M.Xf(m, x, y, z)
	return m[1] * x + m[2] * y + m[3] * z + m[4], m[5] * x + m[6] * y + m[7] * z + m[8], m[9] * x + m[10] * y + m[11] * z + m[12]
end
-- (a direction: without the translation)
function M.Rot(m, x, y, z)
	return m[1] * x + m[2] * y + m[3] * z, m[5] * x + m[6] * y + m[7] * z, m[9] * x + m[10] * y + m[11] * z
end

-- The inverse of any 3 x 4 that has one (scaled bones too).
function M.Inv(t, o)
	local a, b, c, d = t[1], t[2], t[3], t[4]
	local e, f, g, h = t[5], t[6], t[7], t[8]
	local i, j, k, l = t[9], t[10], t[11], t[12]
	local c11, c12, c13 = f * k - g * j, c * j - b * k, b * g - c * f
	local c21, c22, c23 = g * i - e * k, a * k - c * i, c * e - a * g
	local c31, c32, c33 = e * j - f * i, b * i - a * j, a * f - b * e
	local det = a * c11 + b * c21 + c * c31
	if abs(det) < 1e-12 then return nil end
	local inv = 1 / det
	c11, c12, c13 = c11 * inv, c12 * inv, c13 * inv
	c21, c22, c23 = c21 * inv, c22 * inv, c23 * inv
	c31, c32, c33 = c31 * inv, c32 * inv, c33 * inv
	o = o or {}
	o[1], o[2], o[3], o[4] = c11, c12, c13, -(c11 * d + c12 * h + c13 * l)
	o[5], o[6], o[7], o[8] = c21, c22, c23, -(c21 * d + c22 * h + c23 * l)
	o[9], o[10], o[11], o[12] = c31, c32, c33, -(c31 * d + c32 * h + c33 * l)
	return o
end

-- The largest of the three lengths a matrix gives a unit step (how much it enlarges at the most).
function M.Scale(m)
	local a = m[1] * m[1] + m[5] * m[5] + m[9] * m[9]
	local b = m[2] * m[2] + m[6] * m[6] + m[10] * m[10]
	local c = m[3] * m[3] + m[7] * m[7] + m[11] * m[11]
	return sqrt(math.max(a, b, c))
end

if not SK.offline then
	function M.FromMatrix(vm, o)
		o = o or {}
		o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12] = vm:Unpack()
		return o
	end
	function M.ToMatrix(m, vm)
		vm = vm or Matrix()
		vm:SetUnpacked(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], 0, 0, 0, 1)
		return vm
	end
end

------------------------------------------------------------------------------------------
-- The reference rig, from the stock data: where its joints are, how long its bones
------------------------------------------------------------------------------------------
local ST = SK.Stock
local rest = ST.rest
-- Keys that are no animation bone of any rig: a part of what a bone carries, which goes with that
-- bone and has a fit of its own (the lower jaw in the head, each pair of ribs on the chest bone:
-- sh_stock.lua, parts). Such a key stands where its bone stands.
local PART = ST.parts or {}
P.PART = PART
for part, host in pairs(PART) do rest[part] = rest[part] or rest[host] end
ST.joint = {}
for key, m in pairs(rest) do
	-- (the bone's origin in the model's space: what model -> bone sends to nothing)
	local inv = M.Inv(m)
	ST.joint[key] = { inv[4], inv[8], inv[12] }
	ST.restInv = ST.restInv or {}
	ST.restInv[key] = inv
end
-- the key a bone's length is measured to
local CHILD = { spine_low = "spine_mid", spine_mid = "spine_up", spine_up = "spine_top", neck = "head" }
for _, s in ipairs({ "_l", "_r" }) do
	CHILD["clavicle" .. s] = "upperarm" .. s
	CHILD["upperarm" .. s] = "forearm" .. s
	CHILD["forearm" .. s] = "hand" .. s
	CHILD["thigh" .. s] = "calf" .. s
	CHILD["calf" .. s] = "foot" .. s
	CHILD["foot" .. s] = "toe" .. s
end
P.CHILD = CHILD
local function RefLength(key)
	local c = CHILD[key]
	local a, b = ST.joint[key], c and ST.joint[c]
	if not a or not b then return nil end
	return sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

------------------------------------------------------------------------------------------
-- The fit of a body model: by rig key, a map in the bone's own space (sh_fitdata.lua)
------------------------------------------------------------------------------------------
local fits = {}       -- model -> { keys = { key = rows }, src }
F.cache = fits

-- For a model the generator has measured: its table. For any other: each bone as long as the
-- body's own bone is against the reference rig's (measured on the entity, once), nothing across it
-- and nothing for the head: that is a fit of lengths only, and is said to be one.
function F.For(ent, prof)
	local model = prof.model
	local f = fits[model]
	if f then return f end
	local data = SK.FitData and SK.FitData[model]
	-- the head: the skull's and the lower jaw's maps, made from the head's own numbers (sh_headfit.lua)
	local hp = SK.HeadFit and SK.HeadFit.For(model)
	local head12, jaw12
	if hp then head12, jaw12 = SK.HeadFit.Maps(hp) end
	if data then
		local keys = {}
		for k, v in pairs(data.keys) do keys[k] = v end
		keys.head, keys.jaw = head12, jaw12
		f = { keys = keys, src = "table", out = data.out, head = hp and hp.src or "none" }
	else
		local keys, n = {}, 0
		for key, child in pairs(CHILD) do
			local a, b = prof.bone[key], prof.bone[child]
			local ref = RefLength(key)
			local ma, mb = a and ent:GetBoneMatrix(a), b and ent:GetBoneMatrix(b)
			if ma and mb and ref and ref > 0.5 then
				local len = (ma:GetTranslation() - mb:GetTranslation()):Length()
				local k = len / ref
				-- (a bone that some gore has scaled away, or a rig laid out otherwise: left alone)
				if k > 0.6 and k < 1.6 and abs(k - 1) > 0.01 then
					keys[key] = { k, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }
					n = n + 1
				end
			end
		end
		for _, s in ipairs({ "_l", "_r" }) do keys["toe" .. s] = keys["foot" .. s] end
		-- (a head fitted by hand on a model that has no table: HF.Adjust)
		keys.head, keys.jaw = head12, jaw12
		f = { keys = keys, src = n > 0 and "lengths" or "none", head = hp and hp.src or "none" }
	end
	fits[model] = f
	return f
end

------------------------------------------------------------------------------------------
-- Poses
------------------------------------------------------------------------------------------
local Pose = P.Class or {}
P.Class = Pose
Pose.__index = Pose
P.gen = P.gen or 0          -- raised when something every pose depends on changes (the fit switched off for a look)
P.noFit = P.noFit or false

local function Stamp()
	if SK.offline then return 0 end
	return (CLIENT and FrameNumber() or engine.TickCount()) * 8 + P.gen % 8
end

function Pose:Fresh()
	self.stamp = Stamp()
	self.raw, self.car, self.skin, self.bm, self.inv = {}, {}, {}, {}, {}
end

local function Check(self)
	if self.stamp ~= Stamp() then self:Fresh() end
end

-- The body's bone matrix for a key as the engine has it, or nil (no such bone, or scaled to nothing).
function Pose:Raw(key)
	Check(self)
	local c = self.raw[key]
	if c ~= nil then return c or nil end
	local rows
	local idx = self.prof.bone[key]
	if self.getter then
		-- (bone matrices handed in from elsewhere: a body model's own rest pose, for measuring a fit)
		rows = idx and self.getter(idx) or nil
	else
		local vm = idx and self.ent:GetBoneMatrix(idx)
		if vm then
			rows = M.FromMatrix(vm)
			-- (Z-City shows a limb that is gone by scaling its bone to nothing: what hangs on it is gone with it)
			if rows[1] * rows[1] + rows[5] * rows[5] + rows[9] * rows[9] < 0.01 then rows = nil end
		end
	end
	self.raw[key] = rows or false
	return rows
end

-- The same with the fit of that key, or nil.
function Pose:Carrier(key)
	Check(self)
	local c = self.car[key]
	if c ~= nil then return c or nil end
	local rows
	if self.atRest then
		rows = ST.restInv[key]
	else
		rows = self:Raw(key)
		local A = rows and not P.noFit and self.fit and self.fit.keys[key]
		if A then rows = M.Mul(rows, A) end
	end
	self.car[key] = rows or false
	return rows
end

-- Rest pose -> world for what hangs on a key. A key the model has not is carried by its stand-in,
-- as if it were fastened to that in the rest pose. A key that is a part of a bone's load is carried
-- by that bone with the part's own fit (the bone's, where the part has none).
function Pose:Skin(key)
	Check(self)
	local s = self.skin[key]
	if s ~= nil then return s or nil end
	local out
	local host = PART[key]
	if host and not self.atRest then
		local real = self.prof.bone[host] and host or self.prof.via[host]
		local raw = real and self:Raw(real)
		if raw and rest[real] then
			local A = not P.noFit and self.fit and (self.fit.keys[key] or self.fit.keys[real])
			out = M.Mul(A and M.Mul(raw, A) or raw, rest[real])
		end
	else
		local real = key
		if not self.atRest and not self.prof.bone[key] then real = self.prof.via[key] end
		local c = real and self:Carrier(real)
		out = c and rest[real] and M.Mul(c, rest[real])
	end
	self.skin[key] = out or false
	return out or nil
end

-- Rest pose -> world for something that hangs on several keys (carry = { { key, weight }, ... })
-- and has its middle at (cx, cy, cz): the blend of the keys' matrices, made rigid again about that
-- middle. One key: that key's matrix as it is.
function Pose:Carry(carry, cx, cy, cz)
	if #carry == 1 then return self:Skin(carry[1][1]) end
	local a = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	local l1, l2, l3, ws = 0, 0, 0, 0
	for i = 1, #carry do
		local s, w = self:Skin(carry[i][1]), carry[i][2]
		if s then
			for k = 1, 12 do a[k] = a[k] + s[k] * w end
			l1 = l1 + w * sqrt(s[1] * s[1] + s[5] * s[5] + s[9] * s[9])
			l2 = l2 + w * sqrt(s[2] * s[2] + s[6] * s[6] + s[10] * s[10])
			l3 = l3 + w * sqrt(s[3] * s[3] + s[7] * s[7] + s[11] * s[11])
			ws = ws + w
		end
	end
	if ws <= 0 then return nil end
	for k = 1, 12 do a[k] = a[k] / ws end
	l1, l2, l3 = l1 / ws, l2 / ws, l3 / ws
	-- where the blend puts the middle
	local px, py, pz = M.Xf(a, cx, cy, cz)
	-- the three directions square to each other again, each as long as the keys had it
	local ux, uy, uz = a[1], a[5], a[9]
	local n = sqrt(ux * ux + uy * uy + uz * uz)
	if n < 1e-9 then return nil end
	ux, uy, uz = ux / n, uy / n, uz / n
	local vx, vy, vz = a[2], a[6], a[10]
	local d = vx * ux + vy * uy + vz * uz
	vx, vy, vz = vx - d * ux, vy - d * uy, vz - d * uz
	n = sqrt(vx * vx + vy * vy + vz * vz)
	if n < 1e-9 then return nil end
	vx, vy, vz = vx / n, vy / n, vz / n
	local wx, wy, wz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	if wx * a[3] + wy * a[7] + wz * a[11] < 0 then wx, wy, wz = -wx, -wy, -wz end
	local o = { ux * l1, vx * l2, wx * l3, 0, uy * l1, vy * l2, wy * l3, 0, uz * l1, vz * l2, wz * l3, 0 }
	local qx, qy, qz = M.Rot(o, cx, cy, cz)
	o[4], o[8], o[12] = px - qx, py - qy, pz - qz
	return o
end

-- Rest pose -> world for a bone of the registry, or nil (nothing carries it on this body now).
function Pose:Bone(id)
	Check(self)
	local m = self.bm[id]
	if m ~= nil then return m or nil end
	local st = ST.bones[id]
	if st then m = self:Carry(st.carry, st.c[1], st.c[2], st.c[3]) end
	self.bm[id] = m or false
	return m
end

-- World -> rest pose for a bone.
function Pose:BoneInv(id)
	local i = self.inv[id]
	if i ~= nil then return i or nil end
	local m = self:Bone(id)
	i = m and M.Inv(m) or false
	self.inv[id] = i
	return i or nil
end

-- Where a bone's middle is: x, y, z, or nil.
function Pose:BonePos(id)
	local m = self:Bone(id)
	if not m then return nil end
	local c = ST.bones[id].c
	return M.Xf(m, c[1], c[2], c[3])
end

-- A pose whose bone matrices are handed in: getter(the engine bone's number) -> rows or nil.
function P.With(prof, fit, getter)
	local p = setmetatable({ prof = prof, fit = fit, getter = getter }, Pose)
	p:Fresh()
	return p
end

-- The reference rig standing in its rest pose: every bone where the stock data has it.
function P.Rest()
	local p = setmetatable({ atRest = true, prof = { bone = {}, via = {}, ok = true, model = "rest" } }, Pose)
	p:Fresh()
	return p
end

local poses = setmetatable({}, { __mode = "k" })

-- Every fit and every pose is made again when next asked for (the heads' numbers were changed by hand).
function P.Forget()
	for k in pairs(fits) do fits[k] = nil end
	for k in pairs(poses) do poses[k] = nil end
	P.gen = P.gen + 1
end

if SK.offline then return end

-- The entity that is a character's body now: the ragdoll Z-City has laid a player in, else the
-- player; anything else is its own body.
function SK.BodyOf(ent)
	if not IsValid(ent) then return nil end
	if not ent:IsPlayer() then return ent end
	if istable(ABL) and istable(ABL.ZC) and ABL.ZC.GetBody then
		local b = ABL.ZC.GetBody(ent)
		if IsValid(b) then return b end
	elseif istable(hg) and isfunction(hg.GetCurrentCharacter) then
		local c = hg.GetCurrentCharacter(ent)
		if IsValid(c) then return c end
	end
	return ent
end

-- The pose of a body, or nil and why not.
function SK.PoseOf(ent)
	if not IsValid(ent) then return nil, "no entity" end
	local p = poses[ent]
	local model = ent:GetModel()
	if p and p.model == model then return p end
	local prof = R.Resolve(ent)
	if not prof then return nil, "its bones cannot be asked for yet" end
	if not prof.ok then return nil, prof.why end
	p = setmetatable({ ent = ent, model = model, prof = prof }, Pose)
	p.fit = F.For(ent, prof)
	p:Fresh()
	poses[ent] = p
	return p
end
P.Of = SK.PoseOf

function SK.BonePos(ent, id)
	local p = SK.PoseOf(ent)
	if not p then return nil end
	local x, y, z = p:BonePos(id)
	return x and Vector(x, y, z) or nil
end

-- The two ends of a bone's long axis (bones that are a place only have none).
function SK.BoneEnds(ent, id)
	local p = SK.PoseOf(ent)
	local st = ST.bones[id]
	local m = p and st and st.ax and p:Bone(id)
	if not m then return nil end
	local c, a, l = st.c, st.ax, st.len
	local ax, ay, az = M.Xf(m, c[1] - a[1] * l, c[2] - a[2] * l, c[3] - a[3] * l)
	local bx, by, bz = M.Xf(m, c[1] + a[1] * l, c[2] + a[2] * l, c[3] + a[3] * l)
	return Vector(ax, ay, az), Vector(bx, by, bz)
end

-- A bone's own frame in the world: origin its middle, forward along its long axis (the model's
-- own axes for a bone that has none).
function SK.BoneMatrix(ent, id)
	local p = SK.PoseOf(ent)
	local st = ST.bones[id]
	local m = p and st and p:Bone(id)
	if not m then return nil end
	local c = st.c
	local vm = Matrix()
	local px, py, pz = M.Xf(m, c[1], c[2], c[3])
	if st.ax then
		local fx, fy, fz = M.Rot(m, st.ax[1], st.ax[2], st.ax[3])
		vm:SetAngles(Vector(fx, fy, fz):Angle())
	else
		vm:SetAngles(Vector(M.Rot(m, 1, 0, 0)):Angle())
	end
	vm:SetTranslation(Vector(px, py, pz))
	return vm
end

-- What a bone hangs on on this body: a list of { key, weight, bone = the engine bone's number,
-- name = its name, standin = the key that stands in for a missing one }, and
-- { src (stock, derived, placed), how (piece, cut, shared: how its geometry is had), unit, fit }.
function SK.BoneCarriers(ent, id)
	local p = SK.PoseOf(ent)
	local st = ST.bones[id]
	if not p or not st then return nil end
	local out = {}
	for _, cw in ipairs(st.carry) do
		local idx, real = R.BoneOf(p.prof, cw[1])
		local host = PART[cw[1]]
		out[#out + 1] = { key = cw[1], weight = cw[2], bone = idx, name = idx and ent:GetBoneName(idx) or nil, part = host, standin = real ~= (host or cw[1]) and real or nil }
	end
	local unit = st.unit and ST.units[st.unit]
	return out, { src = st.src, how = unit and unit.how or "none", unit = st.unit, fit = p.fit and p.fit.src or "none" }
end
