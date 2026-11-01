if SERVER then AddCSLuaFile() end
-- Мачете из Far Cry 3 (модель из пакета контента сервера remorseism_custom_content, models/weapons/rin/fc3/melee).
-- Анимации и удары - как у катаны (c_kf2_katana, кость 46); клинок поставлен так, что верх рукояти на месте гарды
-- катаны, остриё и кромка смотрят туда же. Взять может только хост сервера (на выделенном - суперадмин).
SWEP.Base = "weapon_hg_katana"
SWEP.PrintName = "FC3 Machete"
SWEP.Instructions = "A heavy jungle machete. Host only.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.WorldModel = "models/weapons/rin/fc3/melee/machetefc3.mdl"
SWEP.WorldModelExchange = "models/weapons/rin/fc3/melee/machetefc3.mdl"

SWEP.weaponPos = Vector(1.33, 4.53, -4.00)
SWEP.weaponAng = Angle(0, 110, 0)

-- как мачете: короче и легче катаны, быстрее замах, сильнее кровотечение
SWEP.AttackTime = 0.4
SWEP.AnimTime1 = 1.2
SWEP.WaitTime1 = 1.1
SWEP.DamagePrimary = 42
SWEP.BleedMultiplier = 2
SWEP.PainMultiplier = 1.3
SWEP.PenetrationPrimary = 6
SWEP.StaminaPrimary = 24
SWEP.AttackLen1 = 52
SWEP.weight = 1.3
SWEP.AttackHitFlesh = "machete/machetehit1.ogg"

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
