if SERVER then AddCSLuaFile() end
-- Анимации, замах и урон - от мачете (weapon_hg_machete), своя только модель
SWEP.Base = "weapon_hg_machete"
SWEP.PrintName = "Field Machete"
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/weapons/melee/w_ws_pamachete.mdl"
SWEP.WorldModelExchange = "models/weapons/melee/w_ws_pamachete.mdl"

-- положение модели в руке (подбирается в игре)
SWEP.weaponPos = Vector(0, 0, 0)
SWEP.weaponAng = Angle(0, -90, 0)
