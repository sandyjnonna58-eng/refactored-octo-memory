if SERVER then AddCSLuaFile() end
-- Cognac: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 7 глотков по ~0.36 промилле (вся бутылка ~2.5).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Cognac"
SWEP.Instructions = "Aged cognac. Warm, smooth and strong.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle003a.mdl"
SWEP.IconOverride = "entities/weapon_hg_cognac.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_cognac.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_cognac.png") end

SWEP.Sips = 7
SWEP.SipAlcohol = 0.36
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 7}

SWEP.Bottle = {
	profile = {{0, 1.9}, {0.3, 2.05}, {5.2, 2.05}, {6.4, 1.85}, {7.6, 1.2}, {8.6, 0.7}, {12.0, 0.66}, {12.2, 0.72}},
	glass = Color(230, 225, 215, 80),
	liquid = Color(150, 70, 20, 215), liquidTop = 5.2, liquidR = 1.95,
	cap = {11.6, 12.8, 0.76, Color(200, 160, 60)},
	label = {1.8, 4.8, Color(232, 214, 160), -100, 100},
	stripe = {4.2, 4.6, Color(120, 30, 25)},
	ink = {Color(90, 40, 20), {2.6, 3.2}},
	grip = 4,
}
