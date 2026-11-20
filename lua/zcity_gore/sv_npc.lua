-- |Z-CITY| GORE NPC support (server)
--
-- NPCs (and their corpses) get the same gore as players: sharp weapons cut limbs / the head off at the joint,
-- explosions tear limbs off and cut the body in half, cut limbs hang from the stump on their arteries and
-- rip off when stretched, a body cut in two leaves a lower half hanging on the chest artery.
--
-- NPCs have no Homigrad organism, so none of the player code paths (HomigradDamage, AmputateLimb wrapper)
-- fire for them. Everything here keeps its own small state on the entity (ent.__zgNpc) and calls the shared
-- pieces: hg.SpawnSeveredLimb (the hanging piece + artery) and ZCityGore.SeverTorso (the two halves).
--
-- Works on every NPC with the standard humanoid skeleton (ValveBiped: citizens, rebels, combine, metrocops,
-- zombies...). Other NPCs (antlions, headcrabs...) are left alone. Best effort for NextBots.
--
-- When an NPC dies its ragdoll takes over: pieces still hanging from the NPC move to the corpse, cut limbs
-- stay cut, a torso cut that was waiting for the death is carried out. NPC corpses can be chopped too.
--
-- ConVars: zcity_gore_npc (0 disables), zcity_gore_npc_bleed (HP/s per missing limb), zcity_gore_npc_torso
-- Public: ZCityGore.NPCSever(ent, limb, dmgInfo, source), ZCityGore.NPCSeverTorso(ent, force)

local LB = ZCityGore.LimbBones
local vecZero = Vector(0, 0, 0)
local vecAlmostZero = Vector(0.01, 0.01, 0.01) -- exact 0 gives singular bone matrices (not for the head)

local zg_npc = CreateConVar("zcity_gore_npc", "1", FCVAR_ARCHIVE, "NPCs and NPC corpses can be dismembered like players (0 = off)", 0, 1)
local zg_npc_bleed = CreateConVar("zcity_gore_npc_bleed", "2", FCVAR_ARCHIVE,
	"HP per second a living NPC loses for every missing limb (0 = no bleeding). A beheaded NPC always dies", 0, 50)
local zg_npc_torso = CreateConVar("zcity_gore_npc_torso", "1", FCVAR_ARCHIVE, "A close explosion cuts an NPC in half (0 = off)", 0, 1)

local function boneOf(ent, name)
	local b = ent:LookupBone(name)
	if b and b >= 0 then return b end
end

local function isLiveNpc(ent)
	return IsValid(ent) and (ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot()))
end

-- a body this module handles: a living NPC or an NPC corpse, with the humanoid skeleton
local function isNPCBody(ent)
	if not IsValid(ent) then return false end
	if not (isLiveNpc(ent) or ent.__zgNpcCorpse == true) then return false end
	return boneOf(ent, "ValveBiped.Bip01_Spine2") ~= nil
end

local function stateOf(ent)
	local st = ent.__zgNpc
	if not st then
		st = {cut = {}, progress = {}, nextHit = {}}
		ent.__zgNpc = st
	end
	return st
end

local function collectBones(ent, bone, out)
	out[#out + 1] = bone
	for _, child in ipairs(ent:GetChildBones(bone) or {}) do
		if child ~= bone then collectBones(ent, child, out) end
	end
end

-- Hide a cut limb on the body (living NPC or corpse). The bones are scaled away; on a ragdoll the limb's
-- physics stay jointed to the body (so the stump follows it) but stop colliding.
local function hideLimb(ent, limb)
	local root = boneOf(ent, LB[limb])
	if not root then return end
	local bones = {}
	collectBones(ent, root, bones)
	local scale = limb == "head" and vecZero or vecAlmostZero
	for i = 1, #bones do ent:ManipulateBoneScale(bones[i], scale) end

	if ent:IsRagdoll() then
		local seen = {}
		for i = 1, #bones do
			local physID = ent:TranslateBoneToPhysBone(bones[i])
			if physID and physID >= 0 and not seen[physID] then
				seen[physID] = true
				local phys = ent:GetPhysicsObjectNum(physID)
				if IsValid(phys) then
					phys:EnableCollisions(false)
					phys:SetMass(0.5)
				end
			end
		end
	end

	if limb == "head" then
		ent.noHead = true
		ent:SetNWBool("noHead", true)
	end
end

-- ---------------------------------------------------------------------------
-- Killing and bleeding
-- ---------------------------------------------------------------------------
local function killNPC(ent, dmgInfo)
	if not isLiveNpc(ent) or ent:Health() <= 0 then return end
	local st = stateOf(ent)
	st.killing = true -- our own damage hooks ignore this hit
	local d = DamageInfo()
	d:SetDamage(ent:Health() + 1000)
	d:SetDamageType(DMG_GENERIC)
	local att = dmgInfo and dmgInfo:GetAttacker()
	d:SetAttacker(IsValid(att) and att or game.GetWorld())
	local inf = dmgInfo and dmgInfo:GetInflictor()
	d:SetInflictor(IsValid(inf) and inf or game.GetWorld())
	d:SetDamageForce(dmgInfo and dmgInfo:GetDamageForce() or vector_origin)
	ent:TakeDamageInfo(d)
	st.killing = nil
end

local bleeders = {}
local nextBleed = 0

hook.Add("Think", "zcity_gore_npc_bleed", function()
	local ct = CurTime()
	if ct < nextBleed then return end
	nextBleed = ct + 0.5
	local rate = zg_npc_bleed:GetFloat()
	for npc in pairs(bleeders) do
		if not IsValid(npc) or npc:Health() <= 0 then
			bleeders[npc] = nil
		elseif rate > 0 then
			local missing = 0
			for limb in pairs(stateOf(npc).cut) do
				if limb ~= "head" then missing = missing + 1 end
			end
			if missing > 0 then
				local d = DamageInfo()
				d:SetDamage(rate * missing * 0.5)
				d:SetDamageType(bit.bor(DMG_GENERIC, DMG_PREVENT_PHYSICS_FORCE))
				d:SetAttacker(game.GetWorld())
				d:SetInflictor(game.GetWorld())
				npc:TakeDamageInfo(d)
			end
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Cutting a limb off
-- ---------------------------------------------------------------------------
function ZCityGore.NPCSever(ent, limb, dmgInfo, source)
	if not zg_npc:GetBool() or not LB[limb] or not isNPCBody(ent) then return false end
	local st = stateOf(ent)
	if st.cut[limb] then return false end
	st.cut[limb] = true

	local force = (dmgInfo and dmgInfo:GetDamageForce()) or vector_origin
	local blast = dmgInfo ~= nil and dmgInfo:IsDamageType(DMG_BLAST)

	-- the hanging piece (artery, tether, stump anchor) is cut from the intact pose, then the limb is hidden
	local ok, rag = pcall(hg.SpawnSeveredLimb, ent, limb, dmgInfo)
	if not ok then
		ErrorNoHalt("[zcity_gore] npc sever: " .. tostring(rag) .. "\n")
		rag = nil
	end
	hideLimb(ent, limb)

	local cutPos = ZCityGore.JointPos(ent, limb) or ent:WorldSpaceCenter()
	if not blast then
		ZCityGore.SendSeverBlood(ent, limb, cutPos, force)
		if SpawnMeatGore and limb ~= "head" then
			pcall(SpawnMeatGore, ent, cutPos, 4, VectorRand(-260, 260), 0.8)
		end
		ZCityGore.TearSfx(IsValid(rag) and rag or ent, true)
	end

	if isLiveNpc(ent) then
		if limb == "head" then
			-- nobody lives on without a head (next tick: we may be inside a damage hook right now)
			timer.Simple(0, function() killNPC(ent, dmgInfo) end)
		else
			bleeders[ent] = true
		end
	end
	local dbg = GetConVar("zcity_gore_debug")
	if dbg and dbg:GetBool() then print("[zcity_gore] npc sever", limb, source or "?") end
	return true
end

-- Cut an NPC (or NPC corpse) in half at the chest.
-- A living NPC dies, and its corpse is split as soon as the ragdoll exists.
function ZCityGore.NPCSeverTorso(ent, force)
	if not zg_npc:GetBool() or not isNPCBody(ent) then return false end
	local st = stateOf(ent)
	if st.torsoCut or st.torso then return false end
	force = force or VectorRand(-250, 250)

	if ent:IsRagdoll() then
		local ok, res = pcall(ZCityGore.SeverTorso, ent, force, false)
		if ok and res then
			st.torsoCut = true
			return true
		end
		return false
	end
	st.torso = {force = force}
	killNPC(ent, nil)
	return true
end

-- ---------------------------------------------------------------------------
-- Sharp weapons
-- ---------------------------------------------------------------------------
hook.Add("ScaleNPCDamage", "zcity_gore_npc_hitgroup", function(npc, hitgroup)
	if IsValid(npc) then
		npc.__zgHit = hitgroup
		npc.__zgHitT = CurTime()
	end
end)

local function limbForHit(ent, st, dmg)
	local hpos = dmg:GetDamagePosition()
	local hasPos = hpos and hpos:LengthSqr() >= 1

	-- NPCs: the hitgroup of the trace names the limb
	if math.abs(CurTime() - (ent.__zgHitT or -1)) < 0.05 then
		local limb = ZCityGore.HitgroupToLimb[ent.__zgHit]
		if limb and not st.cut[limb] then
			if hasPos then
				local j = ZCityGore.JointPos(ent, limb)
				if j and j:Distance(hpos) > ZCityGore.JointRadiusFor(limb) then return end -- not near the joint
			end
			return limb
		end
	end

	-- corpses (no hitgroups): the limb whose joint is closest to the hit
	if not hasPos then return end
	local best, bestDist
	for limb in pairs(ZCityGore.JointBones) do
		if not st.cut[limb] then
			local j = ZCityGore.JointPos(ent, limb)
			if j then
				local d = j:Distance(hpos)
				if d <= ZCityGore.JointRadiusFor(limb) and (not bestDist or d < bestDist) then
					best, bestDist = limb, d
				end
			end
		end
	end
	return best
end

hook.Add("EntityTakeDamage", "zcity_gore_npc_chop", function(ent, dmg)
	if not zg_npc:GetBool() or not dmg:IsDamageType(DMG_SLASH) or not isNPCBody(ent) then return end
	local st = stateOf(ent)
	if st.killing then return end
	local hits = ZCityGore.HitsForWeapon(dmg:GetInflictor())
	if not hits then return end
	local limb = limbForHit(ent, st, dmg)
	if not limb then return end

	if (st.nextHit[limb] or 0) > CurTime() then return end
	st.nextHit[limb] = CurTime() + 0.35
	if limb == "head" then hits = hits * (ZCityGore.HeadHitsMul or 2) end
	st.progress[limb] = (st.progress[limb] or 0) + 1 / hits -- each hit is worth 1/hits of a cut
	if st.progress[limb] < 0.999 then return end
	ZCityGore.NPCSever(ent, limb, dmg, "slash")
end)

-- ---------------------------------------------------------------------------
-- Explosions
-- ---------------------------------------------------------------------------
local function blastDist(ent, dmg)
	local pos = dmg:GetDamagePosition()
	if not pos or pos:LengthSqr() < 1 then
		local inf = dmg:GetInflictor()
		if IsValid(inf) then pos = inf:GetPos() end
	end
	if not pos then return 9999 end
	return math.min(ent:GetPos():Distance(pos), ent:WorldSpaceCenter():Distance(pos))
end

local function blastLimbChance(dist)
	local close = ZCityGore.BlastCloseRange or 120
	local range = ZCityGore.BlastRange or 300
	local far = ZCityGore.BlastFarChance or 0.35
	if dist <= close then return 1 end
	if dist >= range then return far end
	return Lerp((dist - close) / (range - close), 1, far)
end

local BLAST_LIMBS = {"larm", "rarm", "lleg", "rleg"} -- the head is never taken by an explosion

local function npcBlast(ent, dmg, dist)
	if not IsValid(ent) then return end
	local st = stateOf(ent)
	if (st.blastAt or 0) > CurTime() - 1 then return end
	st.blastAt = CurTime()

	local living = isLiveNpc(ent) and ent:Health() > 0
	local force = dmg:GetDamageForce()

	-- very close: the body is cut in half first, the legs go with the lower half
	local torso = false
	if zg_npc_torso:GetBool() and ZCityGore.TorsoBlastEnabled and ZCityGore.TorsoBlastEnabled()
		and dist <= ZCityGore.TorsoBlastRadius() and not st.torso and not st.torsoCut then
		if ent:IsRagdoll() then
			local ok, res = pcall(ZCityGore.SeverTorso, ent, force, true)
			if ok and res then
				st.torsoCut = true
				torso = true
			end
		elseif living then
			st.torso = {force = force} -- carried out on the corpse
			torso = true
		end
	end

	local candidates = {}
	for i = 1, #BLAST_LIMBS do
		local limb = BLAST_LIMBS[i]
		local legGone = torso and (limb == "lleg" or limb == "rleg")
		if not st.cut[limb] and not legGone then candidates[#candidates + 1] = limb end
	end

	if #candidates > 0 then
		local chance = blastLimbChance(dist)
		local chosen = {}
		for i = 1, #candidates do
			if math.random() < chance then chosen[#chosen + 1] = candidates[i] end
		end
		if #chosen == 0 and not torso then chosen[1] = candidates[math.random(#candidates)] end -- always at least one
		for i = 1, #chosen do ZCityGore.NPCSever(ent, chosen[i], dmg, "blast") end
	end

	-- a cut body or a blast right next to it kills; further out the NPC survives, missing limbs and bleeding
	if living and (torso or dist <= (ZCityGore.BlastCloseRange or 120)) then killNPC(ent, dmg) end
end

hook.Add("EntityTakeDamage", "zcity_gore_npc_blast", function(ent, dmg)
	if not zg_npc:GetBool() or not dmg:IsDamageType(DMG_BLAST) or not isNPCBody(ent) then return end
	local st = stateOf(ent) -- also creates the state an NPC that dies from this very blast hands to its corpse
	if st.killing then return end
	local dist = blastDist(ent, dmg)
	if dist > ZCityGore.BlastRange then return end

	local copy = DamageInfo()
	copy:SetDamage(dmg:GetDamage())
	copy:SetDamageType(DMG_BLAST)
	copy:SetDamagePosition(dmg:GetDamagePosition())
	copy:SetDamageForce(dmg:GetDamageForce())
	copy:SetAttacker(dmg:GetAttacker())
	copy:SetInflictor(dmg:GetInflictor())
	timer.Simple(0, function()
		-- the NPC may have been killed by this very blast: then its corpse takes the cut
		local target = IsValid(ent) and ent or st.corpse
		if IsValid(target) then npcBlast(target, copy, dist) end
	end)
end)

-- ---------------------------------------------------------------------------
-- Death: the ragdoll takes over
-- ---------------------------------------------------------------------------
hook.Add("CreateEntityRagdoll", "zcity_gore_npc_corpse", function(npc, rag)
	if not zg_npc:GetBool() or not IsValid(npc) or not IsValid(rag) or not isNPCBody(npc) then return end
	local st = stateOf(npc)
	rag.__zgNpc = st
	rag.__zgNpcCorpse = true
	st.corpse = rag

	-- pieces that hang from the NPC now hang from its corpse
	for piece, data in pairs(hg.severedLimbs or {}) do
		if data.owner == npc then
			data.owner = rag
			if data.tether then data.tether.owner = rag end
			if IsValid(piece) then piece:SetNWEntity("SeveredBody", rag) end
		end
	end

	timer.Simple(0, function()
		if not IsValid(rag) then return end
		-- legs that were cut off stay gone on the lower half of a split corpse
		rag.__zgLegs = {llegamputated = st.cut.lleg == true, rlegamputated = st.cut.rleg == true}
		for limb in pairs(st.cut) do hideLimb(rag, limb) end
		local pending = st.torso
		if pending then
			st.torso = nil
			local ok, res = pcall(ZCityGore.SeverTorso, rag, pending.force, true)
			if ok and res then st.torsoCut = true end
		end
	end)
end)
