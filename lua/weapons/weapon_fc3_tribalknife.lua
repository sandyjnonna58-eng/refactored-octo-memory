if SERVER then AddCSLuaFile() end
-- Тесак из Far Cry 3 (tribal knife). Всё как у weapon_fc3_machete (анимации мачете), своя модель и посадка в руке. Только для хоста.
SWEP.Base = "weapon_fc3_machete"
SWEP.PrintName = "FC3 Tribal Machete"
SWEP.Instructions = "A wide tribal machete. Host only.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.WorldModel = "models/weapons/rin/fc3/melee/tribalknifefc3.mdl"
SWEP.WorldModelExchange = "models/weapons/rin/fc3/melee/tribalknifefc3.mdl"

SWEP.weaponPos = Vector(5.42, -2.40, -7.30)
SWEP.weaponAng = Angle(-90, 0, 0)

-- шире и тяжелее обычного мачете: чуть медленнее, но сильнее
SWEP.AttackTime = 0.4
SWEP.DamagePrimary = 46
SWEP.StaminaPrimary = 27
SWEP.weight = 1.4

SWEP.IconOverride = "entities/weapon_fc3_tribalknife.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_fc3_tribalknife.png")
end
if SERVER then resource.AddSingleFile("materials/entities/weapon_fc3_tribalknife.png") end

SWEP.HostOnly = true
