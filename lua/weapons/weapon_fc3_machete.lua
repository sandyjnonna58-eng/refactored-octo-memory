if SERVER then AddCSLuaFile() end
-- Мачете из Far Cry 3 (модель из пакета контента сервера remorseism_custom_content, models/weapons/rin/fc3/melee).
-- Анимации, удары, звуки и урон - как у обычного мачете (weapon_hg_machete, v_me_machete), виден клинок FC3.
-- Взять может только хост сервера (на выделенном - суперадмин).
SWEP.Base = "weapon_hg_machete"
SWEP.PrintName = "FC3 Machete"
SWEP.Instructions = "A heavy jungle machete with a saw-backed spine. Host only.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.WorldModel = "models/weapons/rin/fc3/melee/machetefc3.mdl"
SWEP.WorldModelExchange = "models/weapons/rin/fc3/melee/machetefc3.mdl"

-- кость 94 анимаций NMRiH: рукоять вдоль x (вверх - к -x), кромка в -y, плоскость клинка - z;
-- низ рукояти там же, где низ рукояти топорика (weapon_hatchet), остриё вверх, кромка вперёд
SWEP.weaponPos = Vector(5.40, -2.00, -1.20)
SWEP.weaponAng = Angle(-90, 0, 0)

SWEP.IconOverride = "entities/weapon_fc3_machete.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_fc3_machete.png")
end
if SERVER then resource.AddSingleFile("materials/entities/weapon_fc3_machete.png") end

SWEP.HostOnly = true

if SERVER then
	-- хост: создатель локального сервера; на выделенном сервере хоста нет - тогда суперадмин
	local function IsHost(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return false end
		if game.SinglePlayer() or ply:IsListenServerHost() then return true end
		return game.IsDedicated() and ply:IsSuperAdmin()
	end
	hg.IsServerHost = IsHost

	local function HostOnlyClass(class)
		local stored = weapons.GetStored(class)
		return stored and stored.HostOnly
	end

	hook.Add("PlayerCanPickupWeapon", "rem_fc3_hostonly", function(ply, wep)
		if HostOnlyClass(wep:GetClass()) and not IsHost(ply) then return false end
	end)
	hook.Add("PlayerGiveSWEP", "rem_fc3_hostonly", function(ply, class)
		if HostOnlyClass(class) and not IsHost(ply) then return false end
	end)
	hook.Add("PlayerSpawnSWEP", "rem_fc3_hostonly", function(ply, class)
		if HostOnlyClass(class) and not IsHost(ply) then return false end
	end)

	-- если всё же попало в руки не хосту (выдача, лут) - забираем
	function SWEP:Equip(owner)
		if self.BaseClass.Equip then self.BaseClass.Equip(self, owner) end
		if not IsHost(owner) then
			local class = self:GetClass()
			timer.Simple(0, function()
				if IsValid(owner) and owner:HasWeapon(class) then owner:StripWeapon(class) end
			end)
		end
	end
end
