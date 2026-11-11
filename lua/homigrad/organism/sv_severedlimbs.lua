-- Отрубленные конечности: при любом отрубании Z-City (hg.organism.AmputateLimb -> хук OnAmputateLimb: катана,
-- сильный режущий удар, взрыв, придавило) у обрубка появляется сама конечность - копия регдолла, где видны только
-- кости конечности (голень со стопой / предплечье с кистью). Остальные кости сжаты в ноль и каждый тик едут в
-- начало конечности (колено / локоть) - так срез закрыт, а не тянется к телу. Конечность можно взять (руки Z-City,
-- E), из среза долго течёт кровь (cl_severedlimbs.lua), при ударах о пол и стены - пятна крови.
local cvOn = CreateConVar("rem_severed_limbs", "1", FCVAR_ARCHIVE, "Severed limbs drop as bleeding pick-up-able pieces", 0, 1)
local cvLife = CreateConVar("rem_severed_limbs_life", "300", FCVAR_ARCHIVE, "Seconds before a severed limb is removed", 10, 3600)
local cvMax = CreateConVar("rem_severed_limbs_max", "16", FCVAR_ARCHIVE, "Max severed limbs at once (oldest removed)", 1, 64)

local LIMB_BONE = {
	lleg = "ValveBiped.Bip01_L_Calf",
	rleg = "ValveBiped.Bip01_R_Calf",
	larm = "ValveBiped.Bip01_L_Forearm",
	rarm = "ValveBiped.Bip01_R_Forearm",
}
local BLEED_TIME = 45 -- секунд течёт кровь (к концу всё реже)
local ZERO = Vector(0, 0, 0)

local limbsAlive = {} -- {ent, rootPhys, hidden = {physID...}}

local function Collect(ent, bone, out)
	out[bone] = true
	for _, child in ipairs(ent:GetChildBones(bone) or {}) do
		if not out[child] then Collect(ent, child, out) end
	end
end

-- поза копии = поза тела (регдолл - по физ. костям, стоящий игрок - по матрицам костей)
local function CopyPose(src, dst)
	if src:IsRagdoll() then
		for i = 0, math.min(src:GetPhysicsObjectCount(), dst:GetPhysicsObjectCount()) - 1 do
			local a, b = src:GetPhysicsObjectNum(i), dst:GetPhysicsObjectNum(i)
			if IsValid(a) and IsValid(b) then
				b:SetPos(a:GetPos())
				b:SetAngles(a:GetAngles())
				b:SetVelocity(a:GetVelocity())
			end
		end
		return
	end
	src:SetupBones()
	local vel = src:GetVelocity()
	for i = 0, dst:GetPhysicsObjectCount() - 1 do
		local phys = dst:GetPhysicsObjectNum(i)
		local bone = dst:TranslatePhysBoneToBone(i)
		local m = bone and bone >= 0 and src:GetBoneMatrix(bone)
		if IsValid(phys) and m then
			phys:SetPos(m:GetTranslation())
			phys:SetAngles(m:GetAngles())
			phys:SetVelocity(vel)
		end
	end
end

local function CopyLook(src, dst, ply)
	dst:SetSkin(src:GetSkin() or 0)
	dst:SetColor(src:GetColor())
	dst:SetMaterial(src:GetMaterial() or "")
	for _, group in ipairs(src:GetBodyGroups() or {}) do
		dst:SetBodygroup(group.id, src:GetBodygroup(group.id))
	end
	for i = 0, #(src:GetMaterials() or {}) - 1 do
		dst:SetSubMaterial(i, src:GetSubMaterial(i) or "")
	end
	local look = IsValid(ply) and ply or src
	dst:SetNWVector("PlayerColor", look.GetPlayerColor and look:GetPlayerColor() or src:GetNWVector("PlayerColor", vector_origin))
	dst:SetNWString("PlayerName", look:GetNWString("PlayerName", "Limb"))
	-- одежда Z-City (new_appearance) - те же текстуры; шапки/броню на кусок руки не вешаем
	for k = 1, 8 do
		local c = look:GetNWString("Colthes" .. k, "")
		if c ~= "" then dst:SetNWString("Colthes" .. k, c) end
	end
	if dst.SetNetVar then
		dst:SetNetVar("Accessories", "none")
		dst:SetNetVar("Armor", {})
	end
end

local fleshSounds = {}
for i = 1, 4 do fleshSounds[i] = "physics/flesh/flesh_squishy_impact_hard" .. i .. ".wav" end

local function OnCollide(ent, data)
	if data.DeltaTime < 0.15 or data.Speed < 60 then return end
	ent:EmitSound(fleshSounds[math.random(#fleshSounds)], 65, math.random(95, 110), 0.7)
	if ent:GetNW2Float("rem_limb_bleed", 0) > CurTime() then
		util.Decal("Blood", data.HitPos + data.HitNormal * 2, data.HitPos - data.HitNormal * 4, ent)
	end
end

local function SpawnLimb(src, ply, limb)
	local boneName = LIMB_BONE[limb]
	if not boneName or not IsValid(src) then return end
	if not src:LookupBone(boneName) then return end

	local e = ents.Create("prop_ragdoll")
	if not IsValid(e) then return end
	e:SetModel(src:GetModel())
	e:SetPos(src:GetPos())
	e:SetAngles(src:GetAngles())
	e:Spawn()
	if e:GetPhysicsObjectCount() < 2 then e:Remove() return end
	e:SetCollisionGroup(COLLISION_GROUP_WEAPON) -- не мешает ходить, но берётся и лежит на полу
	CopyLook(src, e, ply)
	CopyPose(src, e)

	local root = e:LookupBone(boneName)
	local rootPhys = root and e:TranslateBoneToPhysBone(root)
	if not rootPhys or rootPhys < 0 then e:Remove() return end

	local keep = {}
	Collect(e, root, keep)
	local keepPhys = {}
	for bone in pairs(keep) do
		local p = e:TranslateBoneToPhysBone(bone)
		if p and p >= 0 then keepPhys[p] = true end
	end
	-- всё, кроме конечности: сжать в ноль, без столкновений, заморозить (поставит Think)
	for bone = 0, e:GetBoneCount() - 1 do
		if not keep[bone] then e:ManipulateBoneScale(bone, ZERO) end
	end
	local hidden = {}
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		if not keepPhys[i] then
			local phys = e:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:EnableCollisions(false)
				phys:SetMass(0.1)
				phys:EnableMotion(false)
				hidden[#hidden + 1] = i
			end
		end
	end
	e:RemoveInternalConstraint(rootPhys) -- конечность отдельно от тела

	local rp = e:GetPhysicsObjectNum(rootPhys)
	if IsValid(rp) then
		rp:Wake()
		rp:AddVelocity(VectorRand(-60, 60) + Vector(0, 0, 60))
		rp:AddAngleVelocity(VectorRand(-200, 200))
	end

	e.rem_limbBoneName = boneName
	e:SetNW2Bool("rem_limb", true)
	e:SetNW2Int("rem_limb_bone", root)
	e:SetNW2Float("rem_limb_bleed", CurTime() + BLEED_TIME)
	e:AddCallback("PhysicsCollide", OnCollide)
	SafeRemoveEntityDelayed(e, cvLife:GetFloat())

	local entry = {ent = e, rootPhys = rootPhys, hidden = hidden}
	limbsAlive[#limbsAlive + 1] = entry
	while #limbsAlive > cvMax:GetInt() do
		local old = table.remove(limbsAlive, 1)
		if IsValid(old.ent) then old.ent:Remove() end
	end
	return e
end

hg.SpawnSeveredLimb = SpawnLimb

hook.Add("OnAmputateLimb", "rem_severed_limbs", function(org, ent, limb)
	if not cvOn:GetBool() or not IsValid(ent) then return end
	local ply = org and org.owner
	if IsValid(ply) and not ply:IsPlayer() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or ply:GetNWEntity("ply") end
	-- кость на теле прячет сам Z-City; копию делаем, пока поза ещё целая
	SpawnLimb(ent, IsValid(ply) and ply:IsPlayer() and ply or nil, limb)
end)

-- E на конечность - взять в руку (weapon_rem_flesh: можно съесть). Пока в руке уже кусок - не берёт
hook.Add("PlayerUse", "rem_severed_limbs_take", function(ply, ent)
	if not IsValid(ent) or not ent:GetNW2Bool("rem_limb", false) then return end
	if not ply:Alive() or (ply.rem_limbTakeNext or 0) > CurTime() then return false end
	ply.rem_limbTakeNext = CurTime() + 0.5
	if ply:HasWeapon("weapon_rem_flesh") then return false end
	local wep = ply:Give("weapon_rem_flesh")
	if not IsValid(wep) then return false end
	wep:SetNW2String("rem_limb_model", ent:GetModel())
	wep:SetNW2String("rem_limb_bone", ent.rem_limbBoneName or "ValveBiped.Bip01_R_Forearm")
	wep:SetNW2Int("rem_limb_skin", ent:GetSkin() or 0)
	ply:SelectWeapon("weapon_rem_flesh")
	ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 60)
	ent:Remove()
	return false
end)

-- спрятанные кости - в начало конечности, чтобы сжатые вершины собрались у среза
hook.Add("Think", "rem_severed_limbs", function()
	for i = #limbsAlive, 1, -1 do
		local l = limbsAlive[i]
		local e = l.ent
		if not IsValid(e) then
			table.remove(limbsAlive, i)
		else
			local rp = e:GetPhysicsObjectNum(l.rootPhys)
			if IsValid(rp) and not rp:IsAsleep() then
				local pos, ang = rp:GetPos(), rp:GetAngles()
				for _, id in ipairs(l.hidden) do
					local phys = e:GetPhysicsObjectNum(id)
					if IsValid(phys) then
						phys:SetPos(pos)
						phys:SetAngles(ang)
					end
				end
			end
		end
	end
end)
