-- Совместимость с отдельным аддоном «Realistic Vehicles Base (RVB)» (машины, БТР, танки; в репозиторий не кладём -
-- 247 МБ моделей; ставится из Мастерской). Своего модуля под Z-City у RVB нет. Сиденья - prop_vehicle_prisoner_pod,
-- родитель - машина (RVB.IsRVB, seat.RVBParent); камера - хук CalcVehicleView "RVB_Camera" (вид от первого/третьего
-- лица, прицел наводчика), посадка/анимации/скрытие экипажа - свои. Что Z-City ломал и что здесь:
--   регдолл в машине   через 1 с после посадки Z-City роняет в регдолл, приваренный к машине - в RVB не роняем
--                      (hg.NoFakeInCar), оружие в сиденье решает RVB (rvb_seat_weapons, Seats[i].weapons);
--   камера             камера Z-City рисует кадр сама и CalcVehicleView RVB не доходит - в его сиденье уступаем
--                      (hg.CameraYield), мышь тоже (cl_fake "fakeCameraAngles" молчит);
--   смена места        Z-City не пускает в сиденье машины быстрее ~5 м/с, если не ply.switchingseat - у RVB флаг свой
--                      (ply.RVB_Switching), учтён в sv_tier_0 "fake_enterveh";
--   броня экипажа      RVB гасит весь урон по сидящим в бронетехнике (rvb_armored_crew_protect) своим EntityTakeDamage,
--                      но организм Z-City считает урон в своём - мог успеть первым; повторяем ту же проверку
--                      (hg.VehicleDamageBlock) до организма.
--   стационарное оружие   «[RVB] Realistic Animated Emplacement Weapons» (rvb_emp_*, та же база rvb_base - всё выше
--                      работает и для него; камера наводчика - его CalcView "REmp_GunnerView"). Стрелок сидит
--                      невидимым в сиденье, пули по нарисованному телу аддон сам переносит на игрока (ply.REmpOwnHit) с
--                      точкой попадания на нарисованном теле - организм Z-City ищет органы по этой точке и мог
--                      промахнуться: переносим её на голову/грудь настоящего тела (hg.VehicleDamageAdjust).
-- Без RVB ничего не делает.
hg.CameraYielders = hg.CameraYielders or {} -- (списки из sh_00yield.lua - на случай другого порядка загрузки)
hg.NoFakeVehicles = hg.NoFakeVehicles or {}
hg.VehicleDamageBlockers = hg.VehicleDamageBlockers or {}
hg.VehicleDamageAdjusters = hg.VehicleDamageAdjusters or {}
hg.RVB = hg.RVB or {}
local M = hg.RVB

local function Present() return RVB ~= nil and RVB.IsRVB ~= nil end
M.Present = Present

-- сиденье RVB (или сама машина)
function M.IsSeat(veh)
	if not Present() or not IsValid(veh) then return false end
	if RVB.IsRVB(veh) then return true end
	if IsValid(veh.RVBParent) then return true end
	local p = veh:GetParent()
	return IsValid(p) and RVB.IsRVB(p) or false
end

function M.Seated(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:InVehicle() and M.IsSeat(ply:GetVehicle()) or false
end

hg.NoFakeVehicles.rvb = M.IsSeat

if CLIENT then
	hg.CameraYielders.rvb = function(ply)
		return ply == LocalPlayer() and M.Seated(ply)
	end
end

if SERVER then
	-- то же условие, что у RVB "RVB_ArmoredCrew": бронетехника (не IsLightVehicle), квар включён, машина не взорвалась
	hg.VehicleDamageBlockers.rvb = function(ent, dmg)
		if not Present() or not IsValid(ent) or not ent:IsPlayer() or not ent:InVehicle() then return false end
		if not (RVB.CV and RVB.CV.armoredCrew and RVB.CV.armoredCrew:GetBool()) then return false end
		local seat = ent:GetVehicle()
		local veh = IsValid(seat) and (seat.RVBParent or seat:GetParent())
		if not IsValid(veh) or not RVB.IsRVB(veh) then return false end
		if not veh.IsLightVehicle or veh:IsLightVehicle() then return false end
		if veh.RVBCrewKill then return false end
		return true
	end

	-- попадание по нарисованному стрелку стационарного оружия -> точка на настоящем теле в сиденье
	hg.VehicleDamageAdjusters.rvb_emp = function(ent, dmg)
		if not Present() or not IsValid(ent) or not ent:IsPlayer() or not ent.REmpOwnHit then return end
		local veh = RVB.GetPlayerVehicle and RVB.GetPlayerVehicle(ent)
		if not (veh and veh.IsEmplacement) then return end
		local pos = dmg:GetDamagePosition()
		-- голова - если попали в последнюю точку тела (REmp GunnerPoints: от таза до глаз)
		local head = false
		local pts = veh.GunnerPoints and veh:GunnerPoints()
		if pts and #pts > 0 then
			local best, bestK = math.huge, 1
			for k, q in ipairs(pts) do
				local d = q:DistToSqr(pos)
				if d < best then best, bestK = d, k end
			end
			head = bestK == #pts
		end
		local bone = ent:LookupBone(head and "ValveBiped.Bip01_Head1" or "ValveBiped.Bip01_Spine2")
		local bp = bone and ent:GetBonePosition(bone)
		if not bp then return end
		local dir = dmg:GetDamageForce():GetNormalized()
		if dir:IsZero() then dir = (bp - pos):GetNormalized() end
		-- чуть снаружи тела по ходу пули: Z-City трассирует от точки вдоль направления удара
		dmg:SetDamagePosition(bp - dir * 8)
	end
end
