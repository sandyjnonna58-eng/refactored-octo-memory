-- Взрыв конечности (по просьбе: «помимо обычного отрезания конечность взрывается, как голова»).
-- Сильное нережущее попадание в руку или ногу (пуля, дробь, тупой удар - тот же порог урона Z-City в
-- organism/tier_1/sv_input.lua, что сносит голову hg.ExplodeHead) - конечность разлетается: Z-City убирает её как
-- обычно (обрубок, артериальное кровотечение, куски мяса, звук взрыва головы), сверху - больше мяса, облако крови и
-- всплеск из обрубка. Режущее оружие не взрывает - его отрезает аддон z-city arteries & blood (lua/zcity_gore:
-- отрезанный кусок висит на артериях). Взрывы гранат и РПГ тоже рвут конечности через аддон.
-- Аддон оборачивает hg.organism.AmputateLimb и пропускает только свои разрезы - поэтому зовём исходную функцию
-- Z-City (hg.ZCityGore_BaseAmputate); без аддона - обычную. Выкл.: rem_limb_burst 0 (тогда - как у аддона: не рвёт).
local cv = CreateConVar("rem_limb_burst", "1", FCVAR_ARCHIVE, "Strong non-cutting hits blow a limb apart like the head (0 = off)", 0, 1)

local BONES = {
	larm = "ValveBiped.Bip01_L_Forearm", rarm = "ValveBiped.Bip01_R_Forearm",
	lleg = "ValveBiped.Bip01_L_Calf", rleg = "ValveBiped.Bip01_R_Calf",
}
local SOUNDS = {"physics/flesh/flesh_bloody_break.wav", "physics/body/body_medium_break2.wav", "physics/body/body_medium_break3.wav"}

-- игрок, которому принадлежит тело (у трупа - через регдолл)
local function BodyOwner(ent)
	if IsValid(ent) and ent:IsRagdoll() and hg.RagdollOwner then
		local ply = hg.RagdollOwner(ent)
		if IsValid(ply) then return ply end
	end
	return ent
end

function hg.LimbBurst(org, limb, force)
	if not cv:GetBool() or not org or not BONES[limb] or org[limb .. "amputated"] ~= false then return false end
	local owner = org.owner
	if not IsValid(owner) then return false end

	-- аддон потом эту конечность ещё раз не отрежет (у него один кусок на конечность на тело)
	local base = BodyOwner(owner)
	if IsValid(base) then
		base._zgSevered = base._zgSevered or {}
		base._zgSevered[limb] = true
	end

	local amputate = hg.ZCityGore_BaseAmputate or hg.organism.AmputateLimb
	local ok, err = pcall(amputate, org, limb)
	if not ok then ErrorNoHalt("[rem_limb_burst] " .. tostring(err) .. "\n") end
	if org[limb .. "amputated"] ~= true then return false end

	local ent = hg.GetCurrentCharacter and hg.GetCurrentCharacter(owner) or owner
	if not IsValid(ent) then ent = owner end
	local bone = ent:LookupBone(BONES[limb])
	local pos = bone and ent:GetBonePosition(bone) or ent:WorldSpaceCenter()
	force = isvector(force) and force or vector_origin

	-- мясо разлетается по удару
	if SpawnMeatGore then pcall(SpawnMeatGore, ent, pos, math.random(5, 8), force * 0.5 + VectorRand(-150, 150), 0.9) end
	-- облако крови (как при разрыве тела Z-City) и всплеск из обрубка (эффект аддона)
	net.Start("hg_fullbody_bloodmist")
		net.WriteVector(pos)
		net.WriteVector(force)
		net.WriteUInt(35, 8)
	net.Broadcast()
	if ZCityGore and ZCityGore.SendSeverBlood then pcall(ZCityGore.SendSeverBlood, ent, limb, pos, force) end
	ent:EmitSound(SOUNDS[math.random(#SOUNDS)], 75, math.random(90, 110))
	util.Decal("Normal.Blood1", pos, pos - Vector(0, 0, 72), ent) -- пятно крови Z-City
	return true
end

-- Клинки голову с одного удара не взрывают (Z-City в sv_input.lua умножает режущий урон по голове x25 и сносит её
-- hg.ExplodeHead): голову режет аддон zcity_gore - за несколько ударов по шее, и она висит на артериях. Своё отрезание
-- головы (organism/sv_decap.lua) убрано по просьбе. Без аддона - как в Z-City.
local BLADE_CLASS = {
	weapon_buck200knife = true, weapon_combatknife = true, weapon_sogknife = true, weapon_pocketknife = true,
	weapon_hg_spear_knife = true, weapon_hg_machete = true, weapon_fc3_machete = true, weapon_fc3_tribalknife = true,
	weapon_hg_axe = true, weapon_hatchet = true, weapon_tomahawk = true, weapon_hg_katana = true, weapon_hg_slayersword = true,
	weapon_chainsaw = true,
}
local BLADE_PATTERNS = {"chainsaw", "katana", "sword", "axe", "hatchet", "machete", "knife", "bayonet"}

function hg.RemDecapBlocks(dmgInfo)
	if not ZCityGore or not hg.ZCityGore_Sever then return false end
	local wep = dmgInfo:GetInflictor()
	if IsValid(wep) and wep:IsPlayer() then wep = wep:GetActiveWeapon() end
	if not IsValid(wep) or not wep:IsWeapon() then return false end
	local class = wep:GetClass()
	if BLADE_CLASS[class] then return true end
	for _, p in ipairs(BLADE_PATTERNS) do
		if string.find(class, p, 1, true) then return true end
	end
	return false
end

-- тест: rem_test_limbburst (sh_remtests.lua)
