if SERVER then AddCSLuaFile() end
-- Absinthe: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 6 глотков по ~0.55 промилле (вся бутылка ~3.3).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Absinthe"
SWEP.Instructions = "Green absinthe. Brutally strong - a few swigs and the world starts to spin.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle003a.mdl"
SWEP.IconOverride = "entities/weapon_hg_absinthe.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_absinthe.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_absinthe.png") end

SWEP.Sips = 6
SWEP.SipAlcohol = 0.55
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 6}

SWEP.Bottle = {
	profile = {{0, 1.6}, {0.3, 1.72}, {8.8, 1.72}, {9.8, 1.4}, {10.8, 0.75}, {11.2, 0.66}, {13.4, 0.66}, {13.6, 0.72}},
	glass = Color(220, 235, 220, 80),
	liquid = Color(90, 200, 70, 190), liquidTop = 8.8, liquidR = 1.62,
	cap = {13.4, 14.4, 0.78, Color(20, 60, 25)},
	label = {2.8, 6.8, Color(240, 238, 220), -100, 100},
	stripe = {6.0, 6.5, Color(30, 110, 40)},
	ink = {Color(30, 80, 35), {3.6, 4.3, 5.0}},
	grip = 5,
}
