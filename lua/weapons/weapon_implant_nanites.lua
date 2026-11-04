if SERVER then AddCSLuaFile() end
-- Имплант: Blood Nanites (organism/tier_1/modules/sv_implants.lua, id "nanites")
SWEP.Base = "weapon_implant_base"
SWEP.PrintName = "Blood Nanites"
SWEP.Instructions = "A colony of medical nanites in the blood: half the bleeding, wounds slowly close, blood slowly regenerates.\nLMB to install it into yourself, RMB into someone lying down. The surgery hurts."
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.ImplantId = "nanites"
SWEP.ImplantName = "nanite colony"
SWEP.IconOverride = "entities/weapon_implant_nanites.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_implant_nanites.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_implant_nanites.png") end
