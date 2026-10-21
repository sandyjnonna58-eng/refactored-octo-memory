AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local beep_interval = 1

function ENT:Initialize()
	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end
end

local function PatientPos(ply)
	local char = hg.GetCurrentCharacter(ply)
	return IsValid(char) and char:WorldSpaceCenter() or ply:WorldSpaceCenter()
end

-- ближайший живой человек рядом (лежащие в приоритете); если никого - сам нажавший
function ENT:FindPatient(activator)
	local best, bestScore
	local center = self:WorldSpaceCenter()

	for _, ply in player.Iterator() do
		if ply:Alive() and ply ~= activator and not IsValid(ply.LifeSupportMachine) then
			local dist = PatientPos(ply):Distance(center)
			if dist <= self.ConnectRange then
				local score = dist - (IsValid(ply.FakeRagdoll) and 1000 or 0)
				if not bestScore or score < bestScore then best, bestScore = ply, score end
			end
		end
	end

	if not best and not IsValid(activator.LifeSupportMachine) and PatientPos(activator):Distance(center) <= self.ConnectRange then
		best = activator
	end

	return best
end

function ENT:Connect(ply)
	hg.LifeSupport.Connect(self, ply)
end

function ENT:Disconnect()
	hg.LifeSupport.Disconnect(self)
end

function ENT:Use(activator)
	if not IsValid(activator) or not activator:IsPlayer() then return end

	if IsValid(self:GetPatient()) then
		self:Disconnect()
		return
	end

	local ply = self:FindPatient(activator)
	if ply then self:Connect(ply) else activator:Notify("Nobody to connect.", 0, "lifesupport_none", 2) end
end

function ENT:Think()
	local ply = self:GetPatient()

	if IsValid(ply) then
		if not ply:Alive() or ply.LifeSupportMachine ~= self or PatientPos(ply):Distance(self:WorldSpaceCenter()) > self.TubeLength then
			self:Disconnect()
		elseif (self.nextBeep or 0) < CurTime() then
			self.nextBeep = CurTime() + beep_interval
			self:EmitSound("buttons/blip1.wav", 55, 120)
		end
	end

	self:NextThink(CurTime() + 0.2)
	return true
end

function ENT:OnRemove()
	self:Disconnect()
end
