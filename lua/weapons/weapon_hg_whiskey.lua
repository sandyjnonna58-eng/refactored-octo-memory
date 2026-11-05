if SERVER then AddCSLuaFile() end
-- Whiskey: как водка (weapon_hg_vodka) - глотки, алкоголь, своя модель бутылки (цветная, из кода).
-- 7 глотков по ~0.38 промилле (вся бутылка ~2.7).
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Whiskey"
SWEP.Instructions = "Smoky whiskey in a heavy bottle. Strong.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle003a.mdl"
SWEP.IconOverride = "entities/weapon_hg_whiskey.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_whiskey.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_whiskey.png") end

SWEP.Sips = 7
SWEP.SipAlcohol = 0.38
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 7}

SWEP.Bottle = {
	profile = {{0, 1.7}, {0.25, 1.85}, {7.6, 1.85}, {8.4, 1.7}, {9.4, 1.0}, {9.9, 0.68}, {12.6, 0.68}, {12.8, 0.74}},
	glass = Color(230, 228, 220, 80),
	liquid = Color(190, 105, 30, 200), liquidTop = 7.6, liquidR = 1.75,
	cap = {12.6, 13.6, 0.8, Color(25, 25, 25)},
	label = {2.4, 6.4, Color(20, 20, 22), -100, 100},
	stripe = {5.6, 6.0, Color(200, 160, 70)},
	ink = {Color(200, 160, 70), {3.4, 4.0, 4.6}},
	grip = 4.5,
}
