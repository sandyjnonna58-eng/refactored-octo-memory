if SERVER then AddCSLuaFile() end
-- Героин в шприце (одна доза). Действие, передоз и ломка - organism/tier_1/modules/sv_drugs.lua.
SWEP.Base = "weapon_rem_drug_base"
SWEP.PrintName = "Heroin"
SWEP.Instructions = "A syringe of brown liquid. Makes every pain go away.\nTwo of these will stop your breathing.\nHighly addictive.\nLMB to inject, RMB to inject someone else."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/morphine_syrette/morphine.mdl"
SWEP.Color = Color(150, 105, 60)
SWEP.offsetVec = Vector(4, -1.5, 0)
SWEP.offsetAng = Angle(-30, 20, 180)
SWEP.HoldType = "normal"
SWEP.DrugKind = "heroin"
SWEP.Dose = 1
SWEP.Uses = 1
SWEP.AllowOthers = true
SWEP.UseSound = "snd_jack_hmcd_needleprick.wav"
SWEP.DeploySnd = ""
SWEP.FallSnd = "physics/plastic/plastic_box_impact_soft1.wav"
SWEP.Slot = 5
if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/icons/ico_fent.png")
	SWEP.IconOverride = "vgui/icons/ico_fent.png"
end
