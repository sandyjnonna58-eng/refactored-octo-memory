if SERVER then AddCSLuaFile() end
-- Водка: ЛКМ - глоток, ПКМ - влить тому, кто лежит. Алкоголь - organism/tier_1/modules/sv_alcohol.lua
-- (сначала в желудок, потом за полминуты-минуту всасывается: пьянеешь не сразу).
-- Глоток водки ~0.35 промилле: 3 глотка - пьяный, 6-7 - рвёт, вся бутылка залпом - можно не проснуться.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Vodka"
SWEP.Instructions = "A bottle of cheap vodka. Numbs the pain and the fear, warms you up (not really - you lose heat faster).\nKicks in after a while. Too much and you'll throw up, pass out or worse.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle003a.mdl"
SWEP.IconOverride = "entities/weapon_hg_vodka.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_vodka.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_vodka.png") end
SWEP.offsetVec = Vector(3, -2.5, 1)
SWEP.offsetAng = Angle(-90, 0, 0)

SWEP.Sips = 8              -- глотков в бутылке
SWEP.SipAlcohol = 0.35     -- промилле за глоток
SWEP.SipSound = {"npc/barnacle/barnacle_gulp1.wav", "npc/barnacle/barnacle_gulp2.wav"}
SWEP.EmptyGivesBottle = false -- пустая бутылка: false - бросить, true - остаётся в руке как "розочка"-бутылка (weapon_hg_bottle)

SWEP.DeploySnd = "physics/glass/glass_bottle_impact_hard1.wav"
SWEP.FallSnd = "physics/glass/glass_bottle_impact_hard2.wav"

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = {[1] = self.Sips}
end
SWEP.modeValuesdef = {[1] = 8}

function SWEP:Think()
	if not self:GetOwner():KeyDown(IN_ATTACK) and GetConVar("hg_healanims") and GetConVar("hg_healanims"):GetBool() then
		self:SetHolding(math.max(self:GetHolding() - 4, 0))
	end
end

-- NPC бутылку не пьют
function SWEP:OwnerChanged() end

if SERVER then
	function SWEP:Heal(ent, mode)
		local org = ent.organism
		if not org then return end
		local owner = self:GetOwner()
		if ent ~= hg.GetCurrentCharacter(owner) and ent ~= owner and not IsValid(org.owner.FakeRagdoll) then return end
		if not self.modeValues or (self.modeValues[1] or 0) <= 0 then return end
		if (self.nextSip or 0) > CurTime() then return end

		local anims = GetConVar("hg_healanims")
		if ent == hg.GetCurrentCharacter(owner) and anims and anims:GetBool() then
			self:SetHolding(math.min(self:GetHolding() + 4, 100))
			if self:GetHolding() < 100 then return end
		end

		self.nextSip = CurTime() + 1.2
		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		local snd = self.SipSound[math.random(#self.SipSound)]
		entOwner:EmitSound(snd, 60, math.random(95, 108))

		org.alcoholStomach = (org.alcoholStomach or 0) + self.SipAlcohol

		self.modeValues[1] = self.modeValues[1] - 1
		if self.modeValues[1] <= 0 then
			local hands = hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh"
			if self.EmptyGivesBottle and not owner:HasWeapon("weapon_hg_bottle") then
				self:Remove()
				local b = owner:Give("weapon_hg_bottle")
				if IsValid(b) then owner:SelectWeapon("weapon_hg_bottle") else owner:SelectWeapon(hands) end
				return true
			end
			owner:SelectWeapon(hands)
			self:SpawnGarbage(self.WorldModel, nil, "physics/glass/glass_bottle_impact_hard3.wav")
			self:Remove()
		end
		return true
	end
end
