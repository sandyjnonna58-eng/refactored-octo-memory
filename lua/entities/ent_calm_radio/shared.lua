ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Calming Radio"
ENT.Instructions = "E - turn on / off. While it plays, people nearby calm down: panic attacks fade, depression goes away."
ENT.Category = "ZCity Other"
ENT.Spawnable = true
ENT.Model = "models/props_lab/citizenradio.mdl"
ENT.IconOverride = "entities/ent_calm_radio.png"

-- в этом радиусе музыка успокаивает
ENT.CalmRange = 450

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "On")
end
