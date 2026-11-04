if SERVER then AddCSLuaFile() end
-- Имплант: Artificial Heart (organism/tier_1/modules/sv_implants.lua, id "heart")
SWEP.Base = "weapon_implant_base"
SWEP.PrintName = "Artificial Heart"
SWEP.Instructions = "A synthetic heart pump. Never skips a beat: no arrhythmia, no fibrillation, no cardiac arrest from cold or blood loss - only breaks if the heart itself is destroyed.\nLMB to install it into yourself, RMB into someone lying down. The surgery hurts."
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.ImplantId = "heart"
SWEP.ImplantName = "artificial heart"
SWEP.IconOverride = "entities/weapon_implant_heart.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_implant_heart.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_implant_heart.png") end
