if SERVER then AddCSLuaFile() end
-- Имплант: Pain Blocker (organism/tier_1/modules/sv_implants.lua, id "painblock")
SWEP.Base = "weapon_implant_base"
SWEP.PrintName = "Pain Blocker"
SWEP.Instructions = "A neural pain blocker: you feel half the pain.\nLMB to install it into yourself, RMB into someone lying down. The surgery hurts."
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.ImplantId = "painblock"
SWEP.ImplantName = "pain blocker"
SWEP.IconOverride = "entities/weapon_implant_painblock.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_implant_painblock.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_implant_painblock.png") end
