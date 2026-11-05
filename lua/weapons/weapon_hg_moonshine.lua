if SERVER then AddCSLuaFile() end
-- Moonshine: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 8 глотков по ~0.45 промилле (вся бутылка ~3.6).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Moonshine"
SWEP.Instructions = "Homemade moonshine in a plain bottle. Very strong and rough - easy to overdo it.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/glassjug01.mdl"
SWEP.IconOverride = "entities/weapon_hg_moonshine.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_moonshine.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_moonshine.png") end

SWEP.Sips = 8
SWEP.SipAlcohol = 0.45
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 8}

SWEP.Bottle = {
	profile = {{0, 1.95}, {0.3, 2.1}, {7.4, 2.1}, {8.6, 1.7}, {9.8, 0.85}, {10.2, 0.75}, {12.2, 0.75}, {12.4, 0.8}},
	glass = Color(225, 235, 230, 75),
	liquid = Color(235, 240, 225, 70), liquidTop = 7.4, liquidR = 2.0,
	cap = {12.0, 12.9, 0.86, Color(150, 120, 80)},
	label = {3.0, 5.4, Color(214, 196, 150), -60, 60},
	ink = {Color(60, 50, 40), {3.8, 4.5}},
	grip = 4.5,
}
