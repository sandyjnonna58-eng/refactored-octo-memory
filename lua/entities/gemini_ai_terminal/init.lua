AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

function ENT:SpawnFunction(ply, tr, class)
	if not tr.Hit then return end

	local ent = ents.Create(class)
	ent:SetPos(tr.HitPos + tr.HitNormal * 2)
	ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
	ent:Spawn()
	ent:Activate()

	-- Ставим ровно на пол
	local mins = ent:OBBMins()
	ent:SetPos(tr.HitPos - Vector(0, 0, mins.z))

	return ent
end

function ENT:Initialize()
	self:SetModel("models/props_combine/combine_interface001.mdl")
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:EnableMotion(false) -- терминал стоит на месте (можно двигать физганом)
	end
end

function ENT:Use(activator)
	if not IsValid(activator) or not activator:IsPlayer() then return end

	GeminiAI.Terminals[activator:SteamID64()] = self
	self:SetSpeaker(activator:Nick())
	self:EmitSound("buttons/button24.wav", 65, 120)

	net.Start("GeminiAI_Open")
	net.Send(activator)
end

function ENT:OnRemove()
	for sid, term in pairs(GeminiAI.Terminals or {}) do
		if term == self then GeminiAI.Terminals[sid] = nil end
	end
end
