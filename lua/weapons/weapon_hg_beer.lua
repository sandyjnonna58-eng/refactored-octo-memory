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
	-- по фото (tools/drink_textures/make.py), картинка - личный пак materials/rem_drinks_private
	photo = {
		tex = "rem_drinks_private/beer.png", H = 12.9, R = 1.75,
		profile = {{0, 0.74}, {0.33, 1.62}, {0.64, 1.68}, {0.97, 1.68}, {1.29, 1.66}, {1.61, 1.65}, {1.93, 1.64}, {2.26, 1.64}, {2.58, 1.65}, {2.9, 1.64}, {3.22, 1.64}, {3.55, 1.65}, {3.87, 1.65}, {4.19, 1.65}, {4.52, 1.65}, {4.84, 1.65}, {5.16, 1.66}, {5.48, 1.66}, {5.81, 1.68}, {6.12, 1.69}, {6.45, 1.68}, {6.78, 1.58}, {7.09, 1.42}, {7.42, 1.26}, {7.74, 1.11}, {8.06, 1.02}, {8.38, 1}, {8.71, 0.99}, {9.03, 0.99}, {9.35, 0.96}, {9.68, 0.94}, {10, 0.9}, {10.32, 0.86}, {10.64, 0.83}, {10.97, 0.8}, {11.29, 0.76}, {11.61, 0.72}, {11.93, 0.8}, {12.26, 0.69}, {12.57, 0.8}, {12.9, 0.53}},
	},
}
