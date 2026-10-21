if SERVER then AddCSLuaFile() end
-- Анимации, замах и урон - от кувалды (weapon_hg_sledgehammer), своя только модель
SWEP.Base = "weapon_hg_sledgehammer"
SWEP.PrintName = "Rusty Sledgehammer"
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/weapons/sledgehammer.mdl"
SWEP.WorldModelExchange = "models/weapons/sledgehammer.mdl"

-- положение модели в руке (подбирается в игре)
SWEP.weaponPos = Vector(0, 0, 0)
SWEP.weaponAng = Angle(0, -90, 0)
