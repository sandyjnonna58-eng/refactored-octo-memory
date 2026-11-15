-- Совместимость с отдельным аддоном «[V.A.C] Vehicles.Action.Chaos» (техника, самолёты, корабли; в репозиторий
-- не кладём - 1.2 ГБ, чужие модели; ставится из Мастерской). У V.A.C. свой модуль под Z-City
-- (lua/vac/core/sh_compat_zcity.lua): в его сиденьях Z-City не роняет в регдолл, не берёт камеру/мышь/колесо оружия.
-- Он оборачивает хуки по имени раз в 10 с - а наш экран смерти (cl_cdeath.lua) снимает и заново ставит камеру
-- Z-City ("jopa", "homigrad-view"), и до следующей обёртки камера в самолёте/танке снова наша. Здесь - то, чего V.A.C.
-- про эту сборку не знает:
--   камера   hg.CameraYield (её зовёт cl_camera.lua прямо внутри своей камеры) уступает, пока вид у V.A.C.;
--   сиденья  hg.NoFakeInCar (sh_00yield.lua): наши хуки управления (качание прицела от алкоголя/наркотиков/тошноты/
--            паники/ломки, пьяная походка) в его технике молчат - они крутят cmd, а в самолёте это руль и прицел
--            турели (hg.InSpecialVehicle); регдолл/мышь Z-City - тоже, даже если обёртка V.A.C. слетела.
-- Без V.A.C. ничего не делает.
hg.CameraYielders = hg.CameraYielders or {} -- (списки из sh_00yield.lua - на случай другого порядка загрузки)
hg.NoFakeVehicles = hg.NoFakeVehicles or {}
hg.VehicleDamageBlockers = hg.VehicleDamageBlockers or {}
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

	hg.CameraYielders.vac = function(ply)
		return ply == LocalPlayer() and M.HasView()
	end
end

-- сиденье/часть техники V.A.C.
hg.NoFakeVehicles.vac = function(veh)
	local z = Z()
	return z and z.IsVAC and z.IsVAC(veh) or false
end
