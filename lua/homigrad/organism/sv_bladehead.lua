-- Голову режущим оружием не отрезает (по просьбе; своё отрезание головы sv_decap.lua убрано).
-- Z-City (tier_1/sv_input.lua) сносит голову с одного сильного удара, режущий урон по голове там x25 - ножи, мачете,
-- топоры, мечи и пила так голову не взрывают и не отрезают: sv_input.lua спрашивает hg.RemDecapBlocks.
-- Пули, дробь, взрывы, тупое оружие - как в Z-City. rem_blade_headexplode 1 - вернуть как у Z-City.
local cv = CreateConVar("rem_blade_headexplode", "0", FCVAR_ARCHIVE, "Cutting weapons can blow the head off in one hit like in Z-City (0 = never)", 0, 1)

local BLADE_CLASS = {
	weapon_buck200knife = true, weapon_combatknife = true, weapon_sogknife = true, weapon_pocketknife = true,
	weapon_hg_spear_knife = true, weapon_hg_machete = true, weapon_fc3_machete = true, weapon_fc3_tribalknife = true,
	weapon_hg_axe = true, weapon_hatchet = true, weapon_tomahawk = true, weapon_hg_katana = true, weapon_hg_slayersword = true,
	weapon_chainsaw = true,
}
-- оружие из других наборов - по имени класса
local BLADE_PATTERNS = {"chainsaw", "katana", "sword", "axe", "hatchet", "machete", "knife", "bayonet"}

function hg.RemDecapBlocks(dmgInfo)
	if cv:GetBool() then return false end
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
