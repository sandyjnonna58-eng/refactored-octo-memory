ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Life Support Machine"
ENT.Category = "ZCity Other"
ENT.Spawnable = true
ENT.Model = "models/props_lab/reciever_cart.mdl"
ENT.IconOverride = "entities/ent_life_support.png"
ENT.RenderGroup = RENDERGROUP_BOTH

-- пациента можно подключить в этом радиусе, а дальше длины трубки он отключается сам
ENT.ConnectRange = 100
ENT.TubeLength = 170

function ENT:SetupDataTables()
	self:NetworkVar("Entity", 0, "Patient")
end
