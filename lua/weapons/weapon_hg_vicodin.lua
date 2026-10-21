if SERVER then AddCSLuaFile() end
-- Викодин: обезболивающее без передозировки (действует через org.vicodin, см. sv_pain.lua)
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Vicodin"
SWEP.Instructions = "Prescription painkillers. Dulls the pain for a few minutes, you can't overdose on them. 3 pills.\nLMB to take one, RMB to give one to someone else."
SWEP.Category = "ZCity Medicine"
SWEP.Spawnable = true
SWEP.IconOverride = "entities/weapon_hg_vicodin.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_hg_vicodin.png")
end

local pills = 3

-- жёлтые таблетки
local pill_color = Color(255, 215, 40)

if CLIENT then
	function SWEP:AfterDrawModel(model)
		self.pillModel = model
	end

	-- модель флакона общая с обычными таблетками, поэтому цвет красим только на время отрисовки
	function SWEP:DrawWorldModel2(nodraw)
		self.Color = pill_color
		self.BaseClass.DrawWorldModel2(self, nodraw)
		self.Color = nil

		if IsValid(self.pillModel) then self.pillModel:SetColor(color_white) end
	end
end

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)

	self.modeValues = {
		[1] = pills
	}
end

SWEP.modeValuesdef = {
	[1] = pills,
}

if SERVER then
	local hg_healanims = GetConVar("hg_healanims")

	function SWEP:Heal(ent, mode)
		local org = ent.organism
		if not org then return end
		if ent ~= self:GetOwner() and not IsValid(org.owner.FakeRagdoll) then return end
		if not self.modeValues or (self.modeValues[1] or 0) <= 0 then return end

		local owner = self:GetOwner()
		if ent == hg.GetCurrentCharacter(owner) and hg_healanims and hg_healanims:GetBool() then
			self:SetHolding(math.min(self:GetHolding() + 4, 100))
			if self:GetHolding() < 100 then return end
		end

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		entOwner:EmitSound("snd_jack_hmcd_pillsuse.wav", 60, math.random(95, 105))

		-- ещё одна таблетка только продлевает действие, сильнее не становится
		org.vicodin = 1

		self.modeValues[1] = self.modeValues[1] - 1
		if self.modeValues[1] <= 0 then
			owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
			self:SpawnGarbage(nil, nil, "snd_jack_hmcd_foodbounce.wav")
			self:Remove()
		end

		return true
	end
end
