-- Совместимость с отдельным аддоном "Metal Gear Solid V: Gameplay SWEP" (таблица MGSVSnake, оружие weapon_mgsv_*).
-- Самого аддона в репозитории нет (модели и звуки MGSV чужие) - он ставится отдельной папкой в garrysmod/addons.
-- Пока у игрока в руках SWEP Снейка, homigrad уступает:
--   камера - работает камера аддона из-за плеча (от 3-го лица) вместо камеры homigrad от 1-го лица (cl_camera.lua);
--   тело - homigrad не рисует своё тело и аксессуары, аддон рисует Снейка (sh_utility.lua, hg.renderOverride);
--   движение - инерция homigrad выключена, у аддона своё движение: ползком, перекаты, укрытия (movement/sh_inertia.lua).
-- Если игрок упал регдоллом homigrad (FakeRagdoll) или без сознания - Снейк выключается, дальше работает homigrad.
hg.MGSV = hg.MGSV or {}

function hg.MGSV.Active(ply)
	if not MGSVSnake or not MGSVSnake.Active or not IsValid(ply) then return false end
	return MGSVSnake.Active(ply) and true or false
end

-- аддон грузится сам (autorun), поэтому оборачиваем его проверку, когда всё загружено
local function Wrap()
	local S = MGSVSnake
	if not S or not S.Active or S.RemWrapped then return end
	S.RemWrapped = true
	local orig = S.Active
	S.Active = function(ply)
		if IsValid(ply) and (IsValid(ply.FakeRagdoll) or (ply.organism and ply.organism.otrub)) then return false end
		return orig(ply)
	end
end
Wrap()
timer.Simple(0, Wrap)
hook.Add("InitPostEntity", "rem_mgsv_compat", Wrap)
