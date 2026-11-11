if SERVER then AddCSLuaFile() end
-- Кислота: листок с 5 марками. Трип - экран (organism/tier_1/modules/cl_drugs.lua), бэд-трип от передоза - паника.
SWEP.Base = "weapon_rem_drug_base"
SWEP.PrintName = "LSD"
SWEP.Instructions = "A sheet of small paper squares with a smiley print.\nThe world will never look the same.\nThree at once is a very bad idea.\nLMB to put one on your tongue (5 on the sheet)."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_c17/paper01.mdl"
SWEP.Color = Color(255, 220, 120)
SWEP.ModelScale = 0.18
SWEP.DrugKind = "lsd"
SWEP.Dose = 0.8
SWEP.Uses = 5
SWEP.UseDelay = 2
SWEP.UseSound = "physics/cardboard/cardboard_box_impact_soft1.wav"
SWEP.DeploySnd = "physics/cardboard/cardboard_box_impact_soft2.wav"
SWEP.FallSnd = "physics/cardboard/cardboard_box_impact_soft3.wav"
if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/wep_jack_hmcd_painpills")
	SWEP.IconOverride = "vgui/wep_jack_hmcd_painpills.png"
end
