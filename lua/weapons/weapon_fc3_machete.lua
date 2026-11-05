if SERVER then AddCSLuaFile() end
-- Мачете из Far Cry 3 (модель из пакета контента сервера remorseism_custom_content, models/weapons/rin/fc3/melee).
-- Анимации, удары, звуки и урон - как у обычного мачете (weapon_hg_machete, v_me_machete), виден клинок FC3.
-- Взять может только хост сервера (на выделенном - суперадмин).
SWEP.Base = "weapon_hg_machete"
-- основа берётся явно: self.BaseClass у оружия-наследника указывает на это же
-- оружие, и вызов "базы" уходил сам в себя - бесконечная рекурсия, переполнение стека и вылет игры
local BaseClassRem = baseclass.Get("weapon_hg_machete")
SWEP.PrintName = "FC3 Machete"
SWEP.Instructions = "A heavy jungle machete with a saw-backed spine. Host only.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.WorldModel = "models/weapons/rin/fc3/melee/machetefc3.mdl"
SWEP.WorldModelExchange = "models/weapons/rin/fc3/melee/machetefc3.mdl"

-- кость 94 у v_me_machete - "Machete" (у v_me_hatchet это другая кость, "LeadPipe", поэтому по топорику клинок вставал наоборот):
-- родной мачете NMRiH лежит на ней рукоятью от x=-2.9 до ~3, остриё в +x, кромка в -y, плоскость клинка - xy.
-- Клинок FC3 (в модели остриё в +z, кромка в -y) поставлен так же: середина рукояти на середине родной рукояти, обух на обухе
SWEP.weaponPos = Vector(-3.60, -3.44, -3.67)
SWEP.weaponAng = Angle(90, 0, 0)

SWEP.IconOverride = "entities/weapon_fc3_machete.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_fc3_machete.png")
end
if SERVER then resource.AddSingleFile("materials/entities/weapon_fc3_machete.png") end

SWEP.HostOnly = true
-- у обычного мачете NoHolster: сборка (sv_util "homigrad-dropholstered") выбрасывает его, как только в руках другое;
-- мачете FC3 убираются на пояс и остаются в инвентаре
SWEP.NoHolster = false

-- тейкдауны Far Cry 4 (homigrad/takedowns): E со спины / через укрытие / снизу с уступа или лестницы, из воды, прыжок с высоты на цель
SWEP.Takedowns = true
-- камера Far Cry (homigrad/fccamera): X - поднять камеру, наводиться на игроков и NPC - отмечаются
SWEP.FCCamera = true
-- лечение как в Far Cry (homigrad/fcheal): с мачете в инвентаре F при ранениях лечит
SWEP.FCHeal = true
-- клинок в руке анимации FC4 (от ValveBiped.Anim_Attachment_RH): низ рукояти там, где у мачете FC4, остриё и лезвие туда же
SWEP.TakedownOffset = {Vector(3.81, -4.47, 2.93), Angle(0, 0, -90)}

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
		if BaseClassRem.Equip then BaseClassRem.Equip(self, owner) end
		if not IsHost(owner) then
			local class = self:GetClass()
			timer.Simple(0, function()
				if IsValid(owner) and owner:HasWeapon(class) then owner:StripWeapon(class) end
			end)
		end
	end
end

-- E + ПКМ - метнуть (homigrad/meleethrow)
SWEP.CanThrow = true
