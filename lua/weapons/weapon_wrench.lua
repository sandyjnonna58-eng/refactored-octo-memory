if SERVER then AddCSLuaFile() end
-- Гаечный ключ (из MELEECITY): модель Boneworks на анимациях топорика.
-- Заряженный удар (R + ЛКМ) вместо их "тяжёлого удара", ПКМ + ЛКМ - бросок.
SWEP.Base = "weapon_melee"
SWEP.PrintName = "Wrench"
SWEP.Instructions = "A heavy-duty wrench built for gripping and twisting. Its solid metal frame makes it effective for blocking paths or slowing down anyone trying to push through.\n\nLMB to attack.\nRMB to block.\nR + LMB (hold) for a charged swing.\nRMB + LMB to throw."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false

if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/newwrench.png")
	SWEP.IconOverride = "vgui/newwrench.png"
	SWEP.BounceWeaponIcon = false
end

SWEP.SuicidePos = Vector(-12, -4, -8)
SWEP.SuicideAng = Angle(-0, 30, -50)
SWEP.SuicideCutVec = Vector(-2, -6, 2)
SWEP.SuicideCutAng = Angle(10, 0, 0)
SWEP.SuicideTime = 0.5
SWEP.SuicideSound = "player/flesh/flesh_bullet_impact_03.wav"
SWEP.CanSuicide = false
SWEP.SuicideNoLH = true
SWEP.SuicidePunchAng = Angle(5, -15, 0)

SWEP.WorldModel = "models/hatedmekkr/boneworks/weapons/melee/blunts/misc/bw_wpn_bnt_wrench.mdl"
SWEP.WorldModelReal = "models/weapons/tfa_nmrih/v_me_hatchet.mdl"
SWEP.WorldModelExchange = "models/hatedmekkr/boneworks/weapons/melee/blunts/misc/bw_wpn_bnt_wrench.mdl"
SWEP.DontChangeDropped = false
SWEP.ViewModel = ""
SWEP.modelscale = 0.85

SWEP.HoldType = "melee"
SWEP.HoldPos = Vector(-15, 2, -4)
SWEP.HoldAng = Angle(-15, 0, 0)

SWEP.AttackTime = 0.5
SWEP.AnimTime1 = 1.65
SWEP.WaitTime1 = 1.35
SWEP.AttackLen1 = 45
SWEP.ViewPunch1 = Angle(1, 1, 0)

SWEP.Attack2Time = 0.45
SWEP.AnimTime2 = 1.57
SWEP.WaitTime2 = 1.25
SWEP.AttackLen2 = 40
SWEP.ViewPunch2 = Angle(0, 0, -2)

SWEP.attack_ang = Angle(0, 0, 0)
SWEP.sprint_ang = Angle(15, 0, 0)

SWEP.basebone = 94
SWEP.weaponPos = Vector(0, 0, -6.45)
SWEP.weaponAng = Angle(-5, -90, 0)

SWEP.AnimList = {
	["idle"] = "Idle",
	["deploy"] = "Draw",
	["attack"] = "Attack_Quick",
	["attack2"] = "Attack_Quick",
	["charge_begin"] = "Attack_Charge_Begin",
	["charge_idle"] = "Attack_Charge_Idle",
	["charge_end"] = "Attack_Charge_End",
}

SWEP.setlh = false
SWEP.setrh = true
SWEP.TwoHanded = false

SWEP.DamageType = DMG_CLUB
SWEP.DamagePrimary = 20
SWEP.DamageSecondary = 10
SWEP.PenetrationPrimary = 2
SWEP.PenetrationSecondary = 2
SWEP.MaxPenLen = 1
SWEP.PenetrationSizePrimary = 1
SWEP.PenetrationSizeSecondary = 1
SWEP.PainMultiplier = 1.2
SWEP.StaminaPrimary = 27
SWEP.StaminaSecondary = 15
SWEP.weight = 1.5

SWEP.AttackHit = "Concrete.ImpactHard"
SWEP.Attack2Hit = "Concrete.ImpactHard"
SWEP.AttackHitFlesh = "Flesh.ImpactHard"
SWEP.Attack2HitFlesh = "Flesh.ImpactHard"
SWEP.DeploySnd = "physics/metal/metal_solid_impact_soft1.wav"
SWEP.HitFleshExtra = {
	"shovelcrowbarshared/shovelhit1.ogg",
	"shovelcrowbarshared/shovelhit2.ogg",
}
SWEP.HitFleshExtraPitch = 115
SWEP.SwingSound = "baseballbat/swing.ogg"
SWEP.SwingSoundPitch = {145, 152}

SWEP.AttackTimeLength = 0.15
SWEP.Attack2TimeLength = 0.1
SWEP.AttackRads = 55
SWEP.AttackRads2 = 65
SWEP.SwingAng = -90
SWEP.SwingAng2 = 0
SWEP.AttackPos = Vector(0, 0, 0)

SWEP.BlockTier = 2
SWEP.MeleeMaterial = "metal"
SWEP.BlockImpactSound = "physics/metal/metal_solid_impact_soft1.wav"

-- заряженный удар (их HeavyAttack): до x2 урона за 2 секунды
SWEP.canchargeattack = true
SWEP.ChargeAnimTimeBegin = 1.0
SWEP.ChargeAnimTimeIdle = 1
SWEP.ChargeAnimTimeEnd = 1.85
SWEP.ChargeFullTime = 2.0
SWEP.ChargeAttackTime = 0.43
SWEP.ChargeAttackTimeLength = 0.45
SWEP.ChargeWaitTime = 1.7
SWEP.ChargeAttackLen = 50
SWEP.ChargeAttackRads = 100
SWEP.ChargeSwingAng = -90
SWEP.ChargeStamina = 40
SWEP.ChargeDamageMul = 2.0
SWEP.ChargeViewPunch = Angle(5, 0, 0)
-- у нас ChargeHoldPos - сама позиция, а не добавка к HoldPos, как HeavyChargeHoldPos в MELEECITY; как у мачете на тех же NMRIH-анимациях
SWEP.ChargeHoldPos = Vector(-12, 0, -6)

function SWEP:CanPrimaryAttack()
	return true
end

function SWEP:CustomAttack2()
	local ent = ents.Create("ent_throwable")
	ent.WorldModel = self.WorldModelExchange or self.WorldModel

	local ply = self:GetOwner()

	ent:SetPos(select(1, hg.eye(ply, 60, hg.GetCurrentCharacter(ply))) - ply:GetAimVector() * 2)
	ent:SetAngles(ply:EyeAngles())
	ent:SetOwner(ply)
	ent:Spawn()

	ent.localshit = Vector(0, 0, 0)
	ent.wep = self:GetClass()
	ent.owner = ply
	ent.damage = 15
	ent.MaxSpeed = 700
	ent.DamageType = DMG_CLUB
	ent.AttackHit = self.AttackHit
	ent.AttackHitFlesh = self.AttackHitFlesh
	ent.noStuck = true

	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetVelocity(ply:GetAimVector() * ent.MaxSpeed)
		phys:AddAngleVelocity(Vector(0, ent.MaxSpeed, 0))
	end

	ply:ViewPunch(Angle(0, 0, -8))
	ply:SelectWeapon("weapon_hands_sh")

	self:Remove()

	return true
end
