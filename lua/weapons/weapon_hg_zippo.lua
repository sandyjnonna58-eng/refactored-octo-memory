if SERVER then AddCSLuaFile() end
-- Зажигалка: как спички (weapon_matches), но не кончается и поджигает там, куда смотришь, а не кидает спичку
SWEP.Base = "weapon_matches"

if CLIENT then
	SWEP.PrintName = "Zippo Lighter"
	SWEP.Slot = 3
	SWEP.SlotPos = 6
end

SWEP.Instructions = "A refillable metal lighter. It never runs out.\n\nHold LMB to flick it open and set fire to what you're looking at."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/weapons/w_zippolg.mdl"
SWEP.NoInfiniteAmmo = nil

SWEP.Primary.ClipSize = 1
SWEP.Primary.DefaultClip = 1

-- положение модели в руке (подбирается в игре)
SWEP.Offset = {
	Pos = Vector(1.5, 3, -1),
	Ang = Angle(0, 0, 90),
	Size = 1
}

local reach = 120
local flick_cooldown = 1.5

function SWEP:TakePrimaryAmmo()
end

function SWEP:PrimaryAttack()
	self:SetHolding(math.min(self:GetHolding() + 8, 100))
	if self:GetHolding() < 100 then return end

	self:SetNextPrimaryFire(CurTime() + flick_cooldown)
	self:EmitSound("f_firematch_strike.wav")

	local owner = self:GetOwner()
	local tr = hg.eyeTrace(owner, reach)
	if not tr then return end

	if IsValid(tr.Entity) and tr.Entity.OnMatches then
		tr.Entity:OnMatches()
		return
	end

	if not SERVER or not tr.Hit then return end

	-- горящая спичка падает в точку, куда смотришь, и поджигает бензин/бочки как обычная
	local ent = ents.Create("ent_zcity_match")
	if not IsValid(ent) then return end

	ent:SetPos(tr.HitPos + tr.HitNormal * 4)
	ent:SetAngles(AngleRand())
	ent:Spawn()
	ent.debil = owner
end
