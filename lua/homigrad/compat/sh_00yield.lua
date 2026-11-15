-- Общие уступки Z-City чужим аддонам (грузится первым в compat/ - имя на 00). Компат-файлы регистрируют сюда свои
-- проверки, а код Z-City зовёт только эти функции - так один аддон не затирает уступку другого.
--   hg.CameraYield(ply)        - камера (cl_camera.lua: renderscene и CalcView) отдаётся движку/аддону;
--   hg.NoFakeInCar(veh)        - сиденье чужой техники со своей камерой/анимацией: Z-City не роняет в регдолл
--                                (sv_tier_0 "allowweapons"), не трогает мышь (cl_fake "fakeCameraAngles");
--   hg.InSpecialVehicle(ply)   - игрок сидит в такой технике (наши хуки cmd/мыши молчат: там это руль и прицел);
--   hg.VehicleDamageBlock(ent, dmg) - урон по сидящему гасит сама техника (бронированный экипаж RVB):
--                                sv_input "homigrad-damage" выходит с true раньше организма.
hg.CameraYielders = hg.CameraYielders or {}
hg.NoFakeVehicles = hg.NoFakeVehicles or {}
hg.VehicleDamageBlockers = hg.VehicleDamageBlockers or {}

function hg.CameraYield(ply)
	for _, f in pairs(hg.CameraYielders) do
		if f(ply) then return true end
	end
	return false
end

function hg.NoFakeInCar(veh)
	if not IsValid(veh) then return false end
	for _, f in pairs(hg.NoFakeVehicles) do
		if f(veh) then return true end
	end
	return false
end

function hg.InSpecialVehicle(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:InVehicle() and hg.NoFakeInCar(ply:GetVehicle()) or false
end

function hg.VehicleDamageBlock(ent, dmg)
	for _, f in pairs(hg.VehicleDamageBlockers) do
		if f(ent, dmg) then return true end
	end
	return false
end
