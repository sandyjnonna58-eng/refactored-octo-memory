-- Камера Far Cry для мачете (идея из аддона "FAR CRY Camera / NPC Tagging", сделано своё, без его модели):
-- с оружием, у которого SWEP.FCCamera = true (мачете FC3), X - поднять/опустить камеру; когда достаёшь мачете,
-- в инвентарь даётся и сама камера (weapon_fc3_camera) - с ней в руках видоискатель поднят всегда, X - обратно к мачете.
-- В камере: ПКМ - зум (3 ступени), навести на игрока или NPC - через полсекунды он отмечен, ЛКМ - отметить/снять сразу.
-- Отмеченные видны сквозь стены (силуэт) с меткой и расстоянием, пока живы. Отметки свои у каждого.
-- Пока камера поднята, мачете не бьёт и не блокирует, бегать нельзя.
hg = hg or {}
hg.FCCamera = hg.FCCamera or {}
local CAM = hg.FCCamera

function CAM.Allowed(ply)
	if not IsValid(ply) or not ply:Alive() or IsValid(ply.FakeRagdoll) then return false end
	if hg.Takedown and hg.Takedown.ByEnt and hg.Takedown.ByEnt[ply] then return false end
	local wep = ply:GetActiveWeapon()
	return IsValid(wep) and wep.FCCamera == true
end

function CAM.IsUp(ply)
	return IsValid(ply) and ply:GetNW2Bool("rem_fccam", false)
end

hook.Add("StartCommand", "rem_fccam_lock", function(ply, cmd)
	if not CAM.IsUp(ply) and not (CLIENT and ply == LocalPlayer() and CAM.LocalUp) then return end
	cmd:RemoveKey(IN_ATTACK)
	cmd:RemoveKey(IN_ATTACK2)
	cmd:RemoveKey(IN_SPEED)
end)

if SERVER then
	util.AddNetworkString("rem_fccam")

	net.Receive("rem_fccam", function(_, ply)
		local up = net.ReadBool()
		if up and not CAM.Allowed(ply) then up = false end
		ply:SetNW2Bool("rem_fccam", up)
	end)

	-- достал мачете FC3 - в инвентарь даётся камера-предмет (weapon_fc3_camera), если её ещё нет
	CAM.CameraClass = "weapon_fc3_camera"
	local function GiveCamera(ply, wep)
		if not IsValid(ply) or not ply:IsPlayer() or not IsValid(wep) then return end
		if not wep.FCCamera or wep.FCCameraAlways then return end
		timer.Simple(0, function()
			if not IsValid(ply) or not ply:Alive() or ply:HasWeapon(CAM.CameraClass) then return end
			local before = ply:GetActiveWeapon()
			local cam = ply:Give(CAM.CameraClass, true)
			if not IsValid(cam) then return end
			-- сборка (sh_utility "pickupHuy") через пару тиков сама берёт в руки любой новый предмет - камере это запрещаем,
			-- она просто лежит в инвентаре, в руках остаётся мачете
			cam.DontEquipInstantly = true
			if IsValid(before) and before ~= cam and ply:GetActiveWeapon() ~= before then
				ply:SelectWeapon(before:GetClass())
			end
		end)
	end
	hook.Add("PlayerSwitchWeapon", "rem_fccam_give", function(ply, old, new) GiveCamera(ply, new) end)
	hook.Add("WeaponEquip", "rem_fccam_give", function(wep, ply) GiveCamera(ply, wep) end)

	-- сменил оружие, упал, умер, начал тейкдаун - камера опускается;
	-- выбросил все мачете FC3 - камера-предмет тоже убирается
	local function HasMachete(ply)
		for _, w in ipairs(ply:GetWeapons()) do
			if w.FCCamera and not w.FCCameraAlways then return true end
		end
		return false
	end
	local nextCheck = 0
	hook.Add("Think", "rem_fccam_check", function()
		if CurTime() < nextCheck then return end
		nextCheck = CurTime() + 0.2
		for _, ply in ipairs(player.GetAll()) do
			if ply:Alive() and ply:HasWeapon(CAM.CameraClass) and not HasMachete(ply) then
				ply:StripWeapon(CAM.CameraClass)
			end
			if ply:GetNW2Bool("rem_fccam", false) and not CAM.Allowed(ply) then
				ply:SetNW2Bool("rem_fccam", false)
			end
		end
	end)
end
