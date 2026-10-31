-- Пояс смертника: в руке пульт. ЛКМ - случайный крик (sound/rem_vest/jihad*), потом всегда звонок Nokia,
-- потом сильный взрыв через общую очередь взрывов (autorun/server/sv_rem_bombs.lua). Если хозяина убьют
-- раньше - пояс всё равно сработает там, где он лежит.
if SERVER then
	AddCSLuaFile()
	resource.AddSingleFile("sound/rem_vest/jihad1.wav")
	resource.AddSingleFile("sound/rem_vest/jihad3.wav")
	resource.AddSingleFile("sound/rem_vest/nokia.mp3")
end

SWEP.Base = "weapon_base"
SWEP.PrintName = "Suicide Vest"
SWEP.Instructions = "Primary attack to detonate."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"

SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

SWEP.HoldType = "slam"
SWEP.ViewModel = ""
SWEP.WorldModel = "models/sirgibs/ragdoll/css/terror_arctic_radio.mdl"

if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/wep_jack_hmcd_walkietalkie")
	SWEP.IconOverride = "vgui/wep_jack_hmcd_walkietalkie.png"
	SWEP.BounceWeaponIcon = false
end

SWEP.Weight = 0
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
SWEP.Slot = 5
SWEP.SlotPos = 6
SWEP.WorkWithFake = true
SWEP.offsetVec = Vector(6, 5.5, -41)
SWEP.offsetAng = Angle(180, 160, 180)

-- крик (длина в секундах), потом звонок, потом взрыв
SWEP.Shouts = {
	{"rem_vest/jihad1.wav", 1.0},
	{"rem_vest/jihad3.wav", 1.31},
}
SWEP.Ring = {"rem_vest/nokia.mp3", 1.07}
SWEP.BlastRadius = 700
SWEP.BlastDamage = 600

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
end

function SWEP:DrawWorldModel()
	if not self:GetOwner():IsPlayer() then
		self:DrawModel()
	end
end

function SWEP:DrawWorldModel2()
	self.model = IsValid(self.model) and self.model or ClientsideModel(self.WorldModel)
	local WorldModel = self.model
	local owner = hg.GetCurrentCharacter(self:GetOwner())

	WorldModel:SetNoDraw(true)

	if IsValid(owner) then
		local boneid = owner:LookupBone("ValveBiped.Bip01_L_Hand")
		if not boneid then return end
		local matrix = owner:GetBoneMatrix(boneid)
		if not matrix then return end

		local newPos, newAng = LocalToWorld(self.offsetVec, self.offsetAng, matrix:GetTranslation(), matrix:GetAngles())
		WorldModel:SetPos(newPos)
		WorldModel:SetAngles(newAng)
		WorldModel:SetupBones()
		WorldModel:DrawModel()
	else
		WorldModel:SetPos(self:GetPos())
		WorldModel:SetAngles(self:GetAngles())
		WorldModel:DrawModel()
	end
end

function SWEP:OnRemove()
	if CLIENT and IsValid(self.model) then self.model:Remove() end
end

function SWEP:SecondaryAttack() end
function SWEP:Reload() end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 10)
	if CLIENT then return end

	local owner = self:GetOwner()
	if not IsValid(owner) or self.Activated then return end
	self.Activated = true
	self:Detonate(owner)
end

if SERVER then
	-- где сейчас тело хозяина (живой, в рэгдолле или уже мёртвый)
	local function BodyOf(ply)
		local char = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply)
		if IsValid(char) then return char end
		local rag = ply:GetRagdollEntity()
		if IsValid(rag) then return rag end
		return ply
	end

	local function Explode(ply, pos, radius, damage)
		local profile = {
			Decal = "scorch_big",
			Trace = 400,
			Effect = "doi_stuka_explosion",
			EffectAir = "doi_stuka_explosion",
			EffectWater = "ins_water_explosion",
			Sound = "ied/ied_detonate_0" .. math.random(3) .. ".wav",
			FarSound = "ied/ied_detonate_dist_0" .. math.random(3) .. ".wav",
			WaterSound = "iedins/water/ied_water_detonate_01.wav",
			WaterFarSound = "iedins/water/ied_water_detonate_01.wav",
			Force = 60000,
			Lift = 25000,
		}
		if rem_QueueExplosion then
			rem_QueueExplosion({Pos = pos, Radius = radius, Damage = damage, Owner = ply, Profile = profile})
		else
			util.BlastDamage(game.GetWorld(), IsValid(ply) and ply or game.GetWorld(), pos, radius, damage)
		end

		-- сам смертник не выживает ни при какой броне
		timer.Simple(0.2, function()
			if IsValid(ply) and ply:Alive() then ply:Kill() end
		end)
	end

	function SWEP:Detonate(ply)
		local shout = self.Shouts[math.random(#self.Shouts)]
		local ring = self.Ring
		local radius, damage = self.BlastRadius, self.BlastDamage
		local lastPos = BodyOf(ply):WorldSpaceCenter()

		local function track()
			if not IsValid(ply) then return lastPos end
			local body = BodyOf(ply)
			if IsValid(body) then lastPos = body:WorldSpaceCenter() end
			return lastPos
		end

		-- крик
		BodyOf(ply):EmitSound(shout[1], 100, 100, 1, CHAN_VOICE)

		-- звонок Nokia - всегда перед взрывом
		timer.Simple(shout[2], function()
			local pos = track()
			local body = IsValid(ply) and BodyOf(ply)
			if IsValid(body) then
				body:EmitSound(ring[1], 95, 100, 1, CHAN_ITEM)
			else
				sound.Play(ring[1], pos, 95, 100, 1)
			end
		end)

		-- взрыв
		timer.Simple(shout[2] + ring[2], function()
			local pos = track()
			if IsValid(self) then self:Remove() end
			Explode(ply, pos, radius, damage)
		end)
	end
end
