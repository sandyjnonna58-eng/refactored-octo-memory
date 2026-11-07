-- Совместимость с отдельными аддонами ULTRAKILL (в репозиторий не кладём - чужие модели/звуки, ставятся в garrysmod/addons):
--   "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk) - оружие с вьюмоделью первого лица;
--   "ULTRAKILL Movement Collection" (слайд, дэш, прыжки от стен; серверная ukmove_movement_enabled);
--   "ULTRAKILL Coin Mechanics" (монетки, ultrakill_toss_coin) - урон идёт обычным TakeDamageInfo, отдельно не трогаем.
-- Пока в руках оружие пака, homigrad отдаёт камеру движку (cl_camera.lua: hg.CameraYield) - иначе он рисует своё тело
-- от первого лица и вьюмодель с руками не видна. Когда включено движение ULTRAKILL, инерция homigrad выключена
-- (movement/sh_inertia.lua), чтобы не гасила слайд/дэш. В регдолле homigrad всё как обычно.
hg.UK = hg.UK or {}

local UK_BASES = {weapon_dredux_base2_uk = true, weapon_dredux_base3_uk = true}

function hg.UK.Weapon(ply)
	if not IsValid(ply) or not ply:IsPlayer() or IsValid(ply.FakeRagdoll) then return false end
	local w = ply:GetActiveWeapon()
	if not IsValid(w) then return false end
	return string.sub(w:GetClass(), 1, 17) == "weapon_dredux_uk_" or UK_BASES[w.Base or ""] == true
end

function hg.UK.MoveOn()
	local cv = GetConVar("ukmove_movement_enabled")
	return cv and cv:GetBool() or false
end

-- общая уступка камеры чужим аддонам: Снейк (sh_mgsv.lua) или оружие ULTRAKILL
function hg.CameraYield(ply)
	if hg.MGSV and hg.MGSV.Owns and hg.MGSV.Owns(ply) then return true end
	return hg.UK.Weapon(ply)
end
