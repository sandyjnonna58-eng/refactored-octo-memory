if SERVER then AddCSLuaFile() end
-- Тесак из Far Cry 3 (tribal knife). Всё как у weapon_fc3_machete, своя модель и посадка в руке. Только для хоста.
SWEP.Base = "weapon_fc3_machete"
SWEP.PrintName = "FC3 Tribal Machete"
SWEP.Instructions = "A wide tribal machete. Host only.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.WorldModel = "models/weapons/rin/fc3/melee/tribalknifefc3.mdl"
SWEP.WorldModelExchange = "models/weapons/rin/fc3/melee/tribalknifefc3.mdl"

SWEP.weaponPos = Vector(3.79, -1.07, -5.00)
SWEP.weaponAng = Angle(0, 110, 0)

-- шире и тяжелее: чуть медленнее, но сильнее
SWEP.AttackTime = 0.45
SWEP.AnimTime1 = 1.3
SWEP.WaitTime1 = 1.2
SWEP.DamagePrimary = 46
SWEP.StaminaPrimary = 27
SWEP.weight = 1.5

SWEP.IconOverride = "entities/weapon_fc3_tribalknife.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_fc3_tribalknife.png")
end
if SERVER then resource.AddSingleFile("materials/entities/weapon_fc3_tribalknife.png") end

SWEP.HostOnly = true
