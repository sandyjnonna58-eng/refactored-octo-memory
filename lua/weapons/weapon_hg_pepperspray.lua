if SERVER then AddCSLuaFile() end
-- Перцовый баллончик: держа ЛКМ, брызгаешь конусом; у попавших жжёт глаза (боль, дезориентация, кашель, красный экран).
-- Рука и модель в руке - как у спичек (weapon_matches).
SWEP.Base = "weapon_matches"

if CLIENT then
	SWEP.PrintName = "Pepper Spray"
	SWEP.Slot = 3
	SWEP.SlotPos = 7
end

SWEP.Instructions = "A can of pepper spray. Aim for the face.\n\nHold LMB to spray."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/weapons/custom/pepperspray.mdl"
SWEP.NoInfiniteAmmo = nil

SWEP.Primary.ClipSize = 100
SWEP.Primary.DefaultClip = 100

-- положение модели в руке (подбирается в игре)
SWEP.Offset = {
	Pos = Vector(1.5, 3, -1),
	Ang = Angle(0, 0, 90),
	Size = 1
}

local spray_interval = 0.08
local spray_range = 260
local spray_cone_cos = math.cos(math.rad(18))
local pepper_time = 10
local pepper_pain = 2
local pepper_disorientation = 0.6
local pepper_disorientation_max = 4

function SWEP:DrawHUD()
end

local function GetFacePos(ply)
	local char = hg.GetCurrentCharacter(ply)
	local head = IsValid(char) and char:LookupBone("ValveBiped.Bip01_Head1")
	local mat = head and char:GetBoneMatrix(head)
	return mat and mat:GetTranslation() or ply:EyePos()
end

local function Pepper(target, attacker)
	local org = target.organism
	if not org then return end

	org.painadd = org.painadd + pepper_pain
	org.disorientation = math.min((org.disorientation or 0) + pepper_disorientation, pepper_disorientation_max)

	local fresh = target:GetNWFloat("rem_pepper_until", 0) < CurTime()
	target:SetNWFloat("rem_pepper_until", CurTime() + pepper_time)

	if fresh then target:Notify("My eyes are burning!", 0, "pepper_spray", 2, nil, Color(255, 140, 60)) end

	if (target.pepperNextCough or 0) < CurTime() then
		target.pepperNextCough = CurTime() + math.Rand(1.2, 2.2)
		target:EmitSound("ambient/voices/cough" .. math.random(1, 4) .. ".wav", 70)
	end
end

function SWEP:SprayEffect(owner)
	if not IsFirstTimePredicted() then return end

	local pos = owner:GetShootPos() + owner:GetAimVector() * 16 - vector_up * 6
	local emitter = ParticleEmitter(pos)
	if not emitter then return end

	for i = 1, 3 do
		local particle = emitter:Add("particle/particle_smokegrenade", pos)
		if particle then
			particle:SetVelocity(owner:GetAimVector() * math.Rand(300, 420) + VectorRand() * 25)
			particle:SetAirResistance(120)
			particle:SetDieTime(math.Rand(0.4, 0.7))
			particle:SetStartAlpha(110)
			particle:SetEndAlpha(0)
			particle:SetStartSize(2)
			particle:SetEndSize(math.Rand(12, 18))
			particle:SetColor(255, 140, 60)
		end
	end

	emitter:Finish()
end

function SWEP:PrimaryAttack()
	local owner = self:GetOwner()
	if not IsValid(owner) then return end

	self:SetNextPrimaryFire(CurTime() + spray_interval)

	if self:Clip1() <= 0 then
		if SERVER and (self.nextEmptySound or 0) < CurTime() then
			self.nextEmptySound = CurTime() + 0.5
			self:EmitSound("weapons/clipempty_pistol.wav", 60)
		end
		return
	end

	self:SetHolding(100)
	self:TakePrimaryAmmo(1)

	if CLIENT then
		self:SprayEffect(owner)
		return
	end

	if (self.nextSpraySound or 0) < CurTime() then
		self.nextSpraySound = CurTime() + 0.3
		self:EmitSound("player/sprayer.wav", 60, 140)
	end

	local shootPos = owner:GetShootPos()
	local aim = owner:GetAimVector()

	for _, target in player.Iterator() do
		if target == owner or not target:Alive() then continue end

		local face = GetFacePos(target)
		local dir = face - shootPos
		local dist = dir:Length()
		if dist > spray_range or aim:Dot(dir / dist) < spray_cone_cos then continue end

		local tr = util.TraceLine({start = shootPos, endpos = face, filter = {owner, hg.GetCurrentCharacter(owner)}, mask = MASK_SHOT})
		if tr.Hit and tr.Entity ~= target and tr.Entity ~= hg.GetCurrentCharacter(target) then continue end

		Pepper(target, owner)
	end
end

if CLIENT then
	-- жжение в глазах: красный экран и плывущая картинка
	local colPepper = Color(255, 90, 30)

	local function PepperFrac()
		local ply = LocalPlayer()
		if not IsValid(ply) or not ply:Alive() then return 0 end
		return math.Clamp((ply:GetNWFloat("rem_pepper_until", 0) - CurTime()) / pepper_time, 0, 1)
	end

	hook.Add("RenderScreenspaceEffects", "rem_pepper_spray", function()
		local frac = PepperFrac()
		if frac <= 0 then return end

		DrawMotionBlur(0.12, 0.85 * frac, 0.01)
	end)

	hook.Add("HUDPaint", "rem_pepper_spray", function()
		local frac = PepperFrac()
		if frac <= 0 then return end

		colPepper.a = (90 + math.sin(CurTime() * 3) * 25) * frac
		surface.SetDrawColor(colPepper)
		surface.DrawRect(0, 0, ScrW(), ScrH())
	end)
end
