ENT.Type            = "anim"
ENT.Base            = "base_gmodentity"
ENT.PrintName       = "ИИ Терминал"
ENT.Author          = "Gemini AI"
ENT.Purpose         = "Подойдите и нажмите E, чтобы поговорить с ИИ"
ENT.Instructions    = "Нажмите E"
ENT.Category        = "Gemini AI"
ENT.Spawnable       = true
ENT.AdminOnly       = false
ENT.IconOverride    = "entities/gemini_ai_terminal.png"
ENT.RenderGroup     = RENDERGROUP_BOTH

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "Thinking")
	self:NetworkVar("String", 0, "Speaker")
end
