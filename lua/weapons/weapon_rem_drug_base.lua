if SERVER then AddCSLuaFile() end
-- Основа предметов-наркотиков (героин, мет, кислота): ЛКМ - принять дозу, ПКМ - другому (если AllowOthers).
-- Действие - organism/tier_1/modules/sv_drugs.lua (hg.Drugs.Dose). Доз в предмете - Uses (NW2 "used").
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Drug"
SWEP.Category = "ZCity Other"
SWEP.Spawnable = false
SWEP.HoldType = "slam"
SWEP.DrugKind = "heroin"
SWEP.Dose = 1
SWEP.Uses = 1
SWEP.UseDelay = 1.5
SWEP.UseSound = "snd_jack_hmcd_needleprick.wav"
SWEP.AllowOthers = false
SWEP.showstats = false

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
		if not IsValid(ent) or not IsValid(owner) then return end
		local self_use = ent == owner or ent == hg.GetCurrentCharacter(owner)
		if not self_use and not self.AllowOthers then return end
		local target = self_use and owner or (ent:IsRagdoll() and hg.RagdollOwner and hg.RagdollOwner(ent)) or ent
		if not IsValid(target) or not target.organism then return end
		if (self.nextUse or 0) > CurTime() then return end
		self.nextUse = CurTime() + self.UseDelay
		if not hg.Drugs or not hg.Drugs.Dose(target, self.DrugKind, self.Dose) then return end

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		entOwner:EmitSound(self.UseSound, 60, math.random(95, 105))

		local used = self:GetNW2Int("used", 0) + 1
		self:SetNW2Int("used", used)
		if used >= self.Uses then
			owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
			self:SpawnGarbage(nil, nil, self.FallSnd)
			self:Remove()
		end
		return true
	end
end
