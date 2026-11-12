AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

function ENT:SpawnFunction(ply, tr)
	if not IsValid(ply) or not GeminiAI.HasAccess(ply, "Characters") then return end
	net.Start("GeminiAI_CharMenu")
		net.WriteBool(true)
		net.WriteVector(tr.HitPos + tr.HitNormal * 4)
	net.Send(ply)
	-- энтити не создаём: персонаж появится после выбора роли в окне
end

function ENT:Initialize() self:Remove() end
