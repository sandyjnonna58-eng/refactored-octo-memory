if SERVER then AddCSLuaFile() end
-- Пиво: как водка (weapon_hg_vodka), только слабое; пустая бутылка остаётся в руке - ею можно бить (weapon_hg_bottle)
SWEP.Base = "weapon_hg_vodka"
SWEP.PrintName = "Beer"
SWEP.Instructions = "A bottle of beer. Takes the edge off. The empty bottle stays in your hand.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/glassbottle01a.mdl"
SWEP.IconOverride = "entities/weapon_hg_beer.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_beer.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_beer.png") end

SWEP.Sips = 4
SWEP.SipAlcohol = 0.12
SWEP.EmptyGivesBottle = true
SWEP.modeValuesdef = {[1] = 4}

-- коричневая бутылка, золотая крышка, кремовая этикетка
SWEP.Bottle = {
	profile = {{0, 1.3}, {0.25, 1.42}, {7.2, 1.42}, {8.3, 1.1}, {9.6, 0.6}, {12.2, 0.55}, {12.4, 0.62}},
	glass = Color(105, 50, 14, 205),
	liquid = Color(210, 130, 35, 170), liquidTop = 7.2, liquidR = 1.32,
	cap = {12.3, 12.9, 0.64, Color(205, 175, 75)},
	label = {2.6, 6.2, Color(232, 206, 122), -100, 100},
	stripe = {5.5, 5.9, Color(170, 30, 25)},
	ink = {Color(110, 40, 20), {3.4, 4.0, 4.6}},
	grip = 4.5,
}
