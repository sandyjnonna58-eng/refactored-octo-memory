if SERVER then AddCSLuaFile() end
-- Основа имплантов (organism/tier_1/modules/sv_implants.lua): ЛКМ - вживить себе, ПКМ - тому, кто лежит.
-- Операция кустарная: больно и остаётся рана. Один имплант каждого вида на человека; после смерти его нет.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Implant"
SWEP.Category = "ZCity Implants"
SWEP.Spawnable = false
SWEP.AdminOnly = true
SWEP.WorldModel = "models/healthvial.mdl"
SWEP.ImplantId = nil
SWEP.ImplantName = "implant"
SWEP.DeploySnd = "items/ammo_pickup.wav"
SWEP.FallSnd = "physics/metal/weapon_impact_soft1.wav"

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = {[1] = 1}
end
SWEP.modeValuesdef = {[1] = 1}

function SWEP:Think() end
function SWEP:OwnerChanged() end

if SERVER then
	function SWEP:Heal(ent, mode)
		local owner = self:GetOwner()
		local org = ent.organism
		if not org or not self.ImplantId or not hg.organism.InstallImplant then return end
		if ent ~= owner and ent ~= hg.GetCurrentCharacter(owner) and not IsValid(org.owner.FakeRagdoll) then return end
		if (self.nextTry or 0) > CurTime() then return end
		self.nextTry = CurTime() + 1

		local patient = org.owner
		if org.implants and org.implants[self.ImplantId] then
			if owner.Notify then owner:Notify("They already have a " .. self.ImplantName .. ".", true, "implant", 0) end
			return
		end
		if not hg.organism.InstallImplant(patient, org, self.ImplantId) then return end

		-- операция: боль и разрез
		org.painadd = (org.painadd or 0) + 35
		if hg.organism.AddWoundManual then
			hg.organism.AddWoundManual(patient, 12, Vector(2, -3, 0), Angle(0, -90, 0), "ValveBiped.Bip01_Spine2", CurTime())
		end
		local snd = IsValid(patient.FakeRagdoll) and patient.FakeRagdoll or patient
		snd:EmitSound("items/medshot4.wav", 60, 90)
		snd:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav", 60)
		if patient.Notify then patient:Notify(self.ImplantName .. " installed.", true, "implant", 0) end

		owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
		self:Remove()
		return true
	end
end
