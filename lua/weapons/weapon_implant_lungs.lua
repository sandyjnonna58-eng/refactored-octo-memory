if SERVER then AddCSLuaFile() end
-- Имплант: Synthetic Lungs (organism/tier_1/modules/sv_implants.lua, id "lungs")
SWEP.Base = "weapon_implant_base"
SWEP.PrintName = "Synthetic Lungs"
SWEP.Instructions = "Synthetic lungs that can't collapse (no pneumothorax), repair themselves, oxygenate faster and flush carbon monoxide.\nLMB to install it into yourself, RMB into someone lying down. The surgery hurts."
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.ImplantId = "lungs"
SWEP.ImplantName = "pair of synthetic lungs"
SWEP.IconOverride = "entities/weapon_implant_lungs.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_implant_lungs.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_implant_lungs.png") end
