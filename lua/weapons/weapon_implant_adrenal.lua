if SERVER then AddCSLuaFile() end
-- Имплант: Adrenal Implant (organism/tier_1/modules/sv_implants.lua, id "adrenal")
SWEP.Base = "weapon_implant_base"
SWEP.PrintName = "Adrenal Implant"
SWEP.Instructions = "An adrenal booster that injects adrenaline by itself when things get bad (low blood, heavy pain, low health). Once every 2.5 minutes.\nLMB to install it into yourself, RMB into someone lying down. The surgery hurts."
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.ImplantId = "adrenal"
SWEP.ImplantName = "adrenal implant"
SWEP.IconOverride = "entities/weapon_implant_adrenal.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_implant_adrenal.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_implant_adrenal.png") end
