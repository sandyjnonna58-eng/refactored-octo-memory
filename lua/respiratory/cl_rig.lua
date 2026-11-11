-- Client: the bones of the respiratory models.
--
-- The models (models/hemogen/lung_r.mdl, lung_l.mdl, airways.mdl, diaphragm.mdl; made by
-- tools/offline/lunggen.ps1) are skinned by the engine: every corner hangs on up to three bones.
-- The bones are not a skeleton: each stands at the model's origin, has no parent, and is handed
-- its matrix by this file every time the model is drawn:
--
--     where its key's load stands on this body     the skeleton module's Skin(key): a pair of ribs,
--                                                  the chest bone, the neck; so a lung follows the
--                                                  ribs of this body model, pair by pair
--   x drawn together toward the lung's root        lobes and their bronchi, by how far that lung
--                                                  still stands in its place (fl, fr)
--   x identity + dl x (left half) + dr x (right)   what the two halves of the diaphragm do to what
--                                                  hangs on this bone (generated: cl_rigdata.lua)
--
-- Four numbers a body (dl, dr, fl, fr: sh_link.lua) are everything a frame brings; the shape that
-- follows from them is the engine's blend of the bones, so a lung changes its shape (its base goes
-- down and widens with the dome under it, its top stays under the first rib) and is not one stiff
-- thing made larger and smaller.
--
-- One entity a model serves every body: it is posed and drawn once for each. Nothing is made, and
-- nothing asked of the server, per frame.
--
--   RS.Rig.Rows(def, skin, ctl, out)   the arithmetic alone (also run by the offline check)
--   RS.Rig.Ready()                     the entities are there (made when first needed)
--   RS.Rig.Release()                   they are removed

local RS = HemoRespiratory
if RS.NoJIT then RS.NoJIT() end
RS.Rig = RS.Rig or {}
local RG = RS.Rig

-- a x b on rows of twelve (b is applied first), into o
local function Mul(a, b, o)
	local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12]
	o[1], o[2], o[3], o[4] = a1 * b1 + a2 * b5 + a3 * b9, a1 * b2 + a2 * b6 + a3 * b10, a1 * b3 + a2 * b7 + a3 * b11, a1 * b4 + a2 * b8 + a3 * b12 + a4
	o[5], o[6], o[7], o[8] = a5 * b1 + a6 * b5 + a7 * b9, a5 * b2 + a6 * b6 + a7 * b10, a5 * b3 + a6 * b7 + a7 * b11, a5 * b4 + a6 * b8 + a7 * b12 + a8
	o[9], o[10], o[11], o[12] = a9 * b1 + a10 * b5 + a11 * b9, a9 * b2 + a10 * b6 + a11 * b10, a9 * b3 + a10 * b7 + a11 * b11, a9 * b4 + a10 * b8 + a11 * b12 + a12
	return o
end
RG.Mul = Mul

local IDENT = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }
local tmp, col = {}, { {}, {} }

-- The matrix of every bone of a model. def: the model's entry in RS.RigData.models; skin(key): the
-- rows of twelve that carry the load of that key on the body, or nil; ctl: { dl, dr, fl, fr }.
-- out[i] is filled for the i-th bone. Returns out, or nil when nothing carries the chest.
function RG.Rows(def, skin, ctl, out)
	local D = RS.RigData
	local chest = skin("spine_up")
	if not chest then return nil end
	local dl, dr = ctl.dl, ctl.dr
	-- each side's lung drawn together about its root: 1 as it stands .. (1 - collapse) of its size
	for k = 1, 2 do
		local fill = k == 1 and ctl.fr or ctl.fl
		local c = col[k]
		if fill < 0.9995 then
			local s = 1 - D.collapse * (1 - fill)
			local h = k == 1 and D.hilum.r or D.hilum.l
			c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12] = s, 0, 0, (1 - s) * h[1], 0, s, 0, (1 - s) * h[2], 0, 0, s, (1 - s) * h[3]
			c.on = true
		else
			c.on = false
		end
	end
	local bones = def.bones
	for i = 1, #bones do
		local b = bones[i]
		local carry = skin(b[2]) or chest
		local L, R = b[5], b[6]
		local m = IDENT
		if (L and dl ~= 0) or (R and dr ~= 0) then
			m = tmp
			for k = 1, 12 do tmp[k] = IDENT[k] + (L and dl * L[k] or 0) + (R and dr * R[k] or 0) end
		end
		local o = out[i]
		if not o then o = {} out[i] = o end
		local kind = b[3]
		local c = (kind == "lobe" or kind == "bronchus") and (b[4] < 0 and col[1] or col[2]) or nil
		if c and c.on then
			Mul(c, m, o)
			Mul(carry, o, o)
		else
			Mul(carry, m, o)
		end
	end
	return out
end

-- Where a corner that hangs on bones stands: rows by bone (out of RG.Rows), the corner's place at
-- rest, and its bones as { index, weight, index, weight, ... }.
function RG.Blend(rows, x, y, z, bw)
	local px, py, pz = 0, 0, 0
	for k = 1, #bw, 2 do
		local m, w = rows[bw[k]], bw[k + 1]
		px = px + w * (m[1] * x + m[2] * y + m[3] * z + m[4])
		py = py + w * (m[5] * x + m[6] * y + m[7] * z + m[8])
		pz = pz + w * (m[9] * x + m[10] * y + m[11] * z + m[12])
	end
	return px, py, pz
end

-- A model's entry and the number of each of its bones by name.
local byId
function RG.Def(id)
	local D = RS.RigData
	if not D then return nil end
	if not byId then
		byId = {}
		for _, def in ipairs(D.models) do
			local names = {}
			for i, b in ipairs(def.bones) do names[b[1]] = i end
			byId[def.id] = { def = def, names = names }
		end
	end
	local e = byId[id]
	if not e then return nil end
	return e.def, e.names
end

-- Where a mark of the generated data (a named corner: the top of a lung, the fork of the windpipe)
-- stands on a body: x, y, z, or nil. skin and ctl as for RG.Rows.
local markRows = {}
function RG.Mark(id, skin, ctl)
	local D = RS.RigData
	local mk = D and D.marks and D.marks[id]
	if not mk then return nil end
	local def, names = RG.Def(mk.model)
	if not def then return nil end
	local rows = markRows[mk.model]
	if not rows then rows = {} markRows[mk.model] = rows end
	if not RG.Rows(def, skin, ctl, rows) then return nil end
	if not mk.bw then
		mk.bw = {}
		for k = 1, #mk.bones, 2 do
			mk.bw[k], mk.bw[k + 1] = names[mk.bones[k]], mk.bones[k + 1]
		end
	end
	return RG.Blend(rows, mk.p[1], mk.p[2], mk.p[3], mk.bw)
end

if RS.offline then return end

------------------------------------------------------------------------------------------
-- The entities
------------------------------------------------------------------------------------------
RG.ents = RG.ents or {}          -- a model's id -> { ent, def, idx, vm, rows, live }
RG.order = RG.order or {}
RG.state = RG.state or "none"    -- none | ready | failed
RG.note = RG.note or ""
RG.stats = RG.stats or { made = 0, calls = 0 }

function RG.Release()
	for id, e in pairs(RG.ents) do
		if IsValid(e.ent) then e.ent:Remove() end
		RG.ents[id] = nil
	end
	RG.order = {}
	if RG.state == "ready" then RG.state = "none" end
end

local function Fail(why)
	RG.Release()
	RG.state, RG.note = "failed", why
	return false
end

local BOUND = Vector(48, 48, 48)

function RG.Ready()
	if RG.state == "ready" then
		local whole = true
		for _, e in ipairs(RG.order) do if not IsValid(e.ent) then whole = false break end end
		if whole then return true end
		-- (something has removed them: a map clean-up does)
		RG.Release()
	elseif RG.state == "failed" then
		return false
	end
	local D = RS.RigData
	if not D then return Fail("the table of bones (cl_rigdata.lua) is not there: tools/offline/lunggen.ps1 -Emit makes it") end
	for _, def in ipairs(D.models) do
		if not file.Exists(def.path, "GAME") then return Fail(def.path .. " is not there (the addon's models folder)") end
		local ent = ClientsideModel(def.path, RENDERGROUP_OTHER)
		if not IsValid(ent) then return Fail(def.path .. " could not be made") end
		ent:SetNoDraw(true)
		ent:SetupBones()
		local e = { ent = ent, def = def, idx = {}, vm = {}, rows = {}, live = false }
		RG.ents[def.id] = e
		RG.order[#RG.order + 1] = e
		for i, b in ipairs(def.bones) do
			local bi = ent:LookupBone(b[1])
			if not bi then return Fail("the bone " .. b[1] .. " is not in " .. def.path .. ": model and table are not of the same making") end
			e.idx[i], e.vm[i], e.rows[i] = bi, Matrix(), {}
		end
		-- (wherever its origin is put, it is drawn only when asked: its bounds are of no account)
		ent:SetRenderBounds(-BOUND, BOUND)
		ent:AddCallback("BuildBonePositions", function(self)
			RG.stats.calls = RG.stats.calls + 1
			if not e.live then return end
			local idx, vm = e.idx, e.vm
			for i = 1, #idx do self:SetBoneMatrix(idx[i], vm[i]) end
		end)
		RG.stats.made = RG.stats.made + 1
	end
	RG.state, RG.note = "ready", ""
	return true
end

-- A model posed for a body: its bones' matrices worked out and handed to the engine. Returns the
-- entity ready to be drawn, or nil. skin, ctl as for RG.Rows; at: where the chest is (Vector).
local SetUnpacked = FindMetaTable("VMatrix").SetUnpacked
function RG.Pose(id, skin, ctl, at)
	local e = RG.ents[id]
	if not e or not IsValid(e.ent) then return nil end
	local rows = RG.Rows(e.def, skin, ctl, e.rows)
	if not rows then return nil end
	local vm = e.vm
	for i = 1, #rows do
		local m = rows[i]
		SetUnpacked(vm[i], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], 0, 0, 0, 1)
	end
	local ent = e.ent
	-- (from here on the engine is handed these matrices whenever it sets this model's bones up: now,
	-- and again should the drawing itself ask)
	e.live = true
	ent:SetPos(at)
	ent:InvalidateBoneCache()
	ent:SetupBones()
	return ent, e
end

hook.Add("ShutDown", "RS_Rig", function() RG.Release() end)
