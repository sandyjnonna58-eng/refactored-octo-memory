if SERVER then AddCSLuaFile() end
-- Champagne: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 6 глотков по ~0.2 промилле (вся бутылка ~1.2).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Champagne"
SWEP.Instructions = "Sparkling champagne. Light, but the bubbles hit fast.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle002a.mdl"
SWEP.IconOverride = "entities/weapon_hg_champagne.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_champagne.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_champagne.png") end

SWEP.Sips = 6
SWEP.SipAlcohol = 0.2
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 6}

SWEP.Bottle = {
	profile = {{0, 1.6}, {0.3, 1.72}, {8.4, 1.72}, {10.0, 1.3}, {11.6, 0.72}, {12.2, 0.66}, {15.0, 0.66}, {15.3, 0.76}},
	glass = Color(30, 70, 40, 215),
	liquid = Color(235, 215, 140, 200), liquidTop = 8.4, liquidR = 1.62,
	cap = {12.4, 15.6, 0.78, Color(210, 175, 70)},
	label = {2.8, 6.0, Color(240, 232, 205), -110, 110},
	stripe = {5.4, 5.8, Color(210, 175, 70)},
	ink = {Color(40, 40, 40), {3.6, 4.3}},
	grip = 5,
}
