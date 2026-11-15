-- Совместимость с отдельным аддоном «[V.A.C] Vehicles.Action.Chaos» (техника, самолёты, корабли; в репозиторий
-- не кладём - 1.2 ГБ, чужие модели; ставится из Мастерской). У V.A.C. свой модуль под Z-City
-- (lua/vac/core/sh_compat_zcity.lua): в его сиденьях Z-City не роняет в регдолл, не берёт камеру/мышь/колесо оружия.
-- Он оборачивает хуки по имени раз в 10 с - а наш экран смерти (cl_cdeath.lua) снимает и заново ставит камеру
-- Z-City ("jopa", "homigrad-view"), и до следующей обёртки камера в самолёте/танке снова наша. Здесь - то, чего V.A.C.
-- про эту сборку не знает:
--   камера   hg.CameraYield (её зовёт cl_camera.lua прямо внутри своей камеры) уступает, пока вид у V.A.C.;
--   наши хуки управления (качание прицела от алкоголя/наркотиков/тошноты/паники/ломки, пьяная походка) в его
--            сиденье молчат: они крутят cmd - в самолёте это руль и прицел турели (hg.VAC.Seated).
-- Без V.A.C. ничего не делает.
hg.VAC = hg.VAC or {}
local M = hg.VAC

local function Z() return VAC and VAC.ZCity end

-- аддон стоит
function M.Present() return Z() ~= nil end

-- игрок сидит в технике V.A.C. (любое место)
function M.Seated(ply)
	local z = Z()
	if not z or not IsValid(ply) or not ply.InVehicle or not ply:InVehicle() then return false end
	return z.IsVAC and z.IsVAC(ply:GetVehicle()) or false
end

if CLIENT then
	-- вид у V.A.C.: сидит в его технике, карта командира, камера ракеты
	function M.HasView()
		local z = Z()
		if not z then return false end
		if z.HasView then
			local ok, yes = pcall(z.HasView)
			return ok and yes or false
		end
		return M.Seated(LocalPlayer())
	end

	-- цепочкой к уже заданной (Снейк из sh_ultrakill.lua): компат-файлы грузятся по алфавиту, этот - позже
	local prev = hg.CameraYield
	function hg.CameraYield(ply)
		if ply == LocalPlayer() and M.HasView() then return true end
		return prev and prev(ply) or false
	end
end
