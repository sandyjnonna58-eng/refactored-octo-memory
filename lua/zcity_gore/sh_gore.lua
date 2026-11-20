ZCityGore = ZCityGore or {}

-- remorse (сборка remorseism): аддон встроен в сборку, своё поверх него - organism/sv_limbburst.lua.
-- zcity_gore_block_gibs: аддон удалял/прятал ВСЕ куски мяса и обрубки (headpartial, limbspartial, арбузные куски...) -
-- ломал взрыв головы Z-City, наше отрезание головы (organism/sv_decap.lua) и взрыв конечностей. 0 по умолчанию.
-- zcity_gore_heads: голову режущим оружием режет аддон - голова висит на артериях (по жалобе «нет артерий, когда
-- режешь»); 0 - режет organism/sv_decap.lua (с 4-го удара, шанс по оружию, обрубки Zippy), без артерий.
CreateConVar("zcity_gore_block_gibs", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Remove/hide Z-City gore gibs and stumps (old addon behaviour, breaks head explosions)", 0, 1)
CreateConVar("zcity_gore_heads", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Cutting weapons sever the head through this addon, it hangs on arteries (0 = organism/sv_decap.lua does it)", 0, 1)

ZCityGore.LimbBones = {
	larm = "ValveBiped.Bip01_L_Forearm",
	rarm = "ValveBiped.Bip01_R_Forearm",
	lleg = "ValveBiped.Bip01_L_Calf",
	rleg = "ValveBiped.Bip01_R_Calf",
	head = "ValveBiped.Bip01_Head1",
}

ZCityGore.HitgroupToLimb = {
	[HITGROUP_LEFTARM] = "larm",
	[HITGROUP_RIGHTARM] = "rarm",
	[HITGROUP_LEFTLEG] = "lleg",
	[HITGROUP_RIGHTLEG] = "rleg",
	[HITGROUP_HEAD] = "head",
}

-- Hits needed to sever a limb, per weapon class. Every hit adds 1/N progress to the limb,
-- so different weapons can be mixed on the same limb. 1 = cut off in a single hit.
ZCityGore.WeaponHits = {
	weapon_hg_axe        = 1,  -- woodcutting axe: one hit
	weapon_hatchet       = 3,
	weapon_tomahawk      = 3,
	weapon_hg_machete    = 4,
	weapon_pocketknife   = 10, -- knives: slash the limb many times
	weapon_sogknife      = 8,
	weapon_buck200knife  = 8,
	weapon_hg_spear_knife = 10,
}
-- Any other held weapon that deals slash damage (broken glass, shards...)
ZCityGore.DefaultSharpHits = 12
-- Head needs this many times more hits than a limb with the same weapon
ZCityGore.HeadHitsMul = 2
-- remorse: ударов по шее для отдельного оружия (вместо удары по конечности x HeadHitsMul) - мечам иначе нужно 24
ZCityGore.HeadHits = {
	weapon_hg_axe = 2, weapon_hatchet = 5, weapon_tomahawk = 5,
	weapon_hg_machete = 6, weapon_fc3_machete = 6, weapon_fc3_tribalknife = 7,
	weapon_hg_katana = 5, weapon_hg_slayersword = 4, weapon_chainsaw = 3,
}

-- Only a hit close to the joint counts (elbow / knee / neck), distance in units
ZCityGore.JointRadius = 7
ZCityGore.HeadJointRadius = 10 -- remorse: 7 - удар в лицо/макушку не засчитывался
-- Joint bone per limb (the bone the limb is severed at)
ZCityGore.JointBones = {
	larm = "ValveBiped.Bip01_L_Forearm",
	rarm = "ValveBiped.Bip01_R_Forearm",
	lleg = "ValveBiped.Bip01_L_Calf",
	rleg = "ValveBiped.Bip01_R_Calf",
	head = "ValveBiped.Bip01_Head1",
}

-- Kept for other addons / old code: the set of weapon classes that can sever
ZCityGore.Weapons = {}
for class in pairs(ZCityGore.WeaponHits) do ZCityGore.Weapons[class] = true end
-- Explosions: every attached limb is rolled separately. Within BlastCloseRange each limb is
-- torn off for sure, out to BlastRange the chance falls to BlastFarChance. At least one limb always goes.
ZCityGore.BlastRange = 300
ZCityGore.BlastCloseRange = 120
ZCityGore.BlastFarChance = 0.35
-- Mass of a severed limb. Hands throw force is min(5000, mass*800), so light limbs fly far.
ZCityGore.LimbRootMass = 14
ZCityGore.LimbPartMass = 4

-- ---------------------------------------------------------------------------
-- Artery tether: a severed piece stays attached to the stump by a stretchy red artery
-- and hangs / dangles from it. The artery snaps if the body gets too far away.
-- ---------------------------------------------------------------------------
-- Which limbs hang on an artery. The head hangs from the neck too: the beheading burst still
-- plays, the head then dangles from the stump (set head = false to let it fall free again)
ZCityGore.TetherLimbs = {larm = true, rarm = true, lleg = true, rleg = true, head = true}
-- Explosions tear the limb completely off and throw it away
ZCityGore.TetherOnBlast = false
-- Free length of the artery in units (distance stump -> cut face of the hanging piece)
ZCityGore.TetherLength = {larm = 12, rarm = 12, lleg = 14, rleg = 14, head = 10}
-- The artery snaps when stretched to this many times its length (body ran away / was teleported)
ZCityGore.TetherSnapMul = 2.5
-- How fast (units/s) a stretched artery pulls the limb back toward the stump
ZCityGore.TetherPullSpeed = 140
-- A cut throws a hanging limb this much as hard as a free one (it must not rocket off and get yanked back)
ZCityGore.TetherThrowMul = 0.2

-- ---------------------------------------------------------------------------
-- Torso dismemberment (cut in half at the chest). The lower half hangs from the upper half on a
-- thick chest artery, exactly like a severed limb hangs from its stump.
-- ---------------------------------------------------------------------------
ZCityGore.TorsoUpperModel = "models/torsopartial/torsovar.mdl"   -- cap on the upper half
ZCityGore.TorsoLowerModel = "models/torsopartial/abdomenvar.mdl" -- cap on the lower half
-- Explosions closer than this (units, convar zcity_gore_torso_blast_radius) cut the torso
ZCityGore.TorsoOnBlast = true
-- A torso cut by an explosion can hang on the artery too (false = the halves fly apart freely)
ZCityGore.TorsoTetherOnBlast = true
-- Free length of the chest artery (units, cut face of the upper half -> cut face of the lower half)
ZCityGore.TorsoTetherLength = 26
-- Snaps when stretched to this many times its length
ZCityGore.TorsoTetherSnapMul = 2.6
-- Max speed (units/s) at which a stretched artery drags the lower half back
ZCityGore.TorsoTetherPullSpeed = 170
-- The cut pushes the halves apart this much as hard as a free cut (they must not rocket off and be yanked back)
ZCityGore.TorsoTetherThrowMul = 0.3
-- Does a torso cut by an explosion kill the owner right away (limb blasts always do)?
-- false = they lie there bleeding and screaming like after a c-menu cut
ZCityGore.TorsoBlastKills = false

-- ---------------------------------------------------------------------------
-- Artery bundles (shared: the server decides which strand tears when, the client draws them)
--
-- A severed limb hangs on 3 thin arteries, a cut torso on 5. Every strand has its own thickness,
-- colour, position on the cut face (ang, degrees) and tear point. `tear` is how far into the stretch
-- the strand rips: ratio = 1 + (snapMul - 1) * tear. The strand with tear = 1 is the last one,
-- when it rips the piece falls free (same moment the old single-snap happened).
-- r = radius in units, col = RGB, stub = length of the ragged end that is left hanging after a tear.
-- Strands are listed in tear order: thin and weak first, thickest last.
-- ---------------------------------------------------------------------------
ZCityGore.LimbArteries = {
	{r = 0.17, ang = 35,  col = {208, 18, 24}, tear = 0.55, droop = 1.00, stub = 4.5},
	{r = 0.21, ang = 155, col = {168, 10, 19}, tear = 0.80, droop = 0.88, stub = 6.0},
	{r = 0.25, ang = 275, col = {112, 6, 17},  tear = 1.00, droop = 1.12, stub = 7.5},
}
ZCityGore.TorsoArteries = {
	{r = 0.26, ang = 18,  col = {190, 15, 21}, tear = 0.46, droop = 1.00, stub = 8},
	{r = 0.30, ang = 90,  col = {152, 9, 18},  tear = 0.60, droop = 0.90, stub = 9},
	{r = 0.34, ang = 162, col = {204, 17, 23}, tear = 0.72, droop = 1.10, stub = 10},
	{r = 0.40, ang = 234, col = {122, 7, 17},  tear = 0.86, droop = 0.95, stub = 11},
	{r = 0.52, ang = 306, col = {92, 5, 14},   tear = 1.00, droop = 1.05, stub = 13},
}
-- How far from the middle of the cut face the strands leave it (units)
ZCityGore.LimbArterySpread = 1.1
ZCityGore.TorsoArterySpread = 3.2

-- Stretch ratio (distance / free length) at which this strand rips
function ZCityGore.TearRatio(def, snapMul)
	return 1 + ((snapMul or 2.5) - 1) * (def.tear or 1)
end

-- Bit mask with every strand marked as torn
function ZCityGore.FullArteryMask(defs)
	return bit.lshift(1, #defs) - 1
end

-- The entity that currently represents a body: a player can be standing, a fake ragdoll or a corpse.
-- `owner` is the player, or the corpse ragdoll if the body never had a player.
function ZCityGore.ResolveBody(owner)
	if not IsValid(owner) then return end
	if not owner:IsPlayer() then return owner end

	local function ragdollOf(ply)
		local cands = {ply.FakeRagdoll, ply:GetNWEntity("FakeRagdoll"), ply:GetNWEntity("RagdollDeath")}
		if isfunction(ply.GetRagdollEntity) then cands[#cands + 1] = ply:GetRagdollEntity() end
		for i = 1, #cands do
			local e = cands[i]
			if IsValid(e) and e:IsRagdoll() and not (e.IsSeveredLimb or e:GetNWBool("IsSeveredLimb")) then return e end
		end
	end

	if istable(hg) and isfunction(hg.GetCurrentCharacter) then
		local c = hg.GetCurrentCharacter(owner)
		if IsValid(c) and (owner:Alive() or c ~= owner) then return c end
	end
	local rag = ragdollOf(owner)
	if IsValid(rag) then return rag end
	if owner:Alive() then return owner end
end

-- ---------------------------------------------------------------------------
-- Compatibility: "Citizen Clothing Overhaul" and "Citizen Faces Overhaul" (optional, separate addons)
--
-- Both give every citizen-model prop_ragdoll a RANDOM clothing / face sub-material unless it carries their
-- "handled" flag (_ClothingHandled / _faceHandled). Our severed limbs, heads and torso halves are new
-- prop_ragdolls of the body's model, so without this they would get a different random outfit / face than the
-- body they came from. Call this after the appearance of `source` was copied onto `target`: it marks the piece as
-- handled (the mods leave it alone) and keeps the source's sub-materials (clothing, face) on it.
-- Harmless when neither addon is installed.
-- ---------------------------------------------------------------------------
if SERVER then
	local function syncSubMaterials(target, source)
		if not IsValid(target) or not IsValid(source) then return end
		local mats = source:GetMaterials()
		if not mats then return end
		for i = 0, #mats - 1 do
			local sm = source:GetSubMaterial(i)
			if sm and sm ~= "" and target:GetSubMaterial(i) ~= sm then
				target:SetSubMaterial(i, sm)
			end
		end
	end

	function ZCityGore.ProtectOverhaulAppearance(target, source)
		if not IsValid(target) then return end
		target._ClothingHandled = true -- Citizen Clothing Overhaul
		target._faceHandled = true     -- Citizen Faces Overhaul
		if not IsValid(source) then return end
		-- NPC corpses get their outfit / face applied a tick late by those addons: copy again once it is there
		timer.Simple(0.1, function() syncSubMaterials(target, source) end)
		timer.Simple(1.2, function() syncSubMaterials(target, source) end)
	end
end
