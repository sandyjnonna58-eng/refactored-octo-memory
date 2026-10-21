if SERVER then AddCSLuaFile() end
-- Анимации, замах и урон - от ножа Buck 120 (weapon_buck200knife), своя только модель
SWEP.Base = "weapon_buck200knife"
SWEP.PrintName = "Backstabber"
SWEP.Instructions = "A long, thin knife made for one thing - going in from behind.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModelExchange = "models/weapons/w_sinabackstabber.mdl"
SWEP.modelscale = 1

-- положение модели в руке (подбирается в игре)
SWEP.weaponPos = Vector(-1, 0, 0)
SWEP.weaponAng = Angle(90, -90, 0)
