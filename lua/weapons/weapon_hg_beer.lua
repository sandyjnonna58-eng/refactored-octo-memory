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
