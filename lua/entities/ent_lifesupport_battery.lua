AddCSLuaFile()
-- Батарейка для переносного аппарата жизнеобеспечения: E - зарядить его до 100%
ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Life Support Battery"
ENT.Category = "ZCity Medicine"
ENT.Spawnable = true
ENT.Model = "models/items/battery.mdl"
ENT.IconOverride = "entities/ent_lifesupport_battery.png"

function ENT:Initialize()
	if CLIENT then return end

	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)
	self:SetCollisionGroup(COLLISION_GROUP_WEAPON)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end
end

function ENT:Use(activator)
	if not IsValid(activator) or not activator:IsPlayer() then return end

	local device = activator:GetWeapon("weapon_hg_lifesupport_portable")
	if not IsValid(device) then
		activator:Notify("You have nothing to charge with this.", 0, "lifesupport_battery_use", 2)
		return
	end

	if device:Clip1() >= device:GetMaxClip1() then
		activator:Notify("The life support is already fully charged.", 0, "lifesupport_battery_use", 2)
		return
	end

	device:SetClip1(device:GetMaxClip1())
	activator:EmitSound("items/battery_pickup.wav", 60)
	self:Remove()
end
