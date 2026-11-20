-- |Z-CITY| GORE torso (server)
--
-- Cuts a body in half at the chest (Spine2). The body ragdoll keeps the upper half, a new ragdoll
-- is spawned for the lower half, both get a flesh cap on the cut. The lower half hangs from the
-- upper half on a thick chest artery (see "chest artery" below), like severed limbs hang from
-- their stump.
--
-- Split / cap code ported from the "ZCity Gore V2" torso addon (z_podgruz.lua).
--
-- Entry points:
--   ZCityGore.SeverTorso(ent, force, fromBlast)   ent = player, fake ragdoll or corpse ragdoll
--   hg.ZCityGore_AmputateTorso                    same function, name used by the old addon
--
-- ConVars: zcity_gore_torso (0 disables), zcity_gore_torso_tether, zcity_gore_torso_blast,
--          zcity_gore_torso_blast_radius, zcity_gore_torso_lower_lifetime

local ZERO_SCALE = Vector(0, 0, 0)
local ALMOST_ZERO = Vector(0.01, 0.01, 0.01)
local HIDDEN_POS = Vector(0, 0, 0) / 0 -- NaN: moves a bone out of the world entirely
local UPPER_MODEL = ZCityGore.TorsoUpperModel
local LOWER_MODEL = ZCityGore.TorsoLowerModel

local zg_torso = CreateConVar("zcity_gore_torso", "1", FCVAR_ARCHIVE, "Torso dismemberment (0 = off)", 0, 1)
local zg_torso_tether = CreateConVar("zcity_gore_torso_tether", "1", FCVAR_ARCHIVE, "The lower half hangs on a chest artery (0 = it falls free)", 0, 1)
local zg_torso_blast = CreateConVar("zcity_gore_torso_blast", "1", FCVAR_ARCHIVE, "Close explosions cut the torso in half", 0, 1)
local zg_blast_radius = CreateConVar("zcity_gore_torso_blast_radius", "110", FCVAR_ARCHIVE, "Maximum blast distance for torso dismemberment", 1, 500)
local zg_lower_life = CreateConVar("zcity_gore_torso_lower_lifetime", "180", FCVAR_ARCHIVE, "Lifetime of the severed lower half in seconds", 10, 600)

-- ---------------------------------------------------------------------------
-- Content: models + materials (+ tear sounds if the server has them)
-- ---------------------------------------------------------------------------
local tearSounds = {}

do
	local files = {}
	for _, name in ipairs({"torsovar", "abdomenvar"}) do
		files[#files + 1] = "models/torsopartial/" .. name .. ".mdl"
		files[#files + 1] = "models/torsopartial/" .. name .. ".dx80.vtx"
		files[#files + 1] = "models/torsopartial/" .. name .. ".dx90.vtx"
		files[#files + 1] = "models/torsopartial/" .. name .. ".vvd"
	end
	for _, name in ipairs(file.Find("materials/models/torsopartial/*", "GAME") or {}) do
		files[#files + 1] = "materials/models/torsopartial/" .. name
	end
	for i = 1, 7 do
		local snd = "gore/kf2_tear" .. i .. ".wav"
		if file.Exists("sound/" .. snd, "GAME") then
			tearSounds[#tearSounds + 1] = snd
			files[#files + 1] = "sound/" .. snd
			util.PrecacheSound(snd)
		end
	end
	for _, path in ipairs(files) do
		if (ZCITY_GORE_WORKSHOP_ID or "") == "" and file.Exists(path, "GAME") then resource.AddFile(path) end
	end
end

util.PrecacheModel(UPPER_MODEL)
util.PrecacheModel(LOWER_MODEL)

local function playTear(ent, level, volume)
	if not IsValid(ent) then return end
	if #tearSounds > 0 then
		ent:EmitSound(tearSounds[math.random(#tearSounds)], level or 85, math.random(92, 104), volume or 1)
	end
	ent:EmitSound("physics/body/body_medium_break3.wav", 88, math.random(82, 94), 1)
end

-- ---------------------------------------------------------------------------
-- Victim lines (shown to a player who survives the cut)
-- ---------------------------------------------------------------------------
local initialPhrases = {
	"FUCK! I'M TORN IN HALF!",
	"OH GOD! MY LOWER BODY IS GONE!",
	"FUCK! I CAN'T FEEL MY LEGS!",
	"JESUS CHRIST! I'M CUT IN HALF!",
	"MY FUCKING TORSO! HELP ME!",
	"HOLY SHIT! WHERE ARE MY LEGS?!",
	"FUCK! I'M IN TWO PIECES!",
	"OH FUCK, MY BODY! MY BODY!",
	"I'M FUCKING SPLIT OPEN!",
	"GOD! I'VE BEEN RIPPED APART!",
	"MY LEGS! FUCK, MY LEGS ARE GONE!",
	"I'M CUT IN FUCKING HALF!",
	"WHAT THE FUCK HAPPENED TO ME?!",
	"FUCKING HELL! I'M TORN APART!",
	"OH GOD! DON'T LOOK AT ME!",
}

local painPhrases = {
	"FUCK, IT HURTS!",
	"I'M BLEEDING OUT!",
	"SOMEBODY FUCKING HELP ME!",
	"I CAN'T MOVE MY LEGS!",
	"OH GOD, KEEP ME AWAKE!",
	"FUCK! DON'T LET ME DIE!",
	"I CAN'T FEEL ANYTHING BELOW MY CHEST!",
	"FUCK! THE PAIN WON'T STOP!",
	"SOMEBODY STOP THE BLEEDING!",
	"I'M LOSING TOO MUCH BLOOD!",
	"HELP ME! PLEASE, FUCKING HELP ME!",
	"I CAN'T FUCKING MOVE!",
	"MY BACK IS ON FIRE!",
	"FUCK, I FEEL COLD!",
	"DON'T LET ME PASS OUT!",
	"I'M STILL ALIVE! HELP ME!",
	"OH GOD, I'M BLEEDING EVERYWHERE!",
	"FUCK! I CAN'T BREATHE RIGHT!",
	"KEEP ME AWAKE! KEEP TALKING TO ME!",
	"PLEASE, I DON'T WANT TO DIE!",
	"MY BODY'S FUCKED!",
	"I NEED A MEDIC RIGHT FUCKING NOW!",
	"I CAN FEEL MYSELF GETTING WEAKER!",
	"FUCK! EVERYTHING'S GOING NUMB!",
}

local criticalPhrases = {
	"I'M GOING INTO SHOCK!",
	"I CAN'T SEE STRAIGHT!",
	"FUCK, I'M FADING!",
	"I'M SO FUCKING COLD!",
	"DON'T LET ME CLOSE MY EYES!",
	"I CAN'T STAY AWAKE!",
	"THERE'S TOO MUCH BLOOD!",
	"I'M FUCKING DYING HERE!",
	"MY HEART'S POUNDING!",
	"I CAN'T FEEL MY HANDS!",
	"EVERYTHING'S GETTING DARK!",
	"FUCK! I'M LOSING IT!",
}

local function pickPhrase(ply, pool, slot)
	local last = ply[slot]
	local index = math.random(#pool)
	if #pool > 1 and index == last then index = index % #pool + 1 end
	ply[slot] = index
	return pool[index]
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local states = {} -- [state] = true, every live split

local function validVec(v)
	return v ~= nil and v.x == v.x and v.y == v.y and v.z == v.z
end

local function resolvePlayer(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent end
	local direct = ent.ply
	if IsValid(direct) and direct:IsPlayer() then return direct end
	if hg and hg.RagdollOwner then
		local owner = hg.RagdollOwner(ent)
		if IsValid(owner) and owner:IsPlayer() then return owner end
	end
	local nw = ent:GetNWEntity("ply")
	if IsValid(nw) and nw:IsPlayer() then return nw end
	return nil
end

local function copyAppearance(source, target, ply)
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
	-- Citizen Clothing / Faces Overhaul support: keep the body's outfit and face, no random re-skin (see sh_gore.lua)
	if ZCityGore.ProtectOverhaulAppearance then ZCityGore.ProtectOverhaulAppearance(target, source) end

	-- player colour / appearance, same as the severed limbs get
	local col
	if IsValid(ply) and ply.GetPlayerColor then col = ply:GetPlayerColor() end
	if not col and source.GetNWVector then col = source:GetNWVector("PlayerColor", nil) end
	if col then target:SetNWVector("PlayerColor", col) end
	local appearance = (IsValid(ply) and ply.CurAppearance) or source.CurAppearance
	if appearance then target.CurAppearance = table.Copy(appearance) end
end

local function copyPhysicsPose(source, target)
	local count = math.min(source:GetPhysicsObjectCount(), target:GetPhysicsObjectCount())
	for i = 0, count - 1 do
		local src = source:GetPhysicsObjectNum(i)
		local dst = target:GetPhysicsObjectNum(i)
		if IsValid(src) and IsValid(dst) then
			dst:SetPos(src:GetPos())
			dst:SetAngles(src:GetAngles())
			dst:SetVelocity(src:GetVelocity())
		end
	end
end

local function collectDescendants(ent, bone, output)
	output[bone] = true
	for _, child in ipairs(ent:GetChildBones(bone) or {}) do
		if not output[child] then
			collectDescendants(ent, child, output)
		end
	end
end

local function getBoneTransform(ent, bone)
	if not IsValid(ent) or bone == nil or bone < 0 then return nil end
	local physID = ent:TranslateBoneToPhysBone(bone)
	if physID ~= nil and physID >= 0 then
		local phys = ent:GetPhysicsObjectNum(physID)
		if IsValid(phys) then
			return phys:GetPos(), phys:GetAngles()
		end
	end
	local pos, ang = ent:GetBonePosition(bone)
	if isvector(pos) and isangle(ang) then return pos, ang end
	local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(bone)
	if matrix then
		pos, ang = matrix:GetTranslation(), matrix:GetAngles()
		if isvector(pos) and isangle(ang) then return pos, ang end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Flesh caps: a prop glued to a bone that covers the open cut
-- ---------------------------------------------------------------------------
local function updateCap(cap)
	if not IsValid(cap) then return false end
	local parent = cap.__zcGoreParent
	local bone = cap.__zcGoreBone
	if not IsValid(parent) or not bone then
		cap:Remove()
		return false
	end
	local basePos, baseAng = getBoneTransform(parent, bone)
	if not basePos or not baseAng then return false end
	local pos, ang = LocalToWorld(cap.__zcGoreLocalPos or vector_origin, cap.__zcGoreLocalAng or angle_zero, basePos, baseAng)
	cap:SetPos(pos)
	cap:SetAngles(ang)
	return true
end

local function makeCap(model, parent, bone, localPos, localAng, scale)
	local cap = ents.Create("prop_dynamic")
	if not IsValid(cap) then return nil end
	cap:SetModel(model)
	cap:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	cap:SetNotSolid(true)
	cap:SetMoveType(MOVETYPE_NONE)
	cap:DrawShadow(false)
	cap:Spawn()
	if scale then cap:ManipulateBoneScale(0, scale) end
	cap.__zcGoreParent = parent
	cap.__zcGoreBone = bone
	cap.__zcGoreLocalPos = localPos
	cap.__zcGoreLocalAng = localAng
	parent:DeleteOnRemove(cap)
	updateCap(cap)
	return cap
end

-- ---------------------------------------------------------------------------
-- Splitting the ragdoll
-- ---------------------------------------------------------------------------
local function collectParents(ent, bone)
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

local function setHiddenBone(ent, bone, hardHide)
	ent:ManipulateBoneScale(bone, ZERO_SCALE)
	if hardHide then
		ent:ManipulateBonePosition(bone, HIDDEN_POS)
	end
end

local function configureHiddenPhys(ent, physID)
	if not physID or physID < 0 then return end
	local phys = ent:GetPhysicsObjectNum(physID)
	if not IsValid(phys) then return end
	phys:EnableCollisions(false)
	phys:SetMass(0.01)
	phys:EnableMotion(false)
end

local function addPhysParent(map, physID, parentPhysID)
	if not physID or physID < 0 then return end
	if not parentPhysID or parentPhysID < 0 then return end
	if physID == parentPhysID then return end
	map[physID] = parentPhysID
end

-- Hidden physics bones are kept glued to a visible one every tick, so they cannot drag the half apart
local function forceHiddenPhys(ent, map)
	if not IsValid(ent) then return end
	for physID, parentPhysID in pairs(map or {}) do
		local phys = ent:GetPhysicsObjectNum(physID)
		local parentPhys = ent:GetPhysicsObjectNum(parentPhysID)
		if IsValid(phys) and IsValid(parentPhys) then
			phys:SetPos(parentPhys:GetPos())
			phys:SetAngles(parentPhys:GetAngles())
			phys:SetVelocity(parentPhys:GetVelocity())
		end
	end
end

-- Upper half = Spine2 and everything below it in the hierarchy (arms, neck, head); the rest is hidden
local function buildUpperHalf(rag, spine2, spine2PhysID)
	local visible = {}
	collectDescendants(rag, spine2, visible)
	local parents = collectParents(rag, spine2)
	local physParents = {}
	local seenPhys = {}

	for bone = 0, rag:GetBoneCount() - 1 do
		if not visible[bone] then
			setHiddenBone(rag, bone, not parents[bone])
			local physID = rag:TranslateBoneToPhysBone(bone)
			if physID and physID >= 0 and not seenPhys[physID] then
				seenPhys[physID] = true
				configureHiddenPhys(rag, physID)
				if not parents[bone] then
					rag:RemoveInternalConstraint(physID)
				end
				addPhysParent(physParents, physID, spine2PhysID)
			end
		end
	end

	for parentBone in pairs(parents) do
		local physID = rag:TranslateBoneToPhysBone(parentBone)
		if physID and physID >= 0 then
			configureHiddenPhys(rag, physID)
			addPhysParent(physParents, physID, spine2PhysID)
		end
	end

	rag:RemoveInternalConstraint(spine2PhysID)
	return physParents
end

-- Lower half = pelvis, legs and the lower spine; Spine2 and everything above it is hidden
local function buildLowerHalf(lower, spine2)
	local hidden = {}
	collectDescendants(lower, spine2, hidden)
	local spine2PhysID = lower:TranslateBoneToPhysBone(spine2)
	local pelvis = lower:LookupBone("ValveBiped.Bip01_Pelvis")
	local pelvisPhysID = pelvis and lower:TranslateBoneToPhysBone(pelvis) or 0
	if not pelvisPhysID or pelvisPhysID < 0 then pelvisPhysID = 0 end
	local physParents = {}
	local seenPhys = {}

	for bone in pairs(hidden) do
		setHiddenBone(lower, bone, bone ~= spine2)
		local physID = lower:TranslateBoneToPhysBone(bone)
		if physID and physID >= 0 and not seenPhys[physID] then
			seenPhys[physID] = true
			configureHiddenPhys(lower, physID)
			if physID ~= pelvisPhysID then
				lower:RemoveInternalConstraint(physID)
				addPhysParent(physParents, physID, pelvisPhysID)
			end
		end
	end

	if spine2PhysID and spine2PhysID >= 0 and spine2PhysID ~= pelvisPhysID then
		lower:RemoveInternalConstraint(spine2PhysID)
		addPhysParent(physParents, spine2PhysID, pelvisPhysID)
	end

	return physParents, pelvisPhysID
end

-- A leg that was already cut off keeps being gone on the lower half
local function hideAmputatedLegs(lower, org)
	if not org then return end
	for _, info in ipairs({{"lleg", "ValveBiped.Bip01_L_Calf"}, {"rleg", "ValveBiped.Bip01_R_Calf"}}) do
		if org[info[1] .. "amputated"] == true then
			lower.__zcCutLegs = lower.__zcCutLegs or {}
			lower.__zcCutLegs[info[1]] = true
			local bone = lower:LookupBone(info[2])
			if bone then
				local set = {}
				collectDescendants(lower, bone, set)
				for b in pairs(set) do lower:ManipulateBoneScale(b, ALMOST_ZERO) end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Chest artery: the lower half is a rope's length from the upper half. Slack until it is `len`
-- units away, then the artery cancels the outward velocity and drags the lower half back, so it
-- hangs and swings from the chest. It snaps when stretched too far (body ran off / teleported).
-- The strands themselves are drawn on the client (cl_torso.lua).
-- ---------------------------------------------------------------------------
local function detachTether(state)
	state.tether = nil
	if IsValid(state.lower) then state.lower:SetNWBool("ZCTorsoTethered", false) end
end

-- cut face of the upper half (position, velocity) - its Spine2 physics bone
local function upperCut(state)
	local up = state.rag
	if IsValid(up) then
		local phys = up:GetPhysicsObjectNum(state.upperSpine2PhysID or -1)
		if IsValid(phys) then return phys:GetPos(), phys:GetVelocity() end
	end
	-- the body may have been replaced by a corpse ragdoll (but never follow the owner into a new life)
	local o = state.owner
	if IsValid(o) and o:IsPlayer() and ZCityGore.OwnerLife(o) ~= state.life then return end
	local body = ZCityGore.ResolveBody(o)
	if IsValid(body) then
		local bone = body:LookupBone("ValveBiped.Bip01_Spine2")
		local pos = bone and getBoneTransform(body, bone)
		if pos then return pos, body:GetVelocity() end
	end
end

local function tetherStep(state)
	local t = state.tether
	local lower = state.lower
	if not t or not IsValid(lower) then return end
	local root = lower:GetPhysicsObjectNum(state.lowerRoot or 0)
	if not IsValid(root) then return end

	local anchor, anchorVel = upperCut(state)
	if not anchor then
		t.lost = t.lost or CurTime()
		if CurTime() - t.lost > 2 then detachTether(state) end
		return
	end
	t.lost = nil

	local cut = root:GetPos() -- the lower cut face sits on the pelvis
	if not validVec(anchor) or not validVec(cut) then return detachTether(state) end

	local delta = anchor - cut
	local dist = delta:Length()
	-- the 5 chest arteries rip one after another (thinnest first); the last one lets the lower half go
	local snapped, remain = ZCityGore.StepArteryTear(t, ZCityGore.TorsoArteries, dist, ZCityGore.TorsoTetherSnapMul or 2.6, lower, true)
	if snapped then return detachTether(state) end
	if dist <= t.len or dist < 0.01 then return end -- slack
	if lower:IsPlayerHolding() then return end -- let the player carry it; walking away snaps the artery

	local dir = delta / dist
	local rel = root:GetVelocity() - (anchorVel or vector_origin)
	local out = -rel:Dot(dir) -- speed at which the lower half moves away from the chest
	local pull = math.min((dist - t.len) * 8, ZCityGore.TorsoTetherPullSpeed or 170)
	local dv = math.min(pull + out, 600)
	if dv <= 0 then return end
	-- same formula as the limb tether (sv_gore.lua): velocity change * mass of the bone it is applied to
	root:ApplyForceCenter(dir * dv * root:GetMass() * 1.3 * (0.35 + 0.65 * remain))
end

-- ---------------------------------------------------------------------------
-- Build the split
-- ---------------------------------------------------------------------------
local function buildSplitRagdolls(ply, rag, force, fromBlast)
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
	copyAppearance(rag, lower, ply)
	copyPhysicsPose(rag, lower)
	lower:SetNWBool("ZCityTorsoLowerPart", true)

	local lowerSpine2 = lower:LookupBone("ValveBiped.Bip01_Spine2")
	if not lowerSpine2 then
		lower:Remove()
		return nil
	end

	-- legs that are already gone must stay gone (read before the torso trauma flags both legs)
	local org = (IsValid(ply) and ply.organism) or rag.organism or rag.__zgLegs -- (__zgLegs: NPC corpse, sv_npc.lua)

	local upperPhysParents = buildUpperHalf(rag, spine2, spine2PhysID)
	local lowerPhysParents, pelvisPhysID = buildLowerHalf(lower, lowerSpine2)
	hideAmputatedLegs(lower, org)

	rag:SetNWBool("ZCityTorsoSevered", true)
	if IsValid(ply) then ply:SetNWBool("ZCityTorsoSevered", true) end

	local upperCap = makeCap(UPPER_MODEL, rag, spine2, Vector(-2, 2, 0), Angle(0, 90, 90), Vector(1, 1, 1))
	local lowerCap = makeCap(LOWER_MODEL, lower, lowerSpine2, Vector(-3, 2, 0), Angle(0, 90, 90), Vector(1.1, 1.1, 1.1))

	forceHiddenPhys(rag, upperPhysParents)
	forceHiddenPhys(lower, lowerPhysParents)

	local tethered = zg_torso_tether:GetBool() and (not fromBlast or ZCityGore.TorsoTetherOnBlast == true)
	local throwMul = tethered and (ZCityGore.TorsoTetherThrowMul or 0.3) or 1

	local forceDir = force and force:LengthSqr() > 1 and force:GetNormalized() or VectorRand():GetNormalized()
	local push = math.Clamp(force and force:Length() * 0.012 or 260, 180, 620) * throwMul
	local upperVelocity = spine2Phys:GetVelocity()
	spine2Phys:EnableMotion(true)
	spine2Phys:Wake()
	spine2Phys:SetVelocity(upperVelocity + forceDir * push + Vector(0, 0, 70 * throwMul))

	local lowerRoot = lower:GetPhysicsObjectNum(pelvisPhysID or 0)
	if IsValid(lowerRoot) then
		lowerRoot:EnableMotion(true)
		lowerRoot:Wake()
		lowerRoot:SetVelocity(upperVelocity - forceDir * push * 0.45 + Vector(0, 0, 25 * throwMul))
		lowerRoot:AddAngleVelocity(VectorRand(-120, 120) * throwMul)
	end

	local state = {
		owner = IsValid(ply) and ply or rag,
		rag = rag,
		lower = lower,
		upperCap = upperCap,
		lowerCap = lowerCap,
		upperPhysParents = upperPhysParents,
		lowerPhysParents = lowerPhysParents,
		upperSpine2PhysID = spine2PhysID,
		lowerRoot = pelvisPhysID or 0,
		life = ZCityGore.OwnerLife(ply),
	}
	lower.__zcGoreState = state
	states[state] = true
	if IsValid(ply) then ply.__zcGoreTorsoState = state end
	if IsValid(ply) then ply.__zcGoreLowerTorso = lower end

	-- the client draws the artery stubs between / on the caps, tethered or not
	lower:SetNWFloat("ZCTorsoTetherLen", ZCityGore.TorsoTetherLength or 26)
	lower:SetNWEntity("ZCTorsoUpperCap", upperCap or NULL)
	lower:SetNWEntity("ZCTorsoLowerCap", lowerCap or NULL)
	lower:SetNWInt("ZCArteryTorn", 0)
	if not tethered then
		-- the halves fly apart freely: all 5 arteries are already ripped
		lower:SetNWInt("ZCArteryTorn", ZCityGore.FullArteryMask(ZCityGore.TorsoArteries))
		lower:SetNWFloat("ZCArteryTearTime", CurTime())
	end

	if tethered then
		state.tether = {len = ZCityGore.TorsoTetherLength or 26}
		lower:SetNWBool("ZCTorsoTethered", true)
		-- damping so the hanging half swings and settles instead of tumbling forever
		for i = 0, lower:GetPhysicsObjectCount() - 1 do
			local phys = lower:GetPhysicsObjectNum(i)
			if IsValid(phys) and not lowerPhysParents[i] then phys:SetDamping(0.05, 1.5) end
		end
	end
	lower:SetNWFloat("ZCTorsoBleedUntil", CurTime() + 25)

	-- legs that were cut off earlier now hang from the lower half, not from the (legless) upper half
	for limbRag, data in pairs(hg.severedLimbs or {}) do
		local t = data.tether
		if t and (t.limb == "lleg" or t.limb == "rleg") and (t.owner == ply or t.owner == rag) and IsValid(limbRag) then
			t.body = lower
			limbRag:SetNWEntity("SeveredBody", lower)
		end
	end

	local life = zg_lower_life:GetFloat()
	if life > 0 then SafeRemoveEntityDelayed(lower, life) end
	return state
end

-- The 5 chest arteries: {flow size, local offset, spray direction, id}. Thin, so each one leaks less than
-- the old two fat ones, but they spurt in different directions.
local TORSO_WOUNDS = {
	{12, Vector(0, 1.6, 0),    Vector(-150, 0, 20),   "a"},
	{8,  Vector(0, -1.6, 0),   Vector(150, 0, 20),    "b"},
	{8,  Vector(1.4, 0, 1),    Vector(0, -140, 40),   "c"},
	{6,  Vector(-1.4, 0, 1),   Vector(0, 140, 40),    "d"},
	{6,  Vector(0, 0, -1.6),   Vector(-90, 90, -35),  "e"},
}

-- Torso trauma for a player who survives the cut: pain, shock, heavy bleeding from the chest
local function addTorsoTrauma(ply, rag, fromBlast)
	local org = ply.organism
	if not org then return end
	org.torsoamputated = true
	org.llegamputated = true
	org.rlegamputated = true
	org.painadd = math.min((org.painadd or 0) + (fromBlast and 85 or 70), 150)
	org.shock = math.max(org.shock or 0, fromBlast and 20 or 16)
	org.adrenaline = math.max(org.adrenaline or 0, fromBlast and 3.4 or 3.0)
	org.adrenalineAdd = math.max(org.adrenalineAdd or 0, 4.5)
	org.internalBleed = (org.internalBleed or 0) + 24
	org.blood = math.max((org.blood or 5000) - 260, 0)
	org.needfake = true
	org.arterialwounds = org.arterialwounds or {}

	local clean = {}
	for _, wound in pairs(org.arterialwounds) do
		if not (isstring(wound[7]) and string.sub(wound[7], 1, 19) == "zcity_torso_artery_") then
			clean[#clean + 1] = wound
		end
	end
	for i = 1, #TORSO_WOUNDS do
		local w = TORSO_WOUNDS[i]
		clean[#clean + 1] = {w[1], w[2], Angle(), "ValveBiped.Bip01_Spine1", CurTime(), w[3], "zcity_torso_artery_" .. w[4]}
	end
	org.arterialwounds = clean
	if ply.SetNetVar then ply:SetNetVar("arterialwounds", clean) end

	if ply.AddNaturalAdrenaline then ply:AddNaturalAdrenaline(3.5) end

	if hg.organism and hg.organism.AddWoundManual then
		for _ = 1, 6 do
			hg.organism.AddWoundManual(ply, 65, VectorRand(-2.5, 2.5), AngleRand(-12, 12), "ValveBiped.Bip01_Spine1", CurTime() + math.Rand(0, 1.2))
		end
	end

	-- tell every client that the legs are gone (same message Z-City sends for an amputation)
	pcall(function()
		net.Start("organism_send")
		net.WriteTable({owner = ply, llegamputated = true, rlegamputated = true})
		net.WriteBool(true)
		net.WriteBool(false)
		net.WriteBool(false)
		net.WriteBool(true)
		net.Broadcast()
	end)

	if isfunction(ply.Notify) then
		ply:Notify(pickPhrase(ply, initialPhrases, "__zcGoreLastInitialPhrase"), 4, "zcity_torso_initial", 0, nil, Color(255, 80, 70))
	end

	local timerName = "zcity_gore_torso_pain_" .. ply:EntIndex()
	timer.Remove(timerName)
	timer.Create(timerName, 6, 7, function()
		if not IsValid(ply) or not ply:Alive() or not ply:GetNWBool("ZCityTorsoSevered", false) then
			timer.Remove(timerName)
			return
		end
		if ply.organism and not ply.organism.otrub and isfunction(ply.Notify) then
			local orgNow = ply.organism
			local pool = ((orgNow.blood or 5000) < 3000 or (orgNow.shock or 0) > 28) and criticalPhrases or painPhrases
			ply:Notify(pickPhrase(ply, pool, "__zcGoreLastPainPhrase"), 2, timerName .. "_" .. tostring(math.random(1000000)), 0, nil, Color(255, 105, 95))
		end
	end)
end

local function splitEffects(rag)
	local bone = rag:LookupBone("ValveBiped.Bip01_Spine2")
	local pos = bone and rag:GetBonePosition(bone) or rag:WorldSpaceCenter()
	if pos then
		if SpawnMeatGore then SpawnMeatGore(rag, pos, 10, VectorRand(-350, 350), 1.15) end
		util.Decal("Blood", pos + Vector(0, 0, 10), pos - Vector(0, 0, 35), rag)
	end
	playTear(rag, 92, 1.15)
	if pos then
		-- the client turns this into a heavy burst out of the cut
		net.Start("hg_sever_blood")
		net.WriteEntity(rag)
		net.WriteString("torso")
		net.WriteVector(pos)
		net.WriteVector(vector_origin)
		net.Broadcast()
	end
end

-- A player who is still alive: put them into a fake ragdoll, split it, apply the trauma
local function splitLiving(ply, force, fromBlast)
	if ply:GetNWBool("ZCityTorsoSevered", false) or (ply.organism and ply.organism.torsoamputated) then return false end
	if ply.__zcGoreTorsoPending then return false end
	ply.__zcGoreTorsoPending = true

	local ok, res = pcall(function()
		if not IsValid(ply.FakeRagdoll) then
			if not hg or not hg.Fake then return false end
			hg.Fake(ply, nil, nil, true)
		end
		local rag = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or (hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or nil)
		if not IsValid(rag) or not rag:IsRagdoll() then return false end
		local state = buildSplitRagdolls(ply, rag, force or vector_origin, fromBlast)
		if not state then return false end
		addTorsoTrauma(ply, rag, fromBlast)
		splitEffects(rag)
		return true
	end)
	ply.__zcGoreTorsoPending = nil
	if not ok then
		ErrorNoHalt("[zcity_gore] torso: " .. tostring(res) .. "\n")
		return false
	end
	return res == true
end

local function findDeathRagdoll(ply, target)
	if IsValid(target) and target:IsRagdoll() then return target end
	if not IsValid(ply) then return nil end
	if IsValid(ply.RagdollDeath) then return ply.RagdollDeath end
	local nw = ply:GetNWEntity("RagdollDeath")
	if IsValid(nw) then return nw end
	if IsValid(ply.FakeRagdoll) then return ply.FakeRagdoll end
	return nil
end

-- A corpse (or a ragdoll nobody controls): just split it
local function splitRagdoll(ply, rag, force, fromBlast)
	if not IsValid(rag) or not rag:IsRagdoll() or rag:GetNWBool("ZCityTorsoSevered", false) then return false end
	local ok, res = pcall(function()
		local state = buildSplitRagdolls(ply, rag, force or vector_origin, fromBlast)
		if not state then return false end
		splitEffects(rag)
		return true
	end)
	if not ok then
		ErrorNoHalt("[zcity_gore] torso: " .. tostring(res) .. "\n")
		return false
	end
	return res == true
end

-- Cut a body in half at the chest.
-- ent: player, fake ragdoll or corpse ragdoll. Returns true when the body was split.
function ZCityGore.SeverTorso(ent, force, fromBlast)
	if not zg_torso:GetBool() then return false end
	if not IsValid(ent) then return false end
	if ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb") or ent:GetNWBool("ZCityTorsoLowerPart") then return false end
	force = force or VectorRand(-250, 250)
	fromBlast = fromBlast == true

	local ply = resolvePlayer(ent)
	if IsValid(ply) then
		if ply:Alive() then return splitLiving(ply, force, fromBlast) end
		return splitRagdoll(ply, findDeathRagdoll(ply, ent), force, fromBlast)
	end
	if ent:IsRagdoll() then return splitRagdoll(nil, ent, force, fromBlast) end
	return false
end

hg.ZCityGore_AmputateTorso = ZCityGore.SeverTorso -- name used by the old torso addon

function ZCityGore.TorsoBlastRadius()
	return zg_blast_radius:GetFloat()
end

function ZCityGore.TorsoBlastEnabled()
	return zg_torso:GetBool() and zg_torso_blast:GetBool() and ZCityGore.TorsoOnBlast == true
end

-- ---------------------------------------------------------------------------
-- Per-tick upkeep: keep hidden physics glued, move the caps, run the artery
-- ---------------------------------------------------------------------------
hook.Add("Think", "zcity_gore_torso_think", function()
	for state in pairs(states) do
		local ragOk = IsValid(state.rag)
		local lowerOk = IsValid(state.lower)
		if not ragOk and not lowerOk then
			states[state] = nil
		else
			if ragOk then
				forceHiddenPhys(state.rag, state.upperPhysParents)
				if IsValid(state.upperCap) then updateCap(state.upperCap) end
			end
			if lowerOk then
				forceHiddenPhys(state.lower, state.lowerPhysParents)
				if IsValid(state.lowerCap) then updateCap(state.lowerCap) end
			end
			if state.tether then
				local ok, err = pcall(tetherStep, state)
				if not ok then
					detachTether(state)
					ErrorNoHalt("[zcity_gore] torso tether: " .. tostring(err) .. "\n")
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Player state
-- ---------------------------------------------------------------------------
-- No legs: cannot stand up or crouch
hook.Add("Should Fake Up", "zcity_gore_torso_nostand", function(ply)
	if IsValid(ply) and ply:GetNWBool("ZCityTorsoSevered", false) then return false end
end)

hook.Add("StartCommand", "zcity_gore_torso_noduck", function(ply, cmd)
	if IsValid(ply) and ply:GetNWBool("ZCityTorsoSevered", false) then
		cmd:RemoveKey(IN_DUCK)
	end
end)

local function resetTorso(ply)
	if not IsValid(ply) then return end
	ply:SetNWBool("ZCityTorsoSevered", false)
	ply.__zcGoreTorsoPending = nil
	ply.__zcGoreLowerTorso = nil
	ply.__zcGoreLastInitialPhrase = nil
	ply.__zcGoreLastPainPhrase = nil
	-- The lower half of the previous life keeps hanging from that life's corpse (state.rag). It is only let go
	-- when that corpse is gone; the arteries must not rip off just because the player respawned.
	local state = ply.__zcGoreTorsoState
	if state and not IsValid(state.rag) then detachTether(state) end
	ply.__zcGoreTorsoState = nil
	timer.Remove("zcity_gore_torso_pain_" .. ply:EntIndex())
end

hook.Add("PlayerSpawn", "zcity_gore_torso_reset", function(ply)
	if OverrideSpawn then return end -- standing up (hg.FakeUp) respawns the player, that is not a new life
	timer.Simple(0, function() resetTorso(ply) end)
end)

hook.Add("PlayerDisconnected", "zcity_gore_torso_cleanup", function(ply)
	local state = ply.__zcGoreTorsoState
	if state and not IsValid(state.rag) then detachTether(state) end
	ply.__zcGoreTorsoState = nil
	ply.__zcGoreLowerTorso = nil
	timer.Remove("zcity_gore_torso_pain_" .. ply:EntIndex())
end)

hook.Add("Org Clear", "zcity_gore_torso_clear", function(org)
	if org then org.torsoamputated = false end
end)

-- ---------------------------------------------------------------------------
-- Grabbing the lower half (pelvis + legs of a body cut in two)
--   * only the physgun can move it: no hands / +use carrying, no gravity gun
--   * the physgun only takes it by a LEG (thigh, calf, foot). The pelvis and the parked, hidden upper-body
--     bones are not valid grab points, so nobody ends up holding an invisible 0.01 kg bone.
-- The hooks only ever veto (return false); whether a player may use the physgun at all stays up to the
-- server's own rules.
-- ---------------------------------------------------------------------------
local LEG_PHYS_BONES = {
	{"lleg", "ValveBiped.Bip01_L_Thigh"}, {"lleg", "ValveBiped.Bip01_L_Calf"}, {"lleg", "ValveBiped.Bip01_L_Foot"},
	{"rleg", "ValveBiped.Bip01_R_Thigh"}, {"rleg", "ValveBiped.Bip01_R_Calf"}, {"rleg", "ValveBiped.Bip01_R_Foot"},
}

-- physics bone ids of the legs that are still on the lower half
local function legPhysSet(lower)
	local set = lower.__zcLegPhys
	if set then return set end
	set = {}
	local cut = lower.__zcCutLegs or {}
	for _, info in ipairs(LEG_PHYS_BONES) do
		if not cut[info[1]] then
			local bone = lower:LookupBone(info[2])
			local physID = bone and lower:TranslateBoneToPhysBone(bone)
			if physID and physID >= 0 then set[physID] = true end
		end
	end
	local state = lower.__zcGoreState
	if state then
		set[state.lowerRoot or 0] = nil -- pelvis
		for physID in pairs(state.lowerPhysParents or {}) do set[physID] = nil end -- parked upper-body bones
	end
	lower.__zcLegPhys = set
	return set
end

-- Where is the player aiming on this lower half?
-- returns nil when no trace reaches it (then the grab is NOT blocked: better too permissive than ungrabbable),
-- otherwise true / false = the physics bone under the crosshair is / is not a leg
local function aimedBoneIsLeg(ply, lower)
	local set = legPhysSet(lower)
	local start = ply:GetShootPos()
	local endpos = start + ply:GetAimVector() * 32768
	local hit, bone
	-- the physgun's own trace mask differs between versions: try several
	for _, mask in ipairs({MASK_SHOT, MASK_ALL, MASK_SOLID}) do
		local tr = util.TraceLine({start = start, endpos = endpos, filter = ply, mask = mask})
		if tr.Entity == lower then
			hit, bone = true, tr.PhysicsBone
			if set[bone] then return true end
		end
	end
	local dbg = GetConVar("zcity_gore_debug")
	if dbg and dbg:GetBool() then
		local ids = {}
		for id in pairs(set) do ids[#ids + 1] = id end
		print("[zcity_gore] lower half grab: hit=" .. tostring(hit) .. " physbone=" .. tostring(bone) .. " leg bones={" .. table.concat(ids, ",") .. "}")
	end
	if not hit then return nil end
	return false
end

hook.Add("PhysgunPickup", "zcity_gore_torso_lower_grab", function(ply, ent)
	if not IsValid(ent) or not ent:GetNWBool("ZCityTorsoLowerPart") then return end
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if aimedBoneIsLeg(ply, ent) == false then return false end
end)

local function noPickup(_, ent)
	if IsValid(ent) and ent:GetNWBool("ZCityTorsoLowerPart") then return false end
end
hook.Add("AllowPlayerPickup", "zcity_gore_torso_lower_nouse", noPickup)
hook.Add("GravGunPickupAllowed", "zcity_gore_torso_lower_nograv", noPickup)
hook.Add("GravGunPunt", "zcity_gore_torso_lower_nopunt", noPickup)
