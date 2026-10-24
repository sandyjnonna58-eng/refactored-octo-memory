AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

resource.AddSingleFile("materials/entities/ent_calm_radio.png")

local tick_interval = 1
-- в секунду: паническая атака (0..1, активна с 0.45) и депрессия (0..1)
local panic_relief = 0.04
local depression_relief = 0.015
local notify_cooldown = 60

function ENT:Initialize()
	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end
end

function ENT:Use(activator)
	if not IsValid(activator) or not activator:IsPlayer() then return end

	self:SetOn(not self:GetOn())
	self:EmitSound("buttons/lightswitch2.wav", 60)
end

function ENT:Think()
	if self:GetOn() then
		local center = self:WorldSpaceCenter()

		for _, ply in player.Iterator() do
			local org = ply.organism
			if ply:Alive() and org and ply:WorldSpaceCenter():Distance(center) <= self.CalmRange then
				-- panicattack тянется к panicattackadd, поэтому гасим оба
				org.panicattackadd = math.max((org.panicattackadd or 0) - panic_relief * tick_interval, 0)
				org.panicattack = math.max((org.panicattack or 0) - panic_relief * tick_interval, 0)
				org.depression = math.max((org.depression or 0) - depression_relief * tick_interval, 0)

				local troubled = (org.panicattack or 0) > 0.1 or (org.depression or 0) > 0.1
				if troubled and (ply.calmRadioNotify or 0) < CurTime() then
					ply.calmRadioNotify = CurTime() + notify_cooldown
					ply:Notify("The music slowly calms you down.", 0, "calm_radio", 3, nil, Color(180, 220, 255))
				end
			end
		end
	end

	self:NextThink(CurTime() + tick_interval)
	return true
end
