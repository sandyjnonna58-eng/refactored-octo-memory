local TORSO_UPPER_MODEL = "models/torsopartial/torsovar.mdl"
local TORSO_LOWER_MODEL = "models/torsopartial/abdomenvar.mdl"
local ZERO_SCALE = Vector(0, 0, 0)
local HIDDEN_POS = Vector(0, 0, 0) / 0

local STUMP_OFFSETS = {
	[0] = {
		upperPos = Vector(1.5, 2.5, 0),
		upperAng = Angle(0, 90, 90),
		upperScale = Vector(0.9, 0.9, 0.9),
		lowerPos = Vector(-3, 2, 0),
		lowerAng = Angle(0, 90, 90),
		lowerScale = Vector(1.1, 1.1, 1.1),
		lowerNudge = Vector(0, -4, 1)
	},
	[1] = {
		upperPos = Vector(0, 2.5, 0),
		upperAng = Angle(0, 90, 90),
		upperScale = Vector(0.85, 0.85, 0.85),
		lowerPos = Vector(-3, 2, 0),
		lowerAng = Angle(0, 90, 90),
		lowerScale = Vector(0.9, 0.9, 0.9),
		lowerNudge = Vector(0, -3, 0)
	}
}

local tearSounds = {
	"gore/kf2_tear1.wav",
	"gore/kf2_tear2.wav",
	"gore/kf2_tear3.wav",
	"gore/kf2_tear4.wav",
	"gore/kf2_tear5.wav",
	"gore/kf2_tear6.wav",
	"gore/kf2_tear7.wav"
}

for _, snd in ipairs(tearSounds) do
	util.PrecacheSound(snd)
end
util.PrecacheModel(TORSO_UPPER_MODEL)
util.PrecacheModel(TORSO_LOWER_MODEL)

local torsoStates = setmetatable({}, {__mode = "k"})
local splitStates = {}

local initialPhrases = {
	"WHAT THE FUCK?! MY LEGS ARE GONE!",
	"I'M SPLIT IN TWO! OH GOD!",
	"MY WAIST! IT'S JUST... GONE!",
	"GOD DAMN IT! I'M CUT APART!",
	"THERE'S NOTHING BELOW ME! FUCK!",
	"I'M RIPPED IN HALF! HELP!",
	"LOOK AT ME! I'M IN PIECES!",
	"FUCK! MY BODY'S SEVERED!",
	"HALF OF ME IS MISSING! FUCK!",
	"OH FUCK! I'M TORN APART!",
	"WHERE'S THE REST OF ME?!",
	"JESUS! I'M BROKEN IN TWO!"
}

local painPhrases = {
	"GOD, THE PAIN!",
	"I'M DRAINING OUT FAST!",
	"PLEASE! ANYONE! HELP!",
	"MY LEGS AREN'T RESPONDING!",
	"DON'T BLACK OUT! STAY AWAKE!",
	"NOTHING DOWN THERE BUT PAIN!",
	"PUT PRESSURE ON IT! PLEASE!",
	"THERE'S SO MUCH BLOOD!",
	"I CAN'T GET UP! HELP ME!",
	"EVERYTHING BELOW HURTS LIKE HELL!",
	"I'M FREEZING... SO COLD...",
	"STILL BREATHING! STILL HERE!",
	"GET ME A MEDIC, NOW!",
	"I'M SLIPPING AWAY..."
}

local criticalPhrases = {
	"SHOCK... IT'S TAKING ME...",
	"VISION'S GOING FUZZY...",
	"SO COLD... CAN'T STOP SHAKING...",
	"TOO MUCH BLOOD LOST...",
	"THIS IS IT... ISN'T IT?",
	"DARKNESS... COMING...",
	"HEART'S RACING OUT OF CONTROL...",
	"CAN'T FEEL MY FINGERS...",
	"STAY... AWAKE..."
}

local function PickPhrase(ply, pool, slot)
	local last = ply[slot]
	local index = math.random(#pool)
	if #pool > 1 and index == last then index = index % #pool + 1 end
	ply[slot] = index
	return pool[index]
end

local function ResolvePlayer(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent end
	local directOwner = ent.ply
	if IsValid(directOwner) and directOwner:IsPlayer() then return directOwner end
	if hg.RagdollOwner then
		local owner = hg.RagdollOwner(ent)
		if IsValid(owner) and owner:IsPlayer() then return owner end
	end
	local nwOwner = ent:GetNWEntity("ply")
	if IsValid(nwOwner) and nwOwner:IsPlayer() then return nwOwner end
	return nil
end

local function CopyAppearance(source, target)
	target:SetSkin(source:GetSkin() or 0)
	target:SetColor(source:GetColor())
	target:SetMaterial(source:GetMaterial() or "")
	for _, group in ipairs(source:GetBodyGroups() or {}) do
		if group and group.id then
			target:SetBodygroup(group.id, source:GetBodygroup(group.id))
		end
	end
	local mats = source:GetMaterials() or {}
	for i = 0, #mats - 1 do
		target:SetSubMaterial(i, source:GetSubMaterial(i) or "")
	end
end

local function CopyPhysicsPose(source, target)
	local count = math.min(source:GetPhysicsObjectCount(), target:GetPhysicsObjectCount())
	for i = 0, count - 1 do
		local srcPhys = source:GetPhysicsObjectNum(i)
		local dstPhys = target:GetPhysicsObjectNum(i)
		if IsValid(srcPhys) and IsValid(dstPhys) then
			dstPhys:SetPos(srcPhys:GetPos())
			dstPhys:SetAngles(srcPhys:GetAngles())
			dstPhys:SetVelocity(srcPhys:GetVelocity())
		end
	end
end

local function CollectDescendants(ent, bone, output)
	output[bone] = true
	for _, child in ipairs(ent:GetChildBones(bone) or {}) do
		if not output[child] then
			CollectDescendants(ent, child, output)
		end
	end
end

local function GetBoneTransform(ent, bone)
	if not IsValid(ent) or bone == nil or bone < 0 then return nil end
	local physID = ent:TranslateBoneToPhysBone(bone)
	if physID ~= nil and physID >= 0 then
		local phys = ent:GetPhysicsObjectNum(physID)
		if IsValid(phys) then
			return phys:GetPos(), phys:GetAngles()
		end
	end
	if ent.GetBonePosition then
		local pos, ang = ent:GetBonePosition(bone)
		if isvector(pos) and isangle(ang) then
			return pos, ang
		end
	end
	if ent.GetBoneMatrix then
		local matrix = ent:GetBoneMatrix(bone)
		if matrix then
			local pos = matrix:GetTranslation()
			local ang = matrix:GetAngles()
			if isvector(pos) and isangle(ang) then
				return pos, ang
			end
		end
	end
	return nil
end

local function UpdateCap(cap)
	if not IsValid(cap) then return false end
	local parent = cap.__hgTorsoParent
	local bone = cap.__hgTorsoBone
	if not IsValid(parent) or not bone then
		cap:Remove()
		return false
	end
	local basePos, baseAng = GetBoneTransform(parent, bone)
	if not basePos or not baseAng then return false end
	local pos, ang = LocalToWorld(cap.__hgTorsoLocalPos or vector_origin, cap.__hgTorsoLocalAng or angle_zero, basePos, baseAng)
	cap:SetPos(pos)
	cap:SetAngles(ang)
	return true
end

local function MakeCap(model, parent, bone, localPos, localAng, scale)
	local cap = ents.Create("prop_dynamic")
	if not IsValid(cap) then return nil end
	cap:SetModel(model)
	cap:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	cap:SetNotSolid(true)
	cap:SetMoveType(MOVETYPE_NONE)
	cap:DrawShadow(false)
	cap:Spawn()
	if scale then cap:ManipulateBoneScale(0, scale) end
	cap.__hgTorsoParent = parent
	cap.__hgTorsoBone = bone
	cap.__hgTorsoLocalPos = localPos
	cap.__hgTorsoLocalAng = localAng
	parent:DeleteOnRemove(cap)
	UpdateCap(cap)
	return cap
end

local function MakeCapBoneParented(model, parent, bone, localPos, localAng, scale)
	local cap = ents.Create("prop_dynamic")
	if not IsValid(cap) then return nil end
	cap:SetModel(model)
	cap:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	cap:SetNotSolid(true)
	cap:SetMoveType(MOVETYPE_NONE)
	cap:DrawShadow(false)
	cap:Spawn()
	if scale then cap:ManipulateBoneScale(0, scale) end
	local basePos, baseAng = GetBoneTransform(parent, bone)
	if basePos and baseAng then
		local pos, ang = LocalToWorld(localPos or vector_origin, localAng or angle_zero, basePos, baseAng)
		cap:SetPos(pos)
		cap:SetAngles(ang)
	end
	cap:SetParent(parent, bone)
	parent:DeleteOnRemove(cap)
	return cap
end

local function CollectParents(ent, bone)
	local parents = {}
	local parent = ent:GetBoneParent(bone)
	while parent and parent >= 0 do
		parents[parent] = true
		if parent == 0 then break end
		local nextParent = ent:GetBoneParent(parent)
		if nextParent == parent then break end
		parent = nextParent
	end
	return parents
end

local function SetHiddenBone(ent, bone, hardHide)
	ent:ManipulateBoneScale(bone, ZERO_SCALE)
	if hardHide then
		ent:ManipulateBonePosition(bone, HIDDEN_POS)
	end
end

local function ConfigureHiddenPhys(ent, physID)
	if not physID or physID < 0 then return end
	local phys = ent:GetPhysicsObjectNum(physID)
	if not IsValid(phys) then return end
	phys:EnableCollisions(false)
	phys:SetMass(0.01)
	phys:EnableMotion(false)
end

local function AddPhysParent(map, physID, parentPhysID)
	if not physID or physID < 0 then return end
	if not parentPhysID or parentPhysID < 0 then return end
	if physID == parentPhysID then return end
	map[physID] = parentPhysID
end

-- запись {родитель, lpos, lang} (AddRigidParent, косой разрез) - кость едет за родителем с прежним смещением
local function ForceHiddenPhys(ent, map)
	if not IsValid(ent) then return end
	for physID, parentInfo in pairs(map or {}) do
		local parentPhysID, lpos, lang = parentInfo, nil, nil
		if istable(parentInfo) then parentPhysID, lpos, lang = parentInfo[1], parentInfo[2], parentInfo[3] end
		local phys = ent:GetPhysicsObjectNum(physID)
		local parentPhys = ent:GetPhysicsObjectNum(parentPhysID)
		if IsValid(phys) and IsValid(parentPhys) then
			if lpos then
				local pos, ang = LocalToWorld(lpos, lang, parentPhys:GetPos(), parentPhys:GetAngles())
				phys:SetPos(pos)
				phys:SetAngles(ang)
			else
				phys:SetPos(parentPhys:GetPos())
				phys:SetAngles(parentPhys:GetAngles())
			end
			phys:SetVelocity(parentPhys:GetVelocity())
		end
	end
end

local function AddRigidParent(ent, map, physID, parentPhysID)
	local phys, parentPhys = ent:GetPhysicsObjectNum(physID), ent:GetPhysicsObjectNum(parentPhysID)
	if not IsValid(phys) or not IsValid(parentPhys) then return end
	local lpos, lang = WorldToLocal(phys:GetPos(), phys:GetAngles(), parentPhys:GetPos(), parentPhys:GetAngles())
	map[physID] = {parentPhysID, lpos, lang}
end

-- ===== Косой разрез (sv_meleehalve.lua): плоскость задаётся в координатах торса, чтобы перенести её
-- со стоящего игрока на его регдолл. cut = {sx, sy, ex, ey}: начало и конец разреза, x - доля полуширины
-- торса (+ вправо), y - доля высоты от таза до плеч.
local function BonePos(ent, name)
	local b = ent:LookupBone(name)
	if not b then return nil end
	if ent:IsRagdoll() then return (GetBoneTransform(ent, b)) end
	local m = ent:GetBoneMatrix(b)
	return m and m:GetTranslation() or ent:GetBonePosition(b)
end

function hg.TorsoFrame(ent)
	if not IsValid(ent) then return nil end
	local P = BonePos(ent, "ValveBiped.Bip01_Pelvis")
	local top = BonePos(ent, "ValveBiped.Bip01_Spine4") or BonePos(ent, "ValveBiped.Bip01_Spine2")
	local L, R = BonePos(ent, "ValveBiped.Bip01_L_UpperArm"), BonePos(ent, "ValveBiped.Bip01_R_UpperArm")
	if not (P and top and L and R) then return nil end
	local up = (top - P):GetNormalized()
	local right = R - L
	right = (right - up * right:Dot(up)):GetNormalized()
	local yArm = ((L + R) * 0.5 - P):Dot(up)
	if yArm < 5 then return nil end
	return {P = P, up = up, right = right, fwd = up:Cross(right), yArm = yArm, w = math.max((R - L):Dot(right) * 0.5 * 0.8, 3)}
end

-- плоскость разреза в мире: точка S и нормаль n (смотрит к верхней половине)
local function CutPlane(f, cut)
	local S = f.P + f.right * (cut[1] * f.w) + f.up * (cut[2] * f.yArm)
	local E = f.P + f.right * (cut[3] * f.w) + f.up * (cut[4] * f.yArm)
	local n = (E - S):Cross(f.fwd)
	if n:LengthSqr() < 1e-6 then n = Vector(f.up) end
	n:Normalize()
	if n:Dot(f.up) < 0 then n = -n end
	return S, n
end

-- плоскость для клиента (cl_torsocut.lua) - в осях кости, чтобы ехала вместе с телом; side - какую сторону оставить
local function SetCutNW(ent, bone, S, n, side)
	local bpos, bang = GetBoneTransform(ent, bone)
	if not bpos then return end
	ent:SetNW2Vector("rem_cut_p", (WorldToLocal(S, angle_zero, bpos, bang)))
	ent:SetNW2Vector("rem_cut_n", (WorldToLocal(n, angle_zero, vector_origin, bang)))
	ent:SetNW2Int("rem_cut_bone", bone)
	ent:SetNW2Int("rem_cut_side", side)
	ent:SetNW2Bool("rem_cut", true)
end

-- заглушка-обрубок: со стандартного места (разрез по Spine2) - на плоскость, повёрнута по её наклону
local function CapOnPlane(pos, ang, scale, S, n, up)
	local denom = n:Dot(up)
	if denom > 0.2 then pos = pos + up * (n:Dot(S - pos) / denom) end
	local axis = up:Cross(n)
	local sinA = axis:Length()
	if sinA > 1e-4 then
		axis:Normalize()
		local deg = math.deg(math.asin(math.min(sinA, 1)))
		-- направление поворота проверяем на самой оси "вверх" (знак у RotateAroundAxis не угадываем)
		local test = up:Angle()
		test:RotateAroundAxis(axis, deg)
		if test:Forward():Dot(n) < up:Angle():Forward():Dot(n) then deg = -deg end
		ang = Angle(ang.p, ang.y, ang.r)
		ang:RotateAroundAxis(axis, deg)
	end
	local k = 1 + (1 / math.max(denom, 0.5) - 1) * 0.7 -- срез наискось шире
	return pos, ang, scale and scale * k or nil
end

-- верх при косом разрезе: ноги прячем, таз остаётся (низ живота срежет плоскость) и едет жёстко за грудью
local function BuildUpperCut(rag, spine2PhysID)
	local physParents, hide, seen = {}, {}, {}
	for _, name in ipairs({"ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_R_Thigh"}) do
		local b = rag:LookupBone(name)
		if b then CollectDescendants(rag, b, hide) end
	end
	local pelvis = rag:LookupBone("ValveBiped.Bip01_Pelvis")
	local pelvisPhysID = pelvis and rag:TranslateBoneToPhysBone(pelvis)
	if pelvisPhysID and pelvisPhysID >= 0 and pelvisPhysID ~= spine2PhysID then
		AddRigidParent(rag, physParents, pelvisPhysID, spine2PhysID)
		ConfigureHiddenPhys(rag, pelvisPhysID)
		seen[pelvisPhysID] = true
	end
	for bone in pairs(hide) do
		SetHiddenBone(rag, bone, true)
		local physID = rag:TranslateBoneToPhysBone(bone)
		if physID and physID >= 0 and not seen[physID] and physID ~= spine2PhysID then
			seen[physID] = true
			ConfigureHiddenPhys(rag, physID)
			rag:RemoveInternalConstraint(physID)
			AddPhysParent(physParents, physID, spine2PhysID)
		end
	end
	rag:RemoveInternalConstraint(spine2PhysID)
	return physParents
end

-- низ при косом разрезе: руки и голову прячем, грудь остаётся (верх срежет плоскость) и едет жёстко за тазом
local function BuildLowerCut(lower)
	local pelvis = lower:LookupBone("ValveBiped.Bip01_Pelvis")
	local pelvisPhysID = pelvis and lower:TranslateBoneToPhysBone(pelvis) or 0
	if not pelvisPhysID or pelvisPhysID < 0 then pelvisPhysID = 0 end
	local physParents, hide, seen = {}, {}, {[pelvisPhysID] = true}
	local spine2 = lower:LookupBone("ValveBiped.Bip01_Spine2")
	local chestPhysID = spine2 and lower:TranslateBoneToPhysBone(spine2)
	if chestPhysID and chestPhysID >= 0 and chestPhysID ~= pelvisPhysID then
		AddRigidParent(lower, physParents, chestPhysID, pelvisPhysID)
		ConfigureHiddenPhys(lower, chestPhysID)
		lower:RemoveInternalConstraint(chestPhysID)
		seen[chestPhysID] = true
	end
	for _, name in ipairs({"ValveBiped.Bip01_L_Clavicle", "ValveBiped.Bip01_R_Clavicle", "ValveBiped.Bip01_Neck1"}) do
		local b = lower:LookupBone(name)
		if b then CollectDescendants(lower, b, hide) end
	end
	for bone in pairs(hide) do
		SetHiddenBone(lower, bone, true)
		local physID = lower:TranslateBoneToPhysBone(bone)
		if physID and physID >= 0 and not seen[physID] then
			seen[physID] = true
			ConfigureHiddenPhys(lower, physID)
			lower:RemoveInternalConstraint(physID)
			AddPhysParent(physParents, physID, pelvisPhysID)
		end
	end
	return physParents
end

local function BuildUpperHalf(rag, spine2, spine2PhysID)
	local visible = {}
	CollectDescendants(rag, spine2, visible)
	local parents = CollectParents(rag, spine2)
	local physParents = {}
	local seenPhys = {}

	for bone = 0, rag:GetBoneCount() - 1 do
		if not visible[bone] then
			SetHiddenBone(rag, bone, not parents[bone])
			local physID = rag:TranslateBoneToPhysBone(bone)
			if physID and physID >= 0 and not seenPhys[physID] then
				seenPhys[physID] = true
				ConfigureHiddenPhys(rag, physID)
				if not parents[bone] then
					rag:RemoveInternalConstraint(physID)
				end
				AddPhysParent(physParents, physID, spine2PhysID)
			end
		end
	end

	for parentBone in pairs(parents) do
		local physID = rag:TranslateBoneToPhysBone(parentBone)
		if physID and physID >= 0 then
			ConfigureHiddenPhys(rag, physID)
			AddPhysParent(physParents, physID, spine2PhysID)
		end
	end

	rag:RemoveInternalConstraint(spine2PhysID)
	return physParents
end

local function BuildLowerHalf(lower, spine2)
	local hidden = {}
	CollectDescendants(lower, spine2, hidden)
	local spine2PhysID = lower:TranslateBoneToPhysBone(spine2)
	local pelvis = lower:LookupBone("ValveBiped.Bip01_Pelvis")
	local pelvisPhysID = pelvis and lower:TranslateBoneToPhysBone(pelvis) or 0
	if not pelvisPhysID or pelvisPhysID < 0 then pelvisPhysID = 0 end
	local physParents = {}
	local seenPhys = {}

	for bone in pairs(hidden) do
		SetHiddenBone(lower, bone, bone != spine2)
		local physID = lower:TranslateBoneToPhysBone(bone)
		if physID and physID >= 0 and not seenPhys[physID] then
			seenPhys[physID] = true
			ConfigureHiddenPhys(lower, physID)
			if physID != pelvisPhysID then
				lower:RemoveInternalConstraint(physID)
				AddPhysParent(physParents, physID, pelvisPhysID)
			end
		end
	end

	if spine2PhysID and spine2PhysID >= 0 and spine2PhysID != pelvisPhysID then
		lower:RemoveInternalConstraint(spine2PhysID)
		AddPhysParent(physParents, spine2PhysID, pelvisPhysID)
	end

	return physParents
end

local function ApplyOldAmputations(lower, org)
	if not org or not Gib_RemoveBone then return end
	for bonename, limb in pairs(hg.amputeetable or {}) do
		if org[limb.."amputated"] then
			local bone = lower:LookupBone(bonename)
			if bone then
				Gib_RemoveBone(lower, bone, lower:TranslateBoneToPhysBone(bone))
			end
		end
	end
end

local function BuildSplitRagdolls(ply, rag, force, cut)
	local spine2 = rag:LookupBone("ValveBiped.Bip01_Spine2")
	if not spine2 then return nil end
	local spine2PhysID = rag:TranslateBoneToPhysBone(spine2)
	if not spine2PhysID or spine2PhysID < 0 then return nil end
	local spine2Phys = rag:GetPhysicsObjectNum(spine2PhysID)
	if not IsValid(spine2Phys) then return nil end

	local lower = ents.Create("prop_ragdoll")
	if not IsValid(lower) then return nil end
	lower:SetModel(rag:GetModel())
	lower:SetPos(rag:GetPos())
	lower:SetAngles(rag:GetAngles())
	lower:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	lower:DrawShadow(false)
	lower:Spawn()
	CopyAppearance(rag, lower)
	CopyPhysicsPose(rag, lower)
	lower:SetNWBool("hgTorsoLower", true)
	lower:SetNWVector("PlayerColor", rag:GetNWVector("PlayerColor", vector_origin))
	lower:SetNetVar("Accessories", rag:GetNetVar("Accessories", ""))
	if ApplyAppearanceRagdoll and IsValid(ply) then
		ApplyAppearanceRagdoll(lower, ply)
	else
		lower:SetNWString("PlayerName", rag:GetNWString("PlayerName", "Lower body"))
	end
	lower:SetNetVar("wounds", rag:GetNetVar("wounds", {}))
	ApplyOldAmputations(lower, IsValid(ply) and ply.organism or nil)

	local lowerSpine2 = lower:LookupBone("ValveBiped.Bip01_Spine2")
	if not lowerSpine2 then
		lower:Remove()
		return nil
	end

	-- косой разрез: плоскость по позе регдолла (до того, как кости начнут двигать)
	local frame = cut and hg.TorsoFrame(rag)
	local cutS, cutN
	if frame then cutS, cutN = CutPlane(frame, cut) else cut = nil end

	local upperPhysParents, lowerPhysParents
	if cut then
		upperPhysParents = BuildUpperCut(rag, spine2PhysID)
		lowerPhysParents = BuildLowerCut(lower)
	else
		upperPhysParents = BuildUpperHalf(rag, spine2, spine2PhysID)
		lowerPhysParents = BuildLowerHalf(lower, lowerSpine2)
	end

	rag:SetNWBool("hgTorsoSevered", true)
	if IsValid(ply) then ply:SetNWBool("hgTorsoSevered", true) end

	local offsets = STUMP_OFFSETS[ThatPlyIsFemale(IsValid(ply) and ply or rag) and 1 or 0] or STUMP_OFFSETS[0]

	local upperCap
	local upperSpinePos, upperSpineAng = GetBoneTransform(rag, spine2)
	if cut and upperSpinePos then
		local cpos, cang = LocalToWorld(offsets.upperPos, offsets.upperAng, upperSpinePos, upperSpineAng)
		local cscale
		cpos, cang, cscale = CapOnPlane(cpos, cang, offsets.upperScale, cutS, cutN, frame.up)
		local lpos, lang = WorldToLocal(cpos, cang, upperSpinePos, upperSpineAng)
		upperCap = MakeCapBoneParented(TORSO_UPPER_MODEL, rag, spine2, lpos, lang, cscale)
		SetCutNW(rag, spine2, cutS, cutN, 1)
	else
		upperCap = MakeCapBoneParented(TORSO_UPPER_MODEL, rag, spine2, offsets.upperPos, offsets.upperAng, offsets.upperScale)
	end

	local lowerCap = nil
	local lowerPelvis = lower:LookupBone("ValveBiped.Bip01_Pelvis")
	local spine2Pos, spine2Ang = GetBoneTransform(lower, lowerSpine2)
	local pelvisPos, pelvisAng
	if lowerPelvis then
		pelvisPos, pelvisAng = GetBoneTransform(lower, lowerPelvis)
	end
	if spine2Pos and spine2Ang and pelvisPos and pelvisAng then
		local capPos, capAng = LocalToWorld(offsets.lowerPos, offsets.lowerAng, spine2Pos, spine2Ang)
		local lpos, lang = WorldToLocal(capPos, capAng, pelvisPos, pelvisAng)
		lpos = lpos + offsets.lowerNudge
		local lscale = offsets.lowerScale
		if cut then
			local wpos, wang = LocalToWorld(lpos, lang, pelvisPos, pelvisAng)
			wpos, wang, lscale = CapOnPlane(wpos, wang, lscale, cutS, cutN, frame.up)
			lpos, lang = WorldToLocal(wpos, wang, pelvisPos, pelvisAng)
			SetCutNW(lower, lowerPelvis, cutS, cutN, -1)
		end
		lowerCap = MakeCap(TORSO_LOWER_MODEL, lower, lowerPelvis, lpos, lang, lscale)
	else
		lowerCap = MakeCap(TORSO_LOWER_MODEL, lower, lowerSpine2, offsets.lowerPos, offsets.lowerAng, offsets.lowerScale)
	end

	ForceHiddenPhys(rag, upperPhysParents)
	ForceHiddenPhys(lower, lowerPhysParents)

	local forceDir = force and force:LengthSqr() > 1 and force:GetNormalized() or VectorRand():GetNormalized()
	local push = math.Clamp(force and force:Length() * 0.012 or 260, 180, 620)
	local upperVelocity = spine2Phys:GetVelocity()
	spine2Phys:EnableMotion(true)
	spine2Phys:Wake()
	spine2Phys:SetVelocity(upperVelocity + forceDir * push + Vector(0, 0, 70))

	local pelvisBone = lower:LookupBone("ValveBiped.Bip01_Pelvis")
	local pelvisPhysID = pelvisBone and lower:TranslateBoneToPhysBone(pelvisBone) or 0
	local lowerRoot = lower:GetPhysicsObjectNum(pelvisPhysID or 0)
	if IsValid(lowerRoot) then
		lowerRoot:EnableMotion(true)
		lowerRoot:Wake()
		lowerRoot:SetVelocity(upperVelocity - forceDir * push * 0.45 + Vector(0, 0, 25))
		lowerRoot:AddAngleVelocity(VectorRand(-120, 120))
	end

	local state = {
		owner = ply,
		cutPos = cutS,
		rag = rag,
		lower = lower,
		upperCap = upperCap,
		lowerCap = lowerCap,
		upperPhysParents = upperPhysParents,
		lowerPhysParents = lowerPhysParents
	}
	if IsValid(ply) then
		torsoStates[ply] = state
		ply.__hgTorsoLower = lower
	end
	splitStates[state] = true

	local life = 180
	if life > 0 then SafeRemoveEntityDelayed(lower, life) end
	return state
end

local function AddTorsoTrauma(ply, rag, fromExplosion)
	local org = ply.organism
	if not org then return end
	org.torsoamputated = true
	org.llegamputated = true
	org.rlegamputated = true
	org.painadd = math.min((org.painadd or 0) + (fromExplosion and 85 or 70), 150)
	org.shock = math.max(org.shock or 0, fromExplosion and 20 or 16)
	org.internalBleed = (org.internalBleed or 0) + 24
	org.blood = math.max((org.blood or 5000) - 260, 0)
	org.needfake = true
	org.arterialwounds = org.arterialwounds or {}

	local clean = {}
	for _, wound in pairs(org.arterialwounds) do
		if wound[7] != "hg_torso_artery_a" and wound[7] != "hg_torso_artery_b" then
			clean[#clean + 1] = wound
		end
	end
	clean[#clean + 1] = {18, Vector(0, 0, 0), Angle(), "ValveBiped.Bip01_Spine1", CurTime(), Vector(-150, 0, 0), "hg_torso_artery_a"}
	clean[#clean + 1] = {16, Vector(0, 0, 0), Angle(), "ValveBiped.Bip01_Spine1", CurTime(), Vector(150, 0, 0), "hg_torso_artery_b"}
	org.arterialwounds = clean
	ply:SetNetVar("arterialwounds", clean)

	if ply.AddNaturalAdrenaline then ply:AddNaturalAdrenaline(3.5) end

	if hg.organism and hg.organism.AddWoundManual then
		for i = 1, 6 do
			hg.organism.AddWoundManual(ply, 65, VectorRand(-2.5, 2.5), AngleRand(-12, 12), "ValveBiped.Bip01_Spine1", CurTime() + math.Rand(0, 1.2))
		end
	end

	net.Start("organism_send")
	net.WriteTable({owner = ply, torsoamputated = true, llegamputated = true, rlegamputated = true})
	net.WriteBool(true)
	net.WriteBool(false)
	net.WriteBool(false)
	net.WriteBool(true)
	net.Broadcast()

	local spineBone = rag:LookupBone("ValveBiped.Bip01_Spine2")
	local splitPos = spineBone and GetBoneTransform(rag, spineBone) or nil
	if splitPos and SpawnMeatGore then
		SpawnMeatGore(rag, splitPos, 10, VectorRand(-350, 350), 1.15)
	end
	if splitPos then
		util.Decal("Blood", splitPos + Vector(0, 0, 10), splitPos - Vector(0, 0, 35), rag)
	end

	ply:EmitSound(tearSounds[math.random(#tearSounds)], 92, math.random(92, 104), 1.15)
	ply:EmitSound("physics/body/body_medium_break3.wav", 88, math.random(82, 94), 1)
	ply:Notify(PickPhrase(ply, initialPhrases, "__hgTorsoLastInitialPhrase"), 4, "hg_torso_initial", 0, nil, Color(255, 80, 70))

	local timerName = "hg_torsohalve_phrases_" .. ply:EntIndex()
	timer.Remove(timerName)
	timer.Create(timerName, 6, 7, function()
		if not IsValid(ply) or not ply:Alive() then
			timer.Remove(timerName)
			return
		end
		if not ply:GetNWBool("hgTorsoSevered", false) then
			timer.Remove(timerName)
			return
		end
		local orgNow = ply.organism
		if orgNow and not orgNow.otrub then
			local phrasePool = ((orgNow.blood or 5000) < 3000 or (orgNow.shock or 0) > 28) and criticalPhrases or painPhrases
			ply:Notify(PickPhrase(ply, phrasePool, "__hgTorsoLastPainPhrase"), 2, "hg_torso_pain", 0, nil, Color(255, 105, 95))
		end
	end)
end

local function EnsureFakeAndSplit(ply, force, fromExplosion, cut)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
	if ply:GetNWBool("hgTorsoSevered", false) or (ply.organism and ply.organism.torsoamputated) then return false end
	if ply.__hgTorsoPending then return false end
	ply.__hgTorsoPending = true

	if not IsValid(ply.FakeRagdoll) then
		if not hg.Fake then
			ply.__hgTorsoPending = nil
			return false
		end
		hg.Fake(ply)
	end

	local rag = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or (hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or nil)
	if not IsValid(rag) or not rag:IsRagdoll() then
		ply.__hgTorsoPending = nil
		return false
	end

	local state = BuildSplitRagdolls(ply, rag, force or vector_origin, cut)
	if not state then
		ply.__hgTorsoPending = nil
		return false
	end
	ply.__remCut = state.cutPos and cut or nil -- регдолл пересоздадут (смерть) - тот же разрез
	AddTorsoTrauma(ply, rag, fromExplosion)
	ply.__hgTorsoPending = nil
	return true
end

-- cut (необязательно) - косой разрез {sx, sy, ex, ey}, см. hg.TorsoFrame
function hg.AmputateTorso(ent, force, fromExplosion, cut)
	local ply = ResolvePlayer(ent)
	if not IsValid(ply) then return false end
	return EnsureFakeAndSplit(ply, force or VectorRand(-250, 250), fromExplosion == true, cut)
end

local blastMask = bit.bor(DMG_BLAST, DMG_BLAST_SURFACE or 0)

local function IsBlastDamage(dmgInfo)
	if not dmgInfo then return false end
	return bit.band(dmgInfo:GetDamageType(), blastMask) != 0
end

local function GetTorsoPosition(ply, target)
	local character = IsValid(target) and target or nil
	if not IsValid(character) or not character:IsRagdoll() then
		character = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or ply
	end
	local torsoPos = IsValid(character) and character:WorldSpaceCenter() or ply:WorldSpaceCenter()
	if IsValid(character) then
		local bone = character:LookupBone("ValveBiped.Bip01_Spine2")
		if bone then
			local pos = character:GetBonePosition(bone)
			if pos then torsoPos = pos end
		end
	end
	return torsoPos
end

local function GetExplosionOrigin(target, dmgInfo)
	local inflictor = dmgInfo:GetInflictor()
	if IsValid(inflictor) and inflictor != target and not inflictor:IsPlayer() and not inflictor:IsWeapon() and inflictor:GetClass() != "worldspawn" then
		return inflictor:WorldSpaceCenter(), true
	end
	local attacker = dmgInfo:GetAttacker()
	if IsValid(attacker) and attacker != target and not attacker:IsPlayer() and not attacker:IsWeapon() and attacker:GetClass() != "worldspawn" then
		return attacker:WorldSpaceCenter(), true
	end
	local damagePos = dmgInfo:GetDamagePosition()
	if damagePos and damagePos:LengthSqr() > 1 then return damagePos, false end
	return nil, false
end

local function FindDeathRagdoll(ply, target)
	if IsValid(target) and target:IsRagdoll() then return target end
	if IsValid(ply.RagdollDeath) then return ply.RagdollDeath end
	local nwRag = ply:GetNWEntity("RagdollDeath")
	if IsValid(nwRag) then return nwRag end
	if IsValid(ply.FakeRagdoll) then return ply.FakeRagdoll end
	return nil
end

local function SplitDeadRagdoll(ply, target, force, cut)
	local rag = (IsValid(target) and target:IsRagdoll()) and target or (IsValid(ply) and FindDeathRagdoll(ply, target))
	if not IsValid(rag) or not rag:IsRagdoll() or rag:GetNWBool("hgTorsoSevered", false) then return false end
	local state = BuildSplitRagdolls(ply, rag, force or vector_origin, cut)
	if not state then return false end
	local splitBone = rag:LookupBone("ValveBiped.Bip01_Spine2")
	local splitPos = state.cutPos or (splitBone and GetBoneTransform(rag, splitBone)) or rag:WorldSpaceCenter()
	if splitPos and SpawnMeatGore then SpawnMeatGore(rag, splitPos, 10, VectorRand(-350, 350), 1.15) end
	if splitPos then util.Decal("Blood", splitPos + Vector(0, 0, 10), splitPos - Vector(0, 0, 35), rag) end
	rag:EmitSound(tearSounds[math.random(#tearSounds)], 92, math.random(92, 104), 1.15)
	rag:EmitSound("physics/body/body_medium_break3.wav", 88, math.random(82, 94), 1)
	return true
end

local function QueueBlastTorso(target, dmgInfo)
	if not IsBlastDamage(dmgInfo) then return end
	local ply = ResolvePlayer(target)
	if not IsValid(ply) then return end
	if ply.__hgTorsoPending or ply.__hgTorsoBlastQueued or ply:GetNWBool("hgTorsoSevered", false) then return end
	if IsValid(target) and target:GetNWBool("hgTorsoSevered", false) then return end
	local attacker = dmgInfo:GetAttacker()
	if IsValid(attacker) and attacker:GetClass() == "npc_zombie" then return end

	local torsoPos = GetTorsoPosition(ply, target)
	local blastPos, reliableOrigin = GetExplosionOrigin(target, dmgInfo)
	local closeEnough = false
	if blastPos and reliableOrigin then
		closeEnough = torsoPos:DistToSqr(blastPos) <= 110 ^ 2
	elseif blastPos then
		closeEnough = torsoPos:DistToSqr(blastPos) <= 120 ^ 2 or dmgInfo:GetDamage() >= 35
	else
		closeEnough = dmgInfo:GetDamage() >= 35
	end
	if not closeEnough then return end

	local force = dmgInfo:GetDamageForce()
	local targetRef = IsValid(target) and target or nil
	local isCurrentBody = not targetRef or targetRef == ply or targetRef == ply.FakeRagdoll
	ply.__hgTorsoBlastQueued = true
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		ply.__hgTorsoBlastQueued = nil
		if ply:GetNWBool("hgTorsoSevered", false) then return end
		if IsValid(targetRef) and targetRef:GetNWBool("hgTorsoSevered", false) then return end
		if ply:Alive() and isCurrentBody then
			EnsureFakeAndSplit(ply, force, true)
		else
			SplitDeadRagdoll(ply, targetRef, force)
		end
	end)
end

-- разрезать тело: живого (его текущее тело) или труп/регдолл; cut - косой разрез (sv_meleehalve.lua)
function hg.CutTorso(target, force, cut)
	local ply = ResolvePlayer(target)
	if IsValid(target) and target:GetNWBool("hgTorsoSevered", false) then return false end
	local isCurrentBody = IsValid(ply) and (target == ply or target == ply.FakeRagdoll)
	if IsValid(ply) and ply:Alive() and isCurrentBody then
		return EnsureFakeAndSplit(ply, force, false, cut)
	end
	if IsValid(target) and target:IsRagdoll() then return SplitDeadRagdoll(ply, target, force, cut) end
	return false
end

hook.Add("EntityTakeDamage", "hg-torsohalve-blast", QueueBlastTorso)
hook.Add("PostEntityTakeDamage", "hg-torsohalve-blastpost", QueueBlastTorso)

hook.Add("Should Fake Up", "hg-torsohalve-nostand", function(ply)
	if IsValid(ply) and ply:GetNWBool("hgTorsoSevered", false) then return false end
end)

hook.Add("StartCommand", "hg-torsohalve-noduck", function(ply, cmd)
	if IsValid(ply) and ply:GetNWBool("hgTorsoSevered", false) then
		cmd:RemoveKey(IN_DUCK)
	end
end)

hook.Add("Think", "hg-torsohalve-physics", function()
	for state in pairs(splitStates) do
		local ragValid = state and IsValid(state.rag)
		local lowerValid = state and IsValid(state.lower)
		if not ragValid and not lowerValid then
			splitStates[state] = nil
		else
			if ragValid then
				ForceHiddenPhys(state.rag, state.upperPhysParents)
			end
			if lowerValid then
				ForceHiddenPhys(state.lower, state.lowerPhysParents)
				if IsValid(state.lowerCap) then UpdateCap(state.lowerCap) end
			end
		end
	end
	for ply, state in pairs(torsoStates) do
		if not IsValid(ply) or not ply:Alive() or not ply:GetNWBool("hgTorsoSevered", false) or not state then
			torsoStates[ply] = nil
		end
	end
end)

hook.Add("Ragdoll_Create", "hg-torsohalve-resplit", function(ply, rag)
	if not IsValid(ply) or not IsValid(rag) then return end
	local org = ply.organism
	if not org or not org.torsoamputated then return end
	if rag:GetNWBool("hgTorsoSevered", false) or ply.__hgTorsoPending or ply.__hgTorsoBlastQueued then return end
	timer.Simple(0, function()
		if not IsValid(ply) or not IsValid(rag) then return end
		if rag:GetNWBool("hgTorsoSevered", false) or ply.__hgTorsoPending then return end
		if ply:Alive() then
			BuildSplitRagdolls(ply, rag, vector_origin, ply.__remCut)
		else
			SplitDeadRagdoll(ply, rag, vector_origin, ply.__remCut)
		end
	end)
end)

hook.Add("Player Spawn", "hg-torsohalve-reset", function(ply)
	ply:SetNWBool("hgTorsoSevered", false)
	ply.__hgTorsoPending = nil
	ply.__hgTorsoBlastQueued = nil
	ply.__hgTorsoLower = nil
	ply.__remCut = nil
	ply.__remCutHits = nil
	ply.__hgTorsoLastInitialPhrase = nil
	ply.__hgTorsoLastPainPhrase = nil
	torsoStates[ply] = nil
	timer.Remove("hg_torsohalve_phrases_" .. ply:EntIndex())
	timer.Simple(0, function()
		if not IsValid(ply) or not ply.organism then return end
		ply.organism.torsoamputated = nil
		ply.organism.llegamputated = false
		ply.organism.rlegamputated = false
	end)
end)

hook.Add("PlayerDisconnected", "hg-torsohalve-cleanup", function(ply)
	ply.__hgTorsoBlastQueued = nil
	ply.__hgTorsoLower = nil
	torsoStates[ply] = nil
	timer.Remove("hg_torsohalve_phrases_" .. ply:EntIndex())
end)
