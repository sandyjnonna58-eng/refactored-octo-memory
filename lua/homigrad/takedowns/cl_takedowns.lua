-- Клиентская часть тейкдаунов (описание в sh_takedowns.lua): невидимые шаблоны играют анимацию,
-- кости игроков/NPC берутся с них, мачете рисуется в правой руке, камера убивающего и жертвы - из глаз по анимации.
-- cl_ грузится раньше sh_ (по алфавиту), поэтому таблица создаётся здесь тоже
hg.Takedown = hg.Takedown or {}
local TD = hg.Takedown

local BLEND_IN = 0.2   -- тело и камера плавно входят в анимацию
local BLEND_OUT = 0.3  -- камера после приёма плавно возвращается
local FOV_ADD = -12    -- чуть ближе на время приёма

TD.Active = TD.Active or {}

local function Template(model, seq, pos, ang)
	local m = ClientsideModel(model, RENDERGROUP_OTHER)
	if not IsValid(m) then return end
	m:SetNoDraw(true)
	m:SetPos(pos)
	m:SetAngles(ang)
	local id = m:LookupSequence(seq)
	if id and id >= 0 then m:ResetSequence(id) end
	m:SetPlaybackRate(0)
	m:SetCycle(0)
	m.td_ok = id and id >= 0 and m:LookupBone("ValveBiped.Bip01_Pelvis") ~= nil
	return m
end

local function UpdateTemplate(m, t, dur)
	if not IsValid(m) or m.td_frame == FrameNumber() then return end
	m.td_frame = FrameNumber()
	m:SetCycle(math.Clamp(t / dur, 0, 1))
	m:InvalidateBoneCache()
	m:SetupBones()
end

local function Remove(td)
	if td.removed then return end
	td.removed = true
	for _, m in ipairs({td.plyMdl, td.tgtMdl, td.wepMdl}) do
		if IsValid(m) then m:Remove() end
	end
	for _, ent in ipairs({td.attacker, td.victim}) do
		local e = TD.ByEnt[ent]
		if e and e.td == td then TD.ByEnt[ent] = nil end
		if IsValid(ent) and ent.rem_td_cb then
			ent:RemoveCallback("BuildBonePositions", ent.rem_td_cb)
			ent.rem_td_cb = nil
		end
	end
	TD.Active[td.id] = nil
end

-- кости шаблона -> ent: совпадающие по имени копируются, остальные (лишние кости модели) едут за родителем
local boneMaps = {}
local function BoneMap(ent, tm)
	local key = ent:GetModel() .. "|" .. tm:GetModel()
	local map = boneMaps[key]
	if map then return map end
	map = {}
	for i = 0, ent:GetBoneCount() - 1 do
		local tb = tm:LookupBone(ent:GetBoneName(i))
		if tb then map[i] = tb end
	end
	boneMaps[key] = map
	return map
end

local function LerpMatrix(k, a, b)
	local q1, q2 = Quaternion(), Quaternion()
	q1:SetMatrix(a)
	q2:SetMatrix(b)
	local m = Matrix()
	m:SetTranslation(LerpVector(k, a:GetTranslation(), b:GetTranslation()))
	m:SetAngles(q1:SLerp(q2, k):Angle())
	m:SetScale(a:GetScale())
	return m
end

local function Pose(ent, entry)
	local td = entry.td
	local tm = entry.role == "attacker" and td.plyMdl or td.tgtMdl
	if not IsValid(tm) or not tm.td_ok then return end
	local t = CurTime() - td.start
	UpdateTemplate(tm, t, entry.role == "attacker" and td.info.ply or td.info.tgt)

	local k = math.Clamp(t / BLEND_IN, 0, 1)
	local map = BoneMap(ent, tm)
	local old, new = {}, {}
	local n = ent:GetBoneCount()
	for i = 0, n - 1 do old[i] = ent:GetBoneMatrix(i) end
	for i = 0, n - 1 do
		local m
		local tb = map[i]
		if tb then
			m = tm:GetBoneMatrix(tb)
			if m and old[i] then
				m:SetScale(old[i]:GetScale())
				if k < 1 then m = LerpMatrix(k, old[i], m) end
			end
		end
		if not m then
			local p = ent:GetBoneParent(i)
			if p and p >= 0 and new[p] and old[p] and old[i] then
				m = new[p] * (old[p]:GetInverseTR() * old[i])
			end
		end
		if m then
			ent:SetBoneMatrix(i, m)
			new[i] = m
		end
	end
end

-- вызывается из DrawPlayerRagdoll (fake/sh_render.lua) вместо TPIK, пока игрок в приёме
function TD.Pose(ent, ply)
	local entry = TD.ByEnt[ply]
	if entry and ent == ply then Pose(ent, entry) end
end

net.Receive("rem_takedown", function()
	local id = net.ReadUInt(16)
	local attacker, victim = net.ReadEntity(), net.ReadEntity()
	local seq = net.ReadString()
	local plyPos, plyAng = net.ReadVector(), net.ReadAngle()
	local tgtPos, tgtAng = net.ReadVector(), net.ReadAngle()
	local start = net.ReadFloat()
	local wepClass = net.ReadString()
	local info = TD.Seq[seq]
	if not info or not IsValid(attacker) or not IsValid(victim) then return end
	if TD.Active[id] then Remove(TD.Active[id]) end

	local td = {
		id = id, attacker = attacker, victim = victim, seq = seq, info = info, start = start,
		plyPos = plyPos, plyAng = plyAng, tgtPos = tgtPos, tgtAng = tgtAng, bloodDone = {},
	}
	td.plyMdl = Template(TD.PlyModel, seq, plyPos, plyAng)
	td.tgtMdl = Template(TD.TgtModel, seq, tgtPos, tgtAng)

	local stored = wepClass ~= "" and weapons.Get(wepClass)
	if stored then
		local mdl = stored.WorldModelExchange or stored.WorldModel
		if mdl and mdl ~= "" then
			td.wepMdl = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
			if IsValid(td.wepMdl) then td.wepMdl:SetNoDraw(true) end
		end
		td.wepOffset = stored.TakedownOffset or TD.DefaultOffset
	end

	TD.Active[id] = td
	TD.ByEnt[attacker] = {td = td, role = "attacker"}
	TD.ByEnt[victim] = {td = td, role = "victim"}

	-- игроков позирует DrawPlayerRagdoll, NPC - свой колбэк
	if victim:IsNPC() then
		victim.rem_td_cb = victim:AddCallback("BuildBonePositions", function(ent)
			local e = TD.ByEnt[ent]
			if e then Pose(ent, e) end
		end)
	end
end)

net.Receive("rem_takedown_end", function()
	local td = TD.Active[net.ReadUInt(16)]
	if td then Remove(td) end
end)

-- кровь, конец анимации жертвы, страховка от зависших приёмов
local function BloodAt(td)
	local tm = td.tgtMdl
	if not IsValid(tm) or not tm.td_ok then return end
	local b = tm:LookupBone("ValveBiped.Bip01_Neck1") or tm:LookupBone("ValveBiped.Bip01_Head1")
	local m = b and tm:GetBoneMatrix(b)
	if not m then return end
	local pos = m:GetTranslation()
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetNormal(VectorRand())
	ed:SetScale(1)
	util.Effect("BloodImpact", ed)
	for i = 1, 2 do
		local dir = VectorRand() + Vector(0, 0, -1.2)
		util.Decal("Blood", pos, pos + dir * 96, {td.attacker, td.victim})
	end
end

hook.Add("Think", "rem_takedown_cl", function()
	local now = CurTime()
	for id, td in pairs(TD.Active) do
		local t = now - td.start
		if t > td.info.ply + 1 or not IsValid(td.attacker) then Remove(td) continue end
		UpdateTemplate(td.plyMdl, t, td.info.ply)
		UpdateTemplate(td.tgtMdl, t, td.info.tgt)
		for i, bt in ipairs(td.info.blood) do
			if t >= bt and not td.bloodDone[i] then
				td.bloodDone[i] = true
				BloodAt(td)
			end
		end
		-- жертва умерла (сервер убил её в конце её анимации) - дальше рисуется труп
		local v = td.victim
		local e = TD.ByEnt[v]
		if e and e.td == td and (not IsValid(v) or (v:IsPlayer() and not v:Alive()) or (t > td.info.tgt + 0.5)) then
			TD.ByEnt[v] = nil
			if IsValid(v) and v.rem_td_cb then
				v:RemoveCallback("BuildBonePositions", v.rem_td_cb)
				v.rem_td_cb = nil
			end
		end
	end
end)

-- NPC с клиентским трупом: труп в позе последнего кадра
hook.Add("CreateClientsideRagdoll", "rem_takedown_pose", function(ent, rag)
	for _, td in pairs(TD.Active) do
		if td.victim ~= ent or not IsValid(td.tgtMdl) or not td.tgtMdl.td_ok then continue end
		local tm = td.tgtMdl
		UpdateTemplate(tm, td.info.tgt, td.info.tgt)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if not IsValid(phys) then continue end
			local tb = tm:LookupBone(rag:GetBoneName(rag:TranslatePhysBoneToBone(i)))
			local m = tb and tm:GetBoneMatrix(tb)
			if m then
				phys:SetPos(m:GetTranslation())
				phys:SetAngles(m:GetAngles())
				phys:SetVelocity(vector_origin)
				phys:Wake()
			end
		end
	end
end)

-- мачете в правой руке шаблона убивающего
hook.Add("PostDrawOpaqueRenderables", "rem_takedown_weapon", function(depth, sky)
	if depth or sky then return end
	for _, td in pairs(TD.Active) do
		local w, tm = td.wepMdl, td.plyMdl
		if not IsValid(w) or not IsValid(tm) or not tm.td_ok then continue end
		local b = tm:LookupBone("ValveBiped.Anim_Attachment_RH")
		local m = b and tm:GetBoneMatrix(b)
		if not m then continue end
		local pos, ang = LocalToWorld(td.wepOffset[1], td.wepOffset[2], m:GetTranslation(), m:GetAngles())
		w:SetPos(pos)
		w:SetAngles(ang)
		w:SetupBones()
		w:DrawModel()
	end
end)

-- камера: из глаз по анимации (убивающий - вложение eyes шаблона, жертва - от кости головы)
local function EyeView(entry)
	local td = entry.td
	if entry.role == "attacker" then
		local tm = td.plyMdl
		if not IsValid(tm) or not tm.td_ok then return end
		local att = tm:GetAttachment(tm:LookupAttachment("eyes"))
		if att then return att.Pos, att.Ang end
	else
		local tm = td.tgtMdl
		if not IsValid(tm) or not tm.td_ok then return end
		local b = tm:LookupBone("ValveBiped.Bip01_Head1")
		local m = b and tm:GetBoneMatrix(b)
		if m then return LocalToWorld(TD.EyesPos, TD.EyesAng, m:GetTranslation(), m:GetAngles()) end
	end
end

local lastView -- {pos, ang, fov, time} - откуда возвращать камеру после приёма

-- вызывается из CalcView (cl_camera.lua) поверх обычного вида
function TD.FilterView(ply, view, origin, angles, fov)
	if GetViewEntity() ~= ply then return end
	local entry = TD.ByEnt[ply]
	local base = istable(view) and view or {origin = origin, angles = angles, fov = fov}
	local bfov = base.fov or fov or 90

	if entry then
		local pos, ang = EyeView(entry)
		if not pos then return end
		local k = math.Clamp((CurTime() - entry.td.start) / BLEND_IN, 0, 1)
		k = k * k * (3 - 2 * k)
		local out = {
			origin = LerpVector(k, base.origin or pos, pos),
			angles = LerpAngle(k, base.angles or ang, ang),
			fov = bfov + FOV_ADD * k,
			znear = 0.7,
			-- своё тело рисуется (как в обычном виде homigrad), голова у себя сжата в DrawPlayerRagdoll - видно руки
			drawviewer = true,
		}
		lastView = {pos = out.origin, ang = out.angles, fov = out.fov, time = CurTime()}
		return out
	end

	if lastView then
		local k = math.Clamp((CurTime() - lastView.time) / BLEND_OUT, 0, 1)
		if k >= 1 or not ply:Alive() then lastView = nil return end
		k = k * k * (3 - 2 * k)
		base.origin = LerpVector(k, lastView.pos, base.origin or lastView.pos)
		base.angles = LerpAngle(k, lastView.ang, base.angles or lastView.ang)
		base.fov = Lerp(k, lastView.fov, bfov)
		return base
	end
end

-- мышь не крутит взгляд, пока камера идёт по анимации
hook.Add("InputMouseApply", "rem_takedown_mouse", function(cmd)
	if TD.ByEnt[LocalPlayer()] then
		cmd:SetMouseX(0)
		cmd:SetMouseY(0)
		return true
	end
end)
