-- Совместимость с отдельным аддоном "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk;
-- в репозиторий не кладём - чужие модели/звуки, ставится в garrysmod/addons). У этого оружия своя вьюмодель первого лица:
-- пока оно в руках, homigrad отдаёт камеру движку (cl_camera.lua: hg.CameraYield) - иначе он рисует своё тело
-- от первого лица и вьюмодель с руками не видна. В регдолле homigrad всё как обычно.
-- "ULTRAKILL Coin Mechanics" (монетки, ultrakill_toss_coin) тоже поддерживается и ничего тут не требует: рикошет бьёт
-- обычным TakeDamageInfo с позицией попадания - организм homigrad разбирает его сам.
hg.UK = hg.UK or {}

local UK_BASES = {weapon_dredux_base2_uk = true, weapon_dredux_base3_uk = true}

function hg.UK.Weapon(ply)
	if not IsValid(ply) or not ply:IsPlayer() or IsValid(ply.FakeRagdoll) then return false end
	local w = ply:GetActiveWeapon()
	if not IsValid(w) then return false end
	return string.sub(w:GetClass(), 1, 17) == "weapon_dredux_uk_" or UK_BASES[w.Base or ""] == true
end

-- общая уступка камеры чужим аддонам (cl_camera.lua): Снейк (sh_mgsv.lua) и оружие ULTRAKILL (у него своя вьюмодель)
function hg.CameraYield(ply)
	if hg.MGSV and hg.MGSV.Owns and hg.MGSV.Owns(ply) then return true end
	return hg.UK.Weapon(ply)
end
