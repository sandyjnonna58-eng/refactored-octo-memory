-- |Z-CITY| GORE server

local vecZero = Vector(0, 0, 0)
local vecAlmostZero = Vector(0.01, 0.01, 0.01) -- same as Z-City; exact 0 gives singular bone matrices
local vecFull = Vector(1, 1, 1)
local limbRootBones = ZCityGore.LimbBones

hg.severedLimbs = hg.severedLimbs or {}

util.AddNetworkString("hg_sever_blood")
util.AddNetworkString("zcity_gore_artery")
util.AddNetworkString("zcity_gore_reset")
util.AddNetworkString("zcity_gore_artery_tear")

-- Visual textures (see MATERIALS_TO_MAKE.md). The addon falls back to procedural drawing if one is missing.
for _, name in ipairs({"artery_vessel", "artery_tear_tip", "blood_mist", "blood_spatter", "blood_drip", "blood_blob"}) do
	for _, ext in ipairs({".vmt", ".vtf"}) do
		local path = "materials/zcity_gore/" .. name .. ext
		-- with a Workshop ID set (lua/autorun/server/zcity_gore_workshop.lua) clients get everything from the Workshop
		if (ZCITY_GORE_WORKSHOP_ID or "") == "" and file.Exists(path, "GAME") then resource.AddFile(path) end
	end
end

local SEVER_LIFETIME = 600
local SEVER_MAX = 24

local zg_standup = CreateConVar("zcity_gore_standup_armless", "1", FCVAR_ARCHIVE,
	"OBSOLETE, does nothing: Z-City itself lets a player without hands stand up, and the cut arms now stay when they do", 0, 2)
local zg_limb_meat = CreateConVar("zcity_gore_limb_meat", "1", FCVAR_ARCHIVE, "Meat chunks and a wet tear sound when a limb is cut off (0 = off)", 0, 1)

local zg_crush = CreateConVar("zcity_gore_crush", "1", FCVAR_ARCHIVE,
	"Heavy impacts / crush (hit by a heavy object, flying into something at speed) tear the most damaged limbs off, like in base Z-City (0 = off)", 0, 1)

local zg_tether = CreateConVar("zcity_gore_tether", "1", FCVAR_ARCHIVE, "Severed limbs hang on an artery from the stump (0 = they fall free)", 0, 1)

-- Only this addon may sever limbs. Homigrad has several own cut paths (blast loop,
-- crush, bone damage, hitgroup damage, admin tool); they all go through AmputateLimb
-- and are ignored unless we are inside ourSever().
local severDepth = 0
local zg_debug = CreateConVar("zcity_gore_debug", "0", FCVAR_ARCHIVE, "Print every severed limb with its source to the server console", 0, 1)

local function ourSever(org, limb, dmgInfo, source)
	severDepth = severDepth + 1
	local ok, err = pcall(hg.organism.AmputateLimb, org, limb, dmgInfo)
	severDepth = severDepth - 1
	if not ok then ErrorNoHalt("[zcity_gore] " .. tostring(err) .. "\n") end
	if zg_debug:GetBool() then
		print("[zcity_gore] sever", limb, source or "?", ok and "ok" or "error")
	end
end

-- Public entry point for other addons (Withered Bon etc.): severs a limb through this addon, i.e. it
-- spawns the severed piece, amputates through Homigrad and is NOT ignored by the AmputateLimb wrapper.
-- usage: hg.ZCityGore_Sever(org, "larm"|"rarm"|"lleg"|"rleg"|"head", dmgInfo or nil, "source name")
hg.ZCityGore_Sever = ourSever

-- Every real respawn of a player starts a new "life" (counter on the player, networked). A severed piece
-- remembers the life it was cut in. Its arteries belong to the BODY of that life (the corpse), never to the
-- player entity, which is reused by the next life: otherwise a respawn yanks the hanging pieces to the spawn
-- point (the arteries rip off) and the ripped stubs get drawn on the new body forever.
local function ownerLife(owner)
	if not IsValid(owner) or not owner:IsPlayer() then return 0 end
	return owner:GetNWInt("ZCGoreLife", 0)
end
ZCityGore.OwnerLife = ownerLife

local function recursiveBone(rag, bone, list)
	for _, child in pairs(rag:GetChildBones(bone) or {}) do
		if child == 0 then continue end
		list[#list + 1] = child
		recursiveBone(rag, child, list)
	end
end

local function copyLimbAppearance(rag, src, limb)
	if src.GetSkin then rag:SetSkin(src:GetSkin()) end
	if src.GetNumBodyGroups then
		for i = 0, src:GetNumBodyGroups() - 1 do
			rag:SetBodygroup(i, src:GetBodygroup(i))
		end
	end
	rag:SetColor(src:GetColor())
	rag:SetMaterial(src:GetMaterial())
	-- Citizen Clothing / Faces Overhaul support: keep the body's outfit and face, no random re-skin (see sh_gore.lua)
	if ZCityGore.ProtectOverhaulAppearance then ZCityGore.ProtectOverhaulAppearance(rag, src) end

	local mats = src:GetMaterials()
	if mats then
		for i = 0, #mats - 1 do
			local sm = src:GetSubMaterial(i)
			if sm and sm ~= "" then rag:SetSubMaterial(i, sm) end
		end
	end

	local ply = src
	if not src:IsPlayer() then
		if src:IsNPC() or (src.IsNextBot and src:IsNextBot()) then
			ply = src -- NPC: nobody owns it, and Homigrad's RagdollOwner is only meant for ragdolls
		else
			ply = (hg.RagdollOwner and hg.RagdollOwner(src)) or src.ply or src
		end
	end

	if IsValid(ply) then
		local col = ply.GetPlayerColor and ply:GetPlayerColor() or (ply.GetNWVector and ply:GetNWVector("PlayerColor", Vector(1, 1, 1))) or Vector(1, 1, 1)
		rag:SetNWVector("PlayerColor", col)
		if ply.CurAppearance then rag.CurAppearance = table.Copy(ply.CurAppearance) end
		if limb == "head" and ply:IsPlayer() and ApplyAppearanceRagdoll then
			ApplyAppearanceRagdoll(rag, ply)
		elseif src.GetNetVar then
			rag:SetNetVar("Accessories", src:GetNetVar("Accessories", ""))
		end
	end
end

local function pruneSeveredLimbs()
	local list = {}
	for rag, data in pairs(hg.severedLimbs) do
		if IsValid(rag) then
			list[#list + 1] = {rag = rag, spawned = data.spawned or 0, held = rag:IsPlayerHolding()}
		end
	end
	local extra = #list - SEVER_MAX
	if extra <= 0 then return end
	table.sort(list, function(a, b) return a.spawned < b.spawned end)
	for i = 1, #list do
		if extra <= 0 then break end
		if list[i].held then continue end
		if IsValid(list[i].rag) then list[i].rag:Remove() end
		extra = extra - 1
	end
end

hook.Add("Think", "zcity_gore_severed_limbs", function()
	for rag, data in pairs(hg.severedLimbs) do
		if not IsValid(rag) then
			hg.severedLimbs[rag] = nil
			continue
		end
		if (data.spawned or 0) + SEVER_LIFETIME < CurTime() then
			if rag:IsPlayerHolding() then
				data.spawned = CurTime() - SEVER_LIFETIME + 45
			else
				rag:Remove()
				hg.severedLimbs[rag] = nil
				continue
			end
		end
		local root = rag:GetPhysicsObjectNum(data.root)
		if not IsValid(root) then continue end
		local pos, ang = root:GetPos(), root:GetAngles()
		for i = 1, #data.hidden do
			local phys = rag:GetPhysicsObjectNum(data.hidden[i])
			if not IsValid(phys) then continue end
			phys:SetPos(pos)
			phys:SetAngles(ang)
		end
	end
end)

function hg.HideHeadBones(ent)
	if not IsValid(ent) then return end
	local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
	if not bone then return end
	local function rec(b)
		ent:ManipulateBoneScale(b, vecZero)
		for _, kid in ipairs(ent:GetChildBones(b) or {}) do
			rec(kid)
		end
	end
	rec(bone)
end

function hg.SpawnSeveredLimb(src, limb, dmgInfo)
	if not IsValid(src) then return end
	local rootName = limbRootBones[limb]
	if not rootName or not src:LookupBone(rootName) then return end

	local rag = ents.Create("prop_ragdoll")
	if not IsValid(rag) then return end

	rag:SetModel(src:GetModel())
	rag:SetPos(src:GetPos())
	rag:SetAngles(src:GetAngles())
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	rag:Spawn()
	rag:Activate()
	rag:AddEFlags(EFL_DONTBLOCKLOS)

	rag.IsSeveredLimb = true
	rag.severedLimb = limb
	rag.organism = nil
	rag.ply = nil
	rag:SetNWBool("IsSeveredLimb", true)
	rag:SetNWString("SeveredLimb", limb)
	rag:SetNWFloat("SeverBleedUntil", CurTime() + (limb == "head" and 18 or 8))

	copyLimbAppearance(rag, src, limb)

	local rootBone = rag:LookupBone(rootName)
	if not rootBone then rag:Remove() return end

	local keepBones = {rootBone}
	recursiveBone(rag, rootBone, keepBones)
	local keepLookup = {}
	for _, boneid in ipairs(keepBones) do keepLookup[boneid] = true end

	local keepPhys, hiddenPhys, rootPhysNum = {}, {}, nil

	for physNum = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(physNum)
		if not IsValid(phys) then continue end
		local bone = rag:TranslatePhysBoneToBone(physNum)
		if not bone then continue end
		local pos, ang = src:GetBonePosition(bone)
		if (not pos or pos == src:GetPos()) and src.GetBoneMatrix then
			local matrix = src:GetBoneMatrix(bone)
			if matrix then pos, ang = matrix:GetTranslation(), matrix:GetAngles() end
		end
		if pos then
			phys:SetPos(pos)
			phys:SetAngles(ang or angle_zero)
		end
		phys:Wake()
		if keepLookup[bone] then
			keepPhys[physNum] = true
			if bone == rootBone then rootPhysNum = physNum end
		else
			hiddenPhys[#hiddenPhys + 1] = physNum
		end
	end

	if not rootPhysNum then
		for physNum in pairs(keepPhys) do rootPhysNum = physNum break end
	end
	if not rootPhysNum then rag:Remove() return end

	local rootPhys = rag:GetPhysicsObjectNum(rootPhysNum)

	for boneid = 0, rag:GetBoneCount() - 1 do
		if not keepLookup[boneid] then rag:ManipulateBoneScale(boneid, vecAlmostZero) end
	end

	rag:RemoveInternalConstraint(rootPhysNum)

	for i = 1, #hiddenPhys do
		local phys = rag:GetPhysicsObjectNum(hiddenPhys[i])
		if not IsValid(phys) then continue end
		rag:RemoveInternalConstraint(hiddenPhys[i])
		phys:SetPos(rootPhys:GetPos())
		phys:SetAngles(rootPhys:GetAngles())
		phys:EnableCollisions(false)
		phys:EnableMotion(false)
		phys:EnableGravity(false)
		phys:SetMass(0.01)
	end

	for physNum in pairs(keepPhys) do
		local phys = rag:GetPhysicsObjectNum(physNum)
		if not IsValid(phys) then continue end
		phys:EnableMotion(true)
		phys:EnableGravity(true)
		if physNum == rootPhysNum then
			phys:EnableCollisions(true)
			phys:SetMass(ZCityGore.LimbRootMass or 14)
		else
			phys:EnableCollisions(false)
			phys:SetMass(ZCityGore.LimbPartMass or 4)
		end
	end

	-- Does this piece stay on an artery? (not for explosions: they tear it clean off)
	local isBlast = dmgInfo ~= nil and dmgInfo:IsDamageType(DMG_BLAST)
	local tetherOwner = src
	if src:IsRagdoll() and isfunction(hg.RagdollOwner) then
		local ply = hg.RagdollOwner(src)
		if IsValid(ply) then tetherOwner = ply end
	end
	local tethered = zg_tether:GetBool()
		and ZCityGore.TetherLimbs[limb] == true
		and (ZCityGore.TetherOnBlast or not isBlast)

	-- the client draws the ragged artery ends on the stump and on the piece, so it must know the body
	rag:SetNWEntity("SeveredBody", tetherOwner)
	rag:SetNWInt("ZCArteryTorn", 0)
	if not tethered then
		-- torn clean off: every artery is already ripped
		rag:SetNWInt("ZCArteryTorn", ZCityGore.FullArteryMask(ZCityGore.LimbArteries))
		rag:SetNWFloat("ZCArteryTearTime", CurTime())
	end

	local force = Vector(0, 0, 50)
	if dmgInfo then
		local blast = isBlast
		local dir = dmgInfo:GetDamageForce()
		local origin = dmgInfo:GetDamagePosition()
		if blast then
			if not origin or origin:LengthSqr() < 1 then
				local inf = dmgInfo:GetInflictor()
				origin = IsValid(inf) and inf:GetPos() or src:WorldSpaceCenter()
			end
			local away = rootPhys:GetPos() - origin
			if away:LengthSqr() < 16 then
				away = VectorRand(-1, 1)
				away.z = math.abs(away.z) + 0.2
			end
			away:Normalize()
			force = away * math.Rand(520, 860) + Vector(0, 0, math.Rand(220, 380)) + VectorRand(-90, 90)
		elseif dir and dir:LengthSqr() > 1 then
			force = dir:GetNormalized() * 280 + Vector(0, 0, 70)
		else
			local att = dmgInfo:GetAttacker()
			if IsValid(att) then force = att:GetAimVector() * 280 + Vector(0, 0, 70) end
		end
	end
	-- a limb on an artery just drops and swings instead of flying off and being yanked back
	if tethered then force = force * (ZCityGore.TetherThrowMul or 0.2) end
	force = force + VectorRand(-40, 40)

	local srcVel = src:GetVelocity()
	local function applyLimbForce()
		if not IsValid(rag) then return end
		for physNum in pairs(keepPhys) do
			local phys = rag:GetPhysicsObjectNum(physNum)
			if not IsValid(phys) then continue end
			phys:Wake()
			phys:SetVelocity(srcVel + force)
			phys:AddAngleVelocity(VectorRand(-200, 200))
		end
	end
	applyLimbForce()
	timer.Simple(0, applyLimbForce)

	rag.severedRootPhys = rootPhysNum
	rag:SetNWInt("SeveredRootPhys", rootPhysNum)
	-- owner / life: which body (and which life of it) this piece hangs from, see ownerLife()
	local sdata = {root = rootPhysNum, hidden = hiddenPhys, spawned = CurTime(), owner = tetherOwner, life = ownerLife(tetherOwner)}
	rag:SetNWInt("SeveredLife", sdata.life)
	hg.severedLimbs[rag] = sdata
	rag:CallOnRemove("severed_limb_cleanup", function(ent) hg.severedLimbs[ent] = nil end)

	if tethered and IsValid(tetherOwner) then
		local len = (ZCityGore.TetherLength and ZCityGore.TetherLength[limb]) or 12
		sdata.tether = {owner = tetherOwner, limb = limb, len = len}
		rag:SetNWBool("SeveredTethered", true)
		rag:SetNWFloat("SeveredTetherLen", len)
		-- damping so the dangling piece swings and settles instead of spinning forever
		for physNum in pairs(keepPhys) do
			local phys = rag:GetPhysicsObjectNum(physNum)
			if IsValid(phys) then phys:SetDamping(0.05, 1.5) end
		end
	end

	-- Remove this limb when the body it was cut from gets removed (corpse cleanup etc.)
	if IsValid(src) then
		local parentId = "zcity_gore_parent_" .. rag:EntIndex()
		src:CallOnRemove(parentId, function()
			if not IsValid(rag) then return end
			-- A killed NPC is removed once its ragdoll exists. The piece stays and moves over to that corpse
			-- (see sv_npc.lua); an NPC removed while alive (cleanup) still takes its pieces with it.
			if (src:IsNPC() or (src.IsNextBot and src:IsNextBot())) and src:Health() <= 0 then return end
			-- Standing up removes the victim's fake ragdoll. The cut piece must stay: it keeps hanging from the
			-- stump of the standing player (the tether follows the player, see ZCityGore.ResolveBody).
			-- Only a really gone body (corpse cleanup, disconnect, a new round) takes its pieces with it.
			if src ~= tetherOwner and IsValid(tetherOwner) and tetherOwner:IsPlayer() and tetherOwner:Alive()
				and (tetherOwner.FakeRagdollOld == src or src.override) then
				return
			end
			rag:Remove()
		end)
		rag:CallOnRemove("zcity_gore_parent_unhook", function()
			if IsValid(src) then src:RemoveCallOnRemove(parentId) end
		end)
	end
	rag:AddCallback("PhysicsCollide", function(ent, data)
		if data.DeltaTime < 0.2 then return end
		ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav")
		util.Decal("Normal.Blood24", data.HitPos - data.HitNormal, data.HitPos + data.HitNormal, ent)
	end)

	pruneSeveredLimbs()
	if src:IsPlayer() and src.FakeRagdoll == rag then
		src.FakeRagdoll = nil
	end
	timer.Simple(0, function()
		if not IsValid(rag) then return end
		rag.organism = nil
		rag.ply = nil
		if src:IsPlayer() and src.FakeRagdoll == rag then
			src.FakeRagdoll = nil
		end
	end)
	return rag
end

local stumpBones = {
	head = {"ValveBiped.Bip01_Neck1", Vector(5, 0, 0)},
	larm = {"ValveBiped.Bip01_L_UpperArm", Vector(11, 0, 0)},
	rarm = {"ValveBiped.Bip01_R_UpperArm", Vector(11, 0, 0)},
	lleg = {"ValveBiped.Bip01_L_Thigh", Vector(16, 0, 0)},
	rleg = {"ValveBiped.Bip01_R_Thigh", Vector(16, 0, 0)},
}

-- ---------------------------------------------------------------------------
-- Progressive artery tearing.
-- Every strand of the bundle (3 for a limb, 5 for the torso) rips at its own stretch ratio. The server is the
-- authority: it keeps the torn strands as a bit mask on the hanging piece (ZCArteryTorn), so every client -
-- also one that joins later - draws the same intact strands and ragged stubs. The tether loses pull strength
-- with every strand that rips; when the last one goes the piece falls free.
-- ---------------------------------------------------------------------------
local kf2Tear = {}
for i = 1, 7 do
	local snd = "gore/kf2_tear" .. i .. ".wav"
	if file.Exists("sound/" .. snd, "GAME") then kf2Tear[#kf2Tear + 1] = snd end
end

local function tearSfx(ent, final)
	if not IsValid(ent) then return end
	if final then
		if #kf2Tear > 0 then ent:EmitSound(kf2Tear[math.random(#kf2Tear)], 82, math.random(94, 106), 1) end
		ent:EmitSound("physics/body/body_medium_break3.wav", 80, math.random(86, 100), 1)
		ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 78, math.random(70, 85), 1)
	else
		-- one strand: a short wet snap
		ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 70, math.random(125, 150), 0.9)
		if math.random() < 0.5 then
			ent:EmitSound("physics/body/body_medium_break" .. math.random(2, 4) .. ".wav", 62, math.random(130, 160), 0.5)
		end
	end
end
ZCityGore.TearSfx = tearSfx

local function sendTear(ent, strand, final, torso)
	net.Start("zcity_gore_artery_tear")
	net.WriteUInt(ent:EntIndex(), 16)
	net.WriteUInt(strand, 4)
	net.WriteBool(final)
	net.WriteBool(torso)
	net.Broadcast()
end

-- t = tether table ({len = ...}), defs = ZCityGore.LimbArteries / TorsoArteries, ent = the hanging piece
-- returns snapped (the last strand just ripped), remaining pull fraction (1 = all strands intact)
function ZCityGore.StepArteryTear(t, defs, dist, snapMul, ent, torso)
	t.torn = t.torn or {}
	t.tornCount = t.tornCount or 0
	local n = #defs
	local ratio = dist / math.max(t.len, 0.01)

	-- wet creak while the bundle is being stretched
	if ratio > 1.25 and (t.nextCreak or 0) < CurTime() and IsValid(ent) then
		t.nextCreak = CurTime() + math.Rand(0.35, 0.7)
		ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 55, math.random(55, 75), 0.35)
	end

	local changed = false
	for i = 1, n do
		if not t.torn[i] and ratio >= ZCityGore.TearRatio(defs[i], snapMul) then
			t.torn[i] = true
			t.tornCount = t.tornCount + 1
			changed = true
			local final = t.tornCount >= n
			if IsValid(ent) then
				sendTear(ent, i, final, torso == true)
				tearSfx(ent, final)
			end
		end
	end
	if changed and IsValid(ent) then
		local mask = 0
		for i = 1, n do
			if t.torn[i] then mask = mask + bit.lshift(1, i - 1) end
		end
		ent:SetNWInt("ZCArteryTorn", mask)
		ent:SetNWFloat("ZCArteryTearTime", CurTime())
	end
	return t.tornCount >= n, 1 - t.tornCount / n
end

-- ---------------------------------------------------------------------------
-- Artery tether: acts like a rope between the stump and the cut face of the severed piece.
-- It is slack until the piece is `len` units away, then it cancels the outward velocity and
-- pulls the cut face back (applied AT the cut face, so the limb hangs from it like a pendulum).
-- ---------------------------------------------------------------------------
local function detachTether(rag, data)
	if data then data.tether = nil end
	if IsValid(rag) then rag:SetNWBool("SeveredTethered", false) end
end

-- World position of the stump on the body (same point the client uses for the artery)
local function stumpAnchor(body, limb)
	local info = stumpBones[limb]
	if not info or not IsValid(body) then return end
	local bone = body:LookupBone(info[1])
	if not bone then return end
	local pos, ang = body:GetBonePosition(bone)
	if (not pos or pos == body:GetPos()) and body.GetBoneMatrix then
		local m = body:GetBoneMatrix(bone)
		if m then pos, ang = m:GetTranslation(), m:GetAngles() end
	end
	if not pos then return end
	return (LocalToWorld(info[2], angle_zero, pos, ang or angle_zero))
end

-- The body this piece hangs from RIGHT NOW. While the owner lives (or lies dead as a corpse of the same life)
-- that is whatever ResolveBody() says, and the corpse is remembered. Once the player respawned (new life) the
-- piece stays with the remembered corpse and never follows the new body.
local function resolveBody(data, t)
	local owner = t.owner
	if not IsValid(owner) then return IsValid(data.corpse) and data.corpse or nil end
	if owner:IsPlayer() then
		if ownerLife(owner) ~= data.life then
			return IsValid(data.corpse) and data.corpse or nil
		end
		local body = ZCityGore.ResolveBody(owner)
		if IsValid(body) and body ~= owner and not owner:Alive() then data.corpse = body end
		return body
	end
	return ZCityGore.ResolveBody(owner)
end

local function tetherStep(rag, data)
	local t = data.tether
	local root = rag:GetPhysicsObjectNum(data.root)
	if not IsValid(root) then return end

	if not IsValid(t.owner) and not IsValid(data.corpse) then return detachTether(rag, data) end
	-- t.body: set when the torso was cut and this leg now belongs to the lower half
	local body = IsValid(t.body) and t.body or resolveBody(data, t)
	if not IsValid(body) then
		-- e.g. a player just died and the corpse ragdoll does not exist yet
		t.lost = t.lost or CurTime()
		if CurTime() - t.lost > 2 then detachTether(rag, data) end
		return
	end
	t.lost = nil

	local anchor = stumpAnchor(body, t.limb)
	if not anchor then return end
	-- the bone can be hidden at NaN (upper half of a cut torso has no legs): never feed NaN to physics
	if anchor.x ~= anchor.x or anchor.y ~= anchor.y or anchor.z ~= anchor.z then
		return detachTether(rag, data)
	end

	local cut = root:GetPos() -- the cut face (elbow / knee) is the origin of the root physics bone
	local delta = anchor - cut
	local dist = delta:Length()
	-- strands rip one after another; the last one lets go of the piece
	local snapped, remain = ZCityGore.StepArteryTear(t, ZCityGore.LimbArteries, dist, ZCityGore.TetherSnapMul or 2.5, rag, false)
	if snapped then return detachTether(rag, data) end
	if dist <= t.len or dist < 0.01 then return end -- slack
	if rag:IsPlayerHolding() then return end -- let the player carry it; walking away snaps the artery

	local dir = delta / dist
	local rel = root:GetVelocityAtPoint(cut) - body:GetVelocity()
	local out = -rel:Dot(dir) -- speed at which the cut face moves away from the stump
	local pull = math.min((dist - t.len) * 8, ZCityGore.TetherPullSpeed or 140)
	local dv = math.min(pull + out, 600)
	if dv <= 0 then return end
	-- every ripped artery takes some of the pull with it
	root:ApplyForceOffset(dir * dv * root:GetMass() * 1.3 * (0.35 + 0.65 * remain), cut)
end

hook.Add("Think", "zcity_gore_tether", function()
	for rag, data in pairs(hg.severedLimbs) do
		if data.tether and IsValid(rag) then
			local ok, err = pcall(tetherStep, rag, data)
			if not ok then
				detachTether(rag, data)
				ErrorNoHalt("[zcity_gore] tether: " .. tostring(err) .. "\n")
			end
		end
	end
end)

-- Tell the clients which corpse a piece belongs to once its player died, so that after the respawn the arteries
-- (and the ripped stubs) stay on that corpse and are not drawn on the new body (see BundleFor in cl_artery.lua).
local nextCorpseScan = 0

-- Remember (and network) the body every piece of `only` (or of everyone) currently hangs from. Works while the
-- owner is dead, and also at the very moment of a respawn, so a fast respawn can't beat the periodic scan.
local function linkCorpses(only, allowAlive)
	for rag, data in pairs(hg.severedLimbs) do
		local o = data.owner
		if IsValid(rag) and IsValid(o) and o:IsPlayer() and (not only or o == only)
			and (allowAlive or not o:Alive()) and ownerLife(o) == data.life then
			local body = ZCityGore.ResolveBody(o)
			if IsValid(body) and body ~= o and body ~= data.corpse then
				data.corpse = body
				rag:SetNWEntity("SeveredCorpse", body)
			end
		end
	end
end
ZCityGore.LinkCorpses = linkCorpses

hook.Add("Think", "zcity_gore_corpse_links", function()
	local ct = CurTime()
	if ct < nextCorpseScan then return end
	nextCorpseScan = ct + 0.2
	linkCorpses()
end)

-- The death ragdoll can show up a few ticks after the death: look for it right away instead of waiting for the scan
hook.Add("PlayerDeath", "zcity_gore_corpse_links", function(ply)
	for _, delay in ipairs({0, 0.05, 0.15, 0.4}) do
		timer.Simple(delay, function()
			if IsValid(ply) then linkCorpses(ply) end
		end)
	end
end)

local function sendArtery(ent, limb)
	if not IsValid(ent) or not stumpBones[limb] then return end
	net.Start("zcity_gore_artery")
	net.WriteUInt(ent:EntIndex(), 16)
	net.WriteString(limb)
	net.WriteFloat(CurTime() + (limb == "head" and 10 or 8))
	net.Broadcast()
end

local function sendSeverBlood(ent, limb, cutPos, force)
	if not IsValid(ent) then return end
	net.Start("hg_sever_blood")
	net.WriteEntity(ent)
	net.WriteString(limb or "")
	net.WriteVector(cutPos or ent:GetPos())
	net.WriteVector(force or vector_origin)
	net.Broadcast()
end

local blastLimbOrder = {"larm", "rarm", "lleg", "rleg", "head"}

local function hideHeadMesh(target)
	if not IsValid(target) then return end
	if target.IsSeveredLimb or (target.GetNWBool and target:GetNWBool("IsSeveredLimb")) then return end
	if hg.HideHeadBones then hg.HideHeadBones(target) end
	target.noHead = true
	if target.SetNWBool then target:SetNWBool("noHead", true) end
end

local function hideHeadEverywhere(owner, ent)
	hideHeadMesh(ent)
	hideHeadMesh(owner)
	if not IsValid(owner) then return end
	hideHeadMesh(owner.FakeRagdoll)
	if owner:IsPlayer() and isfunction(owner.GetRagdollEntity) then
		hideHeadMesh(owner:GetRagdollEntity())
	end
	if owner.GetNWEntity then
		hideHeadMesh(owner:GetNWEntity("FakeRagdoll"))
		hideHeadMesh(owner:GetNWEntity("RagdollDeath"))
	end
	if isfunction(hg.GetCurrentCharacter) then
		hideHeadMesh(hg.GetCurrentCharacter(owner))
	end
end

local function killOwner(owner)
	if not IsValid(owner) or not owner:IsPlayer() then return end
	local org = owner.organism
	if org then
		org.alive = false
		org.brain = 0
		org.heartstop = true
		org.otrub = true
	end
	if owner:Alive() then
		owner:SetHealth(0)
		owner:Kill()
	end
end

-- Player and corpse have different organism tables; normalise to the player
local function bodyBase(e)
	if not IsValid(e) then return end
	if e:IsRagdoll() and isfunction(hg.RagdollOwner) then
		local ply = hg.RagdollOwner(e)
		if IsValid(ply) then return ply end
	end
	return e
end

-- Short window after a blast in which Homigrad's own blast gore is suppressed
local BLAST_WINDOW = 2

local function markBlast(e)
	if not IsValid(e) then return end
	local untilT = CurTime() + BLAST_WINDOW
	e._zgBlastUntil = untilT
	local base = bodyBase(e)
	if IsValid(base) then base._zgBlastUntil = untilT end
end

local function recentlyBlasted(e)
	if not IsValid(e) then return false end
	local now = CurTime()
	if (e._zgBlastUntil or 0) > now then return true end
	local base = bodyBase(e)
	return IsValid(base) and (base._zgBlastUntil or 0) > now
end

local function hideHeadOnBody(org, owner, ent)
	if not org then return end
	org.headamputated = true
	hideHeadEverywhere(owner, ent)
	killOwner(owner)
end

-- Chance that a given limb is torn off, by distance from the explosion:
-- full chance up to BlastCloseRange, falling linearly to BlastFarChance at BlastRange.
local function blastLimbChance(dist)
	local close = ZCityGore.BlastCloseRange or 120
	local range = ZCityGore.BlastRange or 300
	local far = ZCityGore.BlastFarChance or 0.35
	if dist <= close then return 1 end
	if dist >= range then return far end
	return Lerp((dist - close) / (range - close), 1, far)
end

local function blastDismember(org, dmgInfo, dist)
	if not org then return end
	if not istable(hg) or not hg.organism or not isfunction(hg.organism.AmputateLimb) then return end

	-- The player and their corpse ragdoll have separate organism tables, and one explosion
	-- reaches both. Dedupe per body (per player) within a short window.
	local base = bodyBase(org.owner) or org.owner
	if not IsValid(base) then return end
	if (base._zgBlastAt or 0) > CurTime() - 1 then return end
	base._zgBlastAt = CurTime()

	-- Very close blast: the torso is cut in half first (the legs go with the lower half), then the
	-- arms are rolled like any other limb. Must never break the limb blast, hence the pcall.
	local torsoCut = false
	if isfunction(ZCityGore.SeverTorso) and ZCityGore.TorsoBlastEnabled()
		and (dist or 9999) <= ZCityGore.TorsoBlastRadius() and not org.torsoamputated then
		local force = dmgInfo and dmgInfo.GetDamageForce and dmgInfo:GetDamageForce() or vector_origin
		local ok, split = pcall(ZCityGore.SeverTorso, base, force, true)
		if ok and split then
			torsoCut = true
			-- the player's and the corpse's organism are separate tables: flag this one too
			org.torsoamputated = true
			org.llegamputated = true
			org.rlegamputated = true
		elseif ok and IsValid(base) and base:IsPlayer() and not base:Alive() then
			-- the corpse ragdoll may not exist yet this tick: try once more
			timer.Simple(0.15, function()
				if IsValid(base) then pcall(ZCityGore.SeverTorso, base, force, true) end
			end)
		end
	end

	-- Collect limbs that are still attached (head is never taken by explosions)
	local candidates = {}
	for i = 1, #blastLimbOrder do
		local limb = blastLimbOrder[i]
		if limb ~= "head" and org[limb .. "amputated"] ~= true then
			candidates[#candidates + 1] = limb
		end
	end
	if #candidates == 0 then
		if not (torsoCut and not ZCityGore.TorsoBlastKills) then killOwner(org.owner) end
		return
	end

	local chance = blastLimbChance(dist or 0)
	local chosen = {}
	for i = 1, #candidates do
		if math.random() < chance then chosen[#chosen + 1] = candidates[i] end
	end
	-- always at least one limb
	if #chosen == 0 then chosen[1] = candidates[math.random(#candidates)] end

	for i = 1, #chosen do
		local limb = chosen[i]
		org[limb .. "amputated"] = false
		ourSever(org, limb, dmgInfo, "blast")
	end

	-- a cut torso leaves the victim alive and screaming (like the c-menu cut) unless configured otherwise
	if torsoCut and not ZCityGore.TorsoBlastKills then return end
	killOwner(org.owner)
end

local function wrapAmputate()
	if not hg or not hg.organism or not isfunction(hg.organism.AmputateLimb) then return false end

	-- Homigrad blows the head off any corpse hit by a blast; explosions must not take the head
	-- Wrappers are re-installed over the original Homigrad function every time,
	-- so a lua refresh of this file replaces the old wrapper instead of being ignored
	if isfunction(hg.ExplodeHead) then
		if hg.ExplodeHead ~= hg.ZCityGore_HeadWrapper then
			hg.ZCityGore_BaseExplodeHead = hg.ExplodeHead
		end
		local oldHead = hg.ZCityGore_BaseExplodeHead
		hg.ZCityGore_HeadWrapper = function(ent, ...)
			if recentlyBlasted(ent) then return end
			return oldHead(ent, ...)
		end
		hg.ExplodeHead = hg.ZCityGore_HeadWrapper
	end

	-- old versions of this file left their wrapper in place with only ZCityGore_WrappedAmp set
	local cur = hg.organism.AmputateLimb
	local isOurs = cur == hg.ZCityGore_AmpWrapper
		or (hg.ZCityGore_WrappedAmp and not hg.ZCityGore_AmpWrapper and hg.ZCityGore_BaseAmputate ~= nil)
	if not isOurs then
		hg.ZCityGore_BaseAmputate = cur
	end
	local old = hg.ZCityGore_BaseAmputate
	hg.ZCityGore_AmpWrapper = function(org, limb, dmgInfo)
		if not org or not limbRootBones[limb] then return end
		if org[limb .. "amputated"] == true then return end
		local owner = org.owner
		if not IsValid(owner) then return end
		local ent = hg.GetCurrentCharacter and hg.GetCurrentCharacter(owner) or owner

		-- Every cut that is not ours is ignored (Homigrad blast / hitgroup damage stack / admin), with one
		-- exception: Z-City's own crush rule (modules_input/sv_bone.lua: DMG_CRUSH on an arm or a leg that
		-- takes more than it can bear = heavy object, vehicle, or the ragdoll slamming into something at speed).
		-- That one goes through here too, so the limb comes off as one of our hanging, arterial pieces.
		if severDepth <= 0 then
			if not zg_crush:GetBool() then return end
			local caller = debug.getinfo(2, "S")
			local path = caller and caller.short_src or ""
			if not string.find(path, "sv_bone", 1, true) then return end
			if limb == "head" or recentlyBlasted(ent) or recentlyBlasted(owner) then return end
			if zg_debug:GetBool() then print("[zcity_gore] crush sever", limb, path) end
		end

		-- one severed piece per limb per body, even if both the player's and the corpse's organism ask
		local base = bodyBase(owner) or owner
		base._zgSevered = base._zgSevered or {}
		if base._zgSevered[limb] then
			org[limb .. "amputated"] = true
			if limb == "head" then hideHeadEverywhere(owner, ent) end
			return
		end
		base._zgSevered[limb] = true

		local blast = dmgInfo and isfunction(dmgInfo.IsDamageType) and dmgInfo:IsDamageType(DMG_BLAST)
		local rag
		if IsValid(ent) then
			local ok, res = pcall(hg.SpawnSeveredLimb, ent, limb, dmgInfo)
			if ok and IsValid(res) then rag = res end
		end

		-- Homigrad's base cut also spawns its own gore; mute it, we spawn our own piece
		local oldLevel = hg.GetGoreLevel
		hg.GetGoreLevel = function() return 0 end
		pcall(old, org, limb, dmgInfo)
		hg.GetGoreLevel = oldLevel

		org[limb .. "amputated"] = true
		if limb == "head" then
			hideHeadOnBody(org, owner, ent)

			-- same burst effect Homigrad uses for a beheading (client explodes at the neck)
			if IsValid(ent) then
				local force = (dmgInfo and isfunction(dmgInfo.GetDamageForce) and dmgInfo:GetDamageForce()) or vector_origin
				net.Start("addfountain")
				net.WriteEntity(ent)
				net.WriteVector(force)
				net.Broadcast()
			end
		end
		-- arterial spray only from the severed piece's cut face. Spraying on the body
		-- leaves Arterial.Blood decals stuck to the leg of the corpse.
		-- (arterial spray is driven by the client from the artery bundle, see cl_artery.lua)

		if not blast and IsValid(ent) then
			local boneName = limbRootBones[limb]
			local boneid = boneName and ent:LookupBone(boneName)
			local cutPos = boneid and select(1, ent:GetBonePosition(boneid)) or ent:GetPos()
			local force = (dmgInfo and isfunction(dmgInfo.GetDamageForce) and dmgInfo:GetDamageForce()) or vector_origin
			sendSeverBlood(ent, limb, cutPos, force)
			if zg_limb_meat:GetBool() then
				if SpawnMeatGore and limb ~= "head" then
					pcall(SpawnMeatGore, ent, cutPos, 4, VectorRand(-260, 260), 0.8)
				end
				tearSfx(IsValid(rag) and rag or ent, true)
			end
		end
	end
	hg.organism.AmputateLimb = hg.ZCityGore_AmpWrapper
	hg.organism.BlastDismember = blastDismember
	hg.ZCityGore_WrappedAmp = true
	return true
end

local function patchWeapons()
	for class in pairs(ZCityGore.Weapons) do
		local stored = weapons.GetStored(class)
		if stored then stored.CanSeverLimbs = true end
	end
	for _, wep in ipairs(ents.FindByClass("weapon_*")) do
		if ZCityGore.Weapons[wep:GetClass()] then
			wep.CanSeverLimbs = true
		end
	end
end

-- Hits needed for this inflictor, or nil if it cannot sever at all
local function hitsForWeapon(inf)
	if IsValid(inf) and inf:IsPlayer() then inf = inf:GetActiveWeapon() end
	if not IsValid(inf) then return end
	local n = ZCityGore.WeaponHits[inf:GetClass()]
	if n then return n end
	if inf.CanSeverLimbs or (inf.IsWeapon and inf:IsWeapon()) then
		return ZCityGore.DefaultSharpHits or 12
	end
end

-- World position of a limb's joint (elbow / knee / neck) on this body
local function jointPos(ent, limb)
	local boneName = ZCityGore.JointBones[limb]
	local bone = boneName and ent:LookupBone(boneName)
	if not bone then return end
	local jpos = ent:GetBonePosition(bone)
	if (not jpos or jpos == ent:GetPos()) and ent.GetBoneMatrix then
		local m = ent:GetBoneMatrix(bone)
		if m then jpos = m:GetTranslation() end
	end
	return jpos
end

local function jointRadius(limb)
	return limb == "head" and (ZCityGore.HeadJointRadius or 7) or (ZCityGore.JointRadius or 7)
end

-- Is the hit close enough to the joint (elbow / knee / neck) of this limb?
local function nearJoint(ent, limb, dmgInfo)
	if not IsValid(ent) then return true end
	local jpos = jointPos(ent, limb)
	local hpos = dmgInfo:GetDamagePosition()
	if not jpos or not hpos or hpos:LengthSqr() < 1 then return true end -- unknown position: do not block
	local radius = jointRadius(limb)
	local dist = jpos:Distance(hpos)
	if zg_debug:GetBool() then
		print(string.format("[zcity_gore] %s joint distance %.1f (max %.1f)", limb, dist, radius))
	end
	return dist <= radius
end

local function trySever(org, dmgInfo, limb, ent)
	if not org or not limbRootBones[limb] then return false end
	-- remorse: голову режет organism/sv_decap.lua, пока zcity_gore_head_chop 0
	if limb == "head" and not GetConVar("zcity_gore_head_chop"):GetBool() then return false end
	if org[limb .. "amputated"] == true then return false end
	if not dmgInfo or not dmgInfo:IsDamageType(DMG_SLASH) then return false end
	local hits = hitsForWeapon(dmgInfo:GetInflictor())
	if not hits then return false end
	if not nearJoint(ent, limb, dmgInfo) then return false end

	org.severprogress = org.severprogress or {larm = 0, rarm = 0, lleg = 0, rleg = 0, head = 0}
	org.severNext = org.severNext or {}
	if (org.severNext[limb] or 0) > CurTime() then return false end
	org.severNext[limb] = CurTime() + 0.35

	if limb == "head" then hits = hits * (ZCityGore.HeadHitsMul or 2) end
	-- each hit is worth 1/hits of a cut; mixed weapons add up
	org.severprogress[limb] = (org.severprogress[limb] or 0) + 1 / hits
	if zg_debug:GetBool() then
		print("[zcity_gore] chop", limb, string.format("%.2f/1", org.severprogress[limb]))
	end
	if org.severprogress[limb] < 0.999 then return false end
	ourSever(org, limb, dmgInfo, "slash")
	return true
end

-- NPCs and NPC corpses are handled by sv_npc.lua (they have no organism, the player paths below must not touch them)
local function isNpcBody(e)
	return IsValid(e) and (e:IsNPC() or e.__zgNpcCorpse == true or (e.IsNextBot and e:IsNextBot()))
end

hook.Add("HomigradDamage", "zcity_gore_chop", function(ply, dmgInfo, hitgroup, ent)
	if isNpcBody(ent) then return end
	if not isnumber(hitgroup) then return end
	local limb = ZCityGore.HitgroupToLimb[hitgroup]
	if not limb or not limbRootBones[limb] then return end
	local org = (IsValid(ent) and ent.organism) or (IsValid(ply) and ply.organism)
	if not org then return end
	trySever(org, dmgInfo, limb, (IsValid(ent) and ent) or ply)
end)

-- Dead bodies: Homigrad does not run HomigradDamage for a corpse ragdoll (it has no living owner
-- any more), so chop corpses straight from EntityTakeDamage. Living / unconscious players keep
-- going through the HomigradDamage hook above.
hook.Add("EntityTakeDamage", "zcity_gore_corpse_chop", function(ent, dmgInfo)
	if not IsValid(ent) or not ent:IsRagdoll() then return end
	if ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb") then return end
	if ent.__zgNpcCorpse then return end
	local org = ent.organism
	if not org or org.fakePlayer then return end
	if hg.RagdollOwner and IsValid(hg.RagdollOwner(ent)) then return end
	if not dmgInfo or not dmgInfo:IsDamageType(DMG_SLASH) then return end

	local hpos = dmgInfo:GetDamagePosition()
	if not hpos or hpos:LengthSqr() < 1 then return end

	-- the limb whose joint is closest to the hit
	local bestLimb, bestDist
	for limb in pairs(ZCityGore.JointBones) do
		if org[limb .. "amputated"] ~= true and not (limb == "head" and org.headamputated == true) then
			local jpos = jointPos(ent, limb)
			if jpos then
				local d = jpos:Distance(hpos)
				if d <= jointRadius(limb) and (not bestDist or d < bestDist) then
					bestLimb, bestDist = limb, d
				end
			end
		end
	end
	if not bestLimb then return end
	trySever(org, dmgInfo, bestLimb, ent)
end)

local function blastDist(ent, dmg)
	local pos = dmg:GetDamagePosition()
	if not pos or pos:LengthSqr() < 1 then
		local inf = dmg:GetInflictor()
		if IsValid(inf) then pos = inf:GetPos() end
	end
	if not pos then return 9999 end
	return math.min(ent:GetPos():Distance(pos), ent:WorldSpaceCenter():Distance(pos))
end

local function queueBlast(org, dmg, dist)
	if not org then return end
	local copy = DamageInfo()
	copy:SetDamage(dmg:GetDamage())
	copy:SetDamageType(DMG_BLAST)
	copy:SetDamagePosition(dmg:GetDamagePosition())
	copy:SetDamageForce(dmg:GetDamageForce())
	copy:SetAttacker(dmg:GetAttacker())
	copy:SetInflictor(dmg:GetInflictor())
	timer.Simple(0, function()
		if org then blastDismember(org, copy, dist) end
	end)
end

hook.Add("EntityTakeDamage", "zcity_gore_blast", function(ent, dmg)
	if not IsValid(ent) or not dmg or not dmg:IsDamageType(DMG_BLAST) then return end
	if isNpcBody(ent) then return end
	markBlast(ent)
	local org = ent.organism
	if not org and isfunction(hg.RagdollOwner) then
		local ply = hg.RagdollOwner(ent)
		org = IsValid(ply) and ply.organism
	end
	if not org then return end
	local dist = blastDist(ent, dmg)
	if dist > ZCityGore.BlastRange then return end
	queueBlast(org, dmg, dist)
end)

hook.Add("HomigradDamage", "zcity_gore_blast", function(ply, dmgInfo, hitgroup, ent)
	if not dmgInfo or not dmgInfo:IsDamageType(DMG_BLAST) then return end
	local target = (IsValid(ent) and ent) or ply
	if not IsValid(target) then return end
	if isNpcBody(target) then return end
	markBlast(target)
	markBlast(ply)
	local org = (IsValid(ent) and ent.organism) or (IsValid(ply) and ply.organism)
	if not org then return end
	local dist = blastDist(target, dmgInfo)
	if dist > ZCityGore.BlastRange then return end
	queueBlast(org, dmgInfo, dist)
end)

local function restorePlayerMesh(ply)
	if not IsValid(ply) then return end
	if ply.IsSeveredLimb or (ply.GetNWBool and ply:GetNWBool("IsSeveredLimb")) then return end
	ply.noHead = nil
	if ply.SetNWBool then ply:SetNWBool("noHead", false) end
	local count = ply.GetBoneCount and ply:GetBoneCount() or 0
	for i = 0, count - 1 do
		ply:ManipulateBoneScale(i, vecFull)
	end
end

local function resetPlayerGore(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	restorePlayerMesh(ply)
	-- (pieces of the previous life are NOT detached: they stay on their corpse, see resolveBody)
	ply._zgSevered = nil
	ply._zgBlastUntil = nil
	local org = ply.organism
	if org then
		org.headamputated = false
		org._blastDismembered = nil
		org.severprogress = {larm = 0, rarm = 0, lleg = 0, rleg = 0, head = 0}
		org.severNext = {larm = 0, rarm = 0, lleg = 0, rleg = 0, head = 0}
	end
	net.Start("zcity_gore_reset")
	net.WriteEntity(ply)
	net.Broadcast()
end

hook.Add("Org Clear", "zcity_gore_clear", function(org)
	if not org then return end
	org.severprogress = {larm = 0, rarm = 0, lleg = 0, rleg = 0, head = 0}
	org.severNext = {larm = 0, rarm = 0, lleg = 0, rleg = 0, head = 0}
	org._blastDismembered = nil
end)

hook.Add("PlayerSpawn", "zcity_gore_reset", function(ply)
	-- hg.FakeUp respawns the player to stand them up (OverrideSpawn is set): the cut limbs stay cut and
	-- keep hanging on their arteries, only a real respawn resets the gore
	if OverrideSpawn then return end
	-- Last chance to pin the pieces of the old life to their corpse, BEFORE the life counter changes (after that the
	-- corpse link can no longer be made and the arteries would vanish)
	if IsValid(ply) and ZCityGore.LinkCorpses then ZCityGore.LinkCorpses(ply, true) end
	-- New life, immediately (not a tick later): from this moment every piece of the old life belongs to the old corpse
	if IsValid(ply) then ply:SetNWInt("ZCGoreLife", ownerLife(ply) + 1) end
	timer.Simple(0, function() resetPlayerGore(ply) end)
end)

hook.Add("Ragdoll_Create", "zcity_gore_sever_head", function(ply, ragdoll)
	if not IsValid(ply) or not IsValid(ragdoll) then return end
	if ragdoll.IsSeveredLimb or ragdoll:GetNWBool("IsSeveredLimb") then
		if ply.FakeRagdoll == ragdoll then ply.FakeRagdoll = nil end
		return
	end
	local org = ply.organism
	if not (org and org.headamputated == true) then return end
	hideHeadMesh(ragdoll)
end)

hook.Add("PlayerDeath", "zcity_gore_sever_head", function(ply)
	if not IsValid(ply) then return end
	local org = ply.organism
	if not (org and org.headamputated == true) and not ply:GetNWBool("noHead") then return end
	hideHeadEverywhere(ply)
end)

-- World position of the middle of a severed piece (average of its visible bones).
-- Grabbing here keeps the piece centred in the palm instead of hanging off the edge.
local function severedCenter(rag)
	local limb = rag:GetNWString("SeveredLimb", "")
	local rootName = limbRootBones[limb]
	local rootBone = rootName and rag:LookupBone(rootName)
	if not rootBone then return end

	local keep = {rootBone}
	recursiveBone(rag, rootBone, keep)

	local sum, n = vector_origin, 0
	for _, b in ipairs(keep) do
		local p = rag:GetBonePosition(b)
		if p then
			sum = sum + p
			n = n + 1
		end
	end
	if n == 0 then return end
	return sum / n
end

local function patchHands()
	local wep = weapons.GetStored("weapon_hands_sh")
	if not wep or wep._zcityGoreHands then return end
	wep._zcityGoreHands = true
	local oldSet = wep.SetCarrying
	if isfunction(oldSet) then
		wep.SetCarrying = function(self, ent, bone, pos, dist)
			-- the lower half of a body cut in two can only be moved with the physgun (see sv_torso.lua)
			if IsValid(ent) and ent:GetNWBool("ZCityTorsoLowerPart") then return end
			if IsValid(ent) and (ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb")) then
				bone = ent.severedRootPhys or ent:GetNWInt("SeveredRootPhys", bone) or bone
				if hg.severedLimbs and hg.severedLimbs[ent] then
					bone = hg.severedLimbs[ent].root or bone
				end
				pos = severedCenter(ent) or pos
			end
			return oldSet(self, ent, bone, pos, dist)
		end
	end
end

local function patchNilOrganism()
	local pmeta = FindMetaTable("Player")
	if not pmeta or pmeta._ZCityGoreOrgGuard then return end
	pmeta._ZCityGoreOrgGuard = true

	local oldBerserk = pmeta.IsBerserk
	if isfunction(oldBerserk) then
		function pmeta:IsBerserk(...)
			if not IsValid(self) or not istable(self.organism) then return false end
			return oldBerserk(self, ...)
		end
	end

	local oldStim = pmeta.IsStimulated
	if isfunction(oldStim) then
		function pmeta:IsStimulated(...)
			if not IsValid(self) or not istable(self.organism) then return false end
			return oldStim(self, ...)
		end
	end
end

local function ensureOrganism(ply)
	if not IsValid(ply) or ply.organism then return end
	if istable(hg) and istable(hg.organism) and isfunction(hg.organism.Add) then
		hg.organism.Add(ply)
	end
end

-- ---------------------------------------------------------------------------
-- Standing up without hands.
-- A standing player keeps the arteries: ResolveBody() hands the tether the player entity, so the cut
-- arms dangle from the stumps and rip off if the player runs too far.
-- ---------------------------------------------------------------------------
-- NOTE: hg.FakeUp refuses to stand up when ANY "Should Fake Up" hook returns a non-nil value, true included.
-- The old version of this hook returned true to "allow" standing, which actually blocked it. Z-City itself
-- lets an armless player stand up, so this addon must not touch the rule at all: the convar is kept only so
-- old configs do not error, it does nothing any more.
local function armlessMayStand(ply)
	return false
end
ZCityGore.ArmlessMayStand = armlessMayStand

-- Diagnostic: lists everything that can veto standing up, so an extra Z-City check can be found.
concommand.Add("zcity_gore_standup_debug", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local function out(msg)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) else print(msg) end
	end
	out("[zcity_gore] hooks on 'Should Fake Up':")
	for name in pairs(hook.GetTable()["Should Fake Up"] or {}) do out("   " .. tostring(name)) end
	out("[zcity_gore] hg functions with 'fake' in the name:")
	for k, v in pairs(hg or {}) do
		if isfunction(v) and string.find(string.lower(tostring(k)), "fake", 1, true) then out("   hg." .. tostring(k)) end
	end
end)

local function install()
	patchWeapons()
	patchHands()
	patchNilOrganism()
	return wrapAmputate()
end

hook.Add("HomigradRun", "zcity_gore_install", function()
	timer.Simple(0, install)
end)
hook.Add("InitPostEntity", "zcity_gore_install", install)
hook.Add("PlayerInitialSpawn", "zcity_gore_org", function(ply)
	timer.Simple(0, function() ensureOrganism(ply) end)
end)
timer.Create("zcity_gore_install", 0.25, 40, function()
	if install() then timer.Remove("zcity_gore_install") end
end)

hook.Add("OnEntityCreated", "zcity_gore_block_gibs", function(ent)
	if not GetConVar("zcity_gore_block_gibs"):GetBool() then return end -- remorse: по умолчанию мясо и обрубки не трогаем
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if ent.IsSeveredLimb or (ent.GetNWBool and ent:GetNWBool("IsSeveredLimb")) then return end
		local mdl = string.lower(tostring(ent:GetModel() or ""))
		if mdl == "" then return end
		if string.find(mdl, "headpartial", 1, true)
			or string.find(mdl, "limbspartial", 1, true)
			or string.find(mdl, "grub_nugget", 1, true)
			or string.find(mdl, "watermelon", 1, true)
			or string.find(mdl, "gibs/humans", 1, true)
			or string.find(mdl, "hgibs", 1, true)
		then
			ent:Remove()
		end
	end)
end)

-- ---------------------------------------------------------------------------
-- Shared with sv_npc.lua / sv_torso.lua
-- ---------------------------------------------------------------------------
ZCityGore.SendSeverBlood = sendSeverBlood
ZCityGore.JointPos = jointPos
ZCityGore.JointRadiusFor = jointRadius -- (NOT ZCityGore.JointRadius: that is the number in sh_gore.lua)
ZCityGore.HitsForWeapon = hitsForWeapon
