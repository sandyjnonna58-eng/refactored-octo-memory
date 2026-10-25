if SERVER then
	AddCSLuaFile()
	resource.AddFile("models/hatedmekkr/boneworks/weapons/melee/blunts/misc/bw_wpn_bnt_noodledog.mdl")
	resource.AddFile("materials/hatedmekkr/boneworks/weapons/melee/blunts/misc/noodledog/bw_wpn_bnt_noodledog.vmt")
	resource.AddSingleFile("materials/hatedmekkr/boneworks/weapons/melee/blunts/misc/noodledog/bw_wpn_bnt_noodledog_nrm.vtf")
end

-- Noodle Dog: fun toy from Boneworks. Bat animations, no sounds at all,
-- barely hurts but every hit knocks the victim into ragdoll and launches it.
SWEP.Base = "weapon_melee"
SWEP.PrintName = "Noodle Dog"
SWEP.Instructions = "A plastic noodle dog. Hurts nobody, but sends everyone flying.\n\nLMB to attack.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.HoldType = "slam"

local MODEL = "models/hatedmekkr/boneworks/weapons/melee/blunts/misc/bw_wpn_bnt_noodledog.mdl"
local SILENT = "common/null.wav"

SWEP.WorldModel = MODEL
SWEP.WorldModelReal = "models/weapons/tfa_nmrih/v_me_bat_metal.mdl"
SWEP.WorldModelExchange = MODEL
SWEP.DontChangeDropped = false
SWEP.ViewModel = ""
SWEP.modelscale = 0.8

SWEP.Weight = 0
SWEP.weight = 1

SWEP.DamageType = DMG_CLUB
SWEP.DamagePrimary = 4
SWEP.DamageSecondary = 2

SWEP.PenetrationPrimary = 1
SWEP.PenetrationSecondary = 1
SWEP.MaxPenLen = 1
SWEP.PenetrationSizePrimary = 1
SWEP.PenetrationSizeSecondary = 1

SWEP.StaminaPrimary = 12
SWEP.StaminaSecondary = 6

SWEP.HoldPos = Vector(-8,0,0)
SWEP.HoldAng = Angle(0,0,-10)

SWEP.AttackTime = 0.33
SWEP.AnimTime1 = 1.45
SWEP.WaitTime1 = 0.9
SWEP.AttackLen1 = 65
SWEP.ViewPunch1 = Angle(2,4,0)
SWEP.HitCooldownEnabled = true
SWEP.HitCooldown = 1

SWEP.canchargeattack = true
SWEP.ChargeAnimTimeBegin = 1
SWEP.ChargeAnimTimeIdle = 1
SWEP.ChargeAnimTimeEnd = 1.35
SWEP.ChargeFullTime = 0.65
SWEP.ChargeAttackTime = 0.36
SWEP.ChargeWaitTime = 1.95
SWEP.ChargeAttackLen = 80
SWEP.ChargeAttackTimeLength = 0.26
SWEP.ChargeAttackRads = 85
SWEP.ChargeSwingAng = -94
SWEP.ChargeStamina = 30
SWEP.ChargePenetration = 1
SWEP.ChargePenetrationSize = 1
SWEP.ChargeDamageMul = 1.5
SWEP.ChargeBreakBoneMul = 0
SWEP.ChargeTapCancelTime = 1
SWEP.ChargeViewPunch = Angle(7, 0, 0)
SWEP.ChargeHoldPos = Vector(-8, 0, 0)

SWEP.Attack2Time = 0.3
SWEP.AnimTime2 = 1
SWEP.WaitTime2 = 0.8
SWEP.AttackLen2 = 45
SWEP.ViewPunch2 = Angle(0,0,-2)

SWEP.attack_ang = Angle(0,0,0)
SWEP.sprint_ang = Angle(15,0,0)

-- same placement as the Boneworks baseball bat on the bat viewmodel
SWEP.basebone = 94
SWEP.weaponPos = Vector(5.5,0.2,-0.6)
SWEP.weaponAng = Angle(-79,5,-4)

SWEP.AnimList = {
	["idle"] = "Idle",
	["deploy"] = "Draw",
	["attack"] = "Attack_Quick",
	["attack2"] = "Shove",
}

SWEP.setlh = true
SWEP.setrh = true
SWEP.TwoHanded = true

SWEP.AttackHit = SILENT
SWEP.Attack2Hit = SILENT
SWEP.ChargeAttackHit = SILENT
SWEP.AttackHitFlesh = SILENT
SWEP.Attack2HitFlesh = SILENT
SWEP.ChargeAttackHitFlesh = SILENT
SWEP.AttackSwing = SILENT
SWEP.Attack2Swing = SILENT
SWEP.ChargeAttackSwing = SILENT
SWEP.DeploySnd = SILENT
SWEP.SelfHarmSound = SILENT
SWEP.SuicideSound = SILENT
SWEP.BlockSound = SILENT

SWEP.AttackPos = Vector(0,0,0)
SWEP.BlockTier = 1
SWEP.BlockMaterial = "wood"
SWEP.BlockDirectionalCharge = "overhead"
SWEP.NoHolster = true

SWEP.BreakBoneMul = 0
SWEP.PainMultiplier = 0.2

SWEP.AttackTimeLength = 0.2
SWEP.Attack2TimeLength = 0.001

SWEP.AttackRads = 120
SWEP.AttackRads2 = 0

SWEP.SwingAng = -5
SWEP.SwingAng2 = 0

SWEP.MinSensivity = 0.6

-- launch speed added to every bone of the victim's ragdoll
SWEP.LaunchForce = 650
SWEP.LaunchUp = 320
SWEP.LaunchChargeMul = 1.6
SWEP.LaunchSecondaryMul = 0.6

function SWEP:PlaySwingSound() end
function SWEP:PlaySoftHitSounds() self.SoftHitPlayed = true end
function SWEP:GetBlockSound() return SILENT end
function SWEP:GetClashSoundData() return SILENT end

function SWEP:Launch(ent, mul)
	if CLIENT or not IsValid(ent) then return end

	local owner = self:GetOwner()
	if not IsValid(owner) then return end

	local victim = self:GetHitVictim(ent)
	if not IsValid(victim) or victim == owner then return end
	if victim:IsPlayer() then
		if not victim:Alive() then return end
		local wep = victim:GetActiveWeapon()
		if IsValid(wep) and wep.GetBlocking and wep:GetBlocking() then return end
	end

	local dir = owner:GetAimVector()
	dir.z = 0
	if dir:LengthSqr() < 0.001 then dir = owner:GetForward() end
	dir:Normalize()

	local vel = dir * self.LaunchForce * mul
	vel.z = self.LaunchUp * mul

	timer.Simple(0, function()
		if not IsValid(victim) then return end

		local rag = victim
		if victim:IsPlayer() then
			if not victim:Alive() then return end
			if not IsValid(victim.FakeRagdoll) then hg.Fake(victim, nil, nil, true) end
			rag = victim.FakeRagdoll
		end
		if not IsValid(rag) or not rag:IsRagdoll() then return end

		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:Wake()
				phys:SetVelocity(phys:GetVelocity() + vel)
			end
		end
	end)
end

function SWEP:PrimaryAttackAdd(ent)
	self:Launch(ent, 1)
end

function SWEP:SecondaryAttackAdd(ent)
	self:Launch(ent, self.LaunchSecondaryMul)
end

function SWEP:ChargeAttackAdd(ent)
	self:Launch(ent, self.LaunchChargeMul)
end
