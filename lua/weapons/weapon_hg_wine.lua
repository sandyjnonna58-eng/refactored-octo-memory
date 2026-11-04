if SERVER then AddCSLuaFile() end
-- Вино: как водка (weapon_hg_vodka), но слабее и глотков меньше; красное в тёмно-зелёной бутылке с бордовой фольгой.
-- Глоток ~0.22 промилле: бутылка целиком - крепко пьяный (~1.3), но не до отключки.
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Wine"
SWEP.Instructions = "A bottle of red wine. Softer than vodka, still gets you drunk.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle002a.mdl"
SWEP.IconOverride = "entities/weapon_hg_wine.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_wine.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_wine.png") end

SWEP.Sips = 6
SWEP.SipAlcohol = 0.22
SWEP.EmptyGivesBottle = false
SWEP.modeValuesdef = {[1] = 6}

SWEP.Bottle = {
	profile = {{0, 1.55}, {0.3, 1.65}, {9.5, 1.65}, {10.5, 1.35}, {11.8, 0.7}, {12.3, 0.6}, {15.2, 0.6}, {15.4, 0.66}},
	glass = Color(28, 62, 32, 215),
	liquid = Color(120, 10, 28, 225), liquidTop = 9.5, liquidR = 1.55,
	cap = {13.3, 15.6, 0.68, Color(125, 16, 32)},
	label = {3.0, 8.0, Color(238, 230, 210), -120, 120},
	stripe = {7.2, 7.6, Color(120, 20, 35)},
	ink = {Color(60, 30, 30), {4.2, 4.9, 5.6}},
	grip = 5,
}
