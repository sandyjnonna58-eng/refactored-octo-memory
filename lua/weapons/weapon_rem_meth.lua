if SERVER then AddCSLuaFile() end
-- Мет: пакетик на 3 дорожки. Действие, передоз и ломка - organism/tier_1/modules/sv_drugs.lua.
SWEP.Base = "weapon_rem_drug_base"
SWEP.PrintName = "Meth"
SWEP.Instructions = "A small bag of glassy crystals. You won't get tired. You won't stop.\nToo much will burst your heart.\nAddictive.\nLMB to snort a line (3 in the bag)."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/bloocobalt/l4d/items/w_eq_pills.mdl"
SWEP.Color = Color(190, 225, 255)
SWEP.ModelScale = 0.7
SWEP.DrugKind = "meth"
SWEP.Dose = 0.9
SWEP.Uses = 3
SWEP.UseDelay = 2.5
SWEP.UseSound = "player/breathe1.wav"
SWEP.DeploySnd = "physics/plastic/plastic_barrel_impact_soft1.wav"
SWEP.FallSnd = "physics/plastic/plastic_box_impact_soft1.wav"
if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/wep_jack_hmcd_painpills")
	SWEP.IconOverride = "vgui/wep_jack_hmcd_painpills.png"
end
