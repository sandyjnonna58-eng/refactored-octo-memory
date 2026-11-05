if SERVER then AddCSLuaFile() end
-- Rum: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 7 глотков по ~0.38 промилле (вся бутылка ~2.7).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Rum"
SWEP.Instructions = "Dark pirate rum. Strong and sweet.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle001a.mdl"
SWEP.IconOverride = "entities/weapon_hg_rum.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_rum.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_rum.png") end

SWEP.Sips = 7
SWEP.SipAlcohol = 0.38
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 7}

SWEP.Bottle = {
	profile = {{0, 1.65}, {0.3, 1.78}, {8.2, 1.78}, {9.2, 1.5}, {10.2, 0.8}, {10.6, 0.68}, {12.8, 0.68}, {13.0, 0.75}},
	glass = Color(70, 40, 20, 210),
	liquid = Color(110, 50, 15, 220), liquidTop = 8.2, liquidR = 1.66,
	cap = {12.8, 13.8, 0.8, Color(30, 20, 15)},
	label = {2.6, 6.8, Color(236, 226, 196), -100, 100},
	stripe = {6.0, 6.5, Color(170, 30, 25)},
	ink = {Color(40, 30, 25), {3.6, 4.3, 5.0}},
	grip = 5,
}
