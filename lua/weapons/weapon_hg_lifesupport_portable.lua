if SERVER then AddCSLuaFile() end
-- Переносной аппарат жизнеобеспечения: маленький, работает хуже стационарного и ест батарейки
-- (заряд = Clip1, 1% в секунду, заряжается ent_lifesupport_battery). Логика - в sv_lifesupport.lua.
SWEP.Base = "weapon_base"
SWEP.PrintName = "Portable Life Support"
SWEP.Instructions = "A small battery-powered ventilator and heart pump. Weaker than a full machine, but you can carry it.\n\nLMB - connect/disconnect yourself\nRMB - connect/disconnect the person you're looking at\nUse batteries to recharge it."
SWEP.Category = "ZCity Medicine"
SWEP.Spawnable = true
SWEP.Slot = 3
SWEP.SlotPos = 8

SWEP.WorldModel = "models/props_lab/reciever01b.mdl"
SWEP.ViewModel = ""
SWEP.HoldType = "slam"

SWEP.Primary.ClipSize = 100
SWEP.Primary.DefaultClip = 50
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

SWEP.IsPortableLifeSupport = true
SWEP.LifeSupportParams = {o2 = 0.6, pulse = 45, heartbeat = 50, pressure = 60, output = 0.6}

local connect_reach = 80

-- положение модели в руке (подбирается в игре)
SWEP.Offset = {
	Pos = Vector(3, 4, -1),
	Ang = Angle(0, 0, 180),
	Size = 0.5
}

function SWEP:SetupDataTables()
	self:NetworkVar("Entity", 0, "Patient")
end

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
end

function SWEP:Toggle(ply)
	if not SERVER then return end

	local LS = hg.LifeSupport
	local patient = self:GetPatient()
	if IsValid(patient) then
		LS.Disconnect(self)
		return
	end

	if not IsValid(ply) then return end
	if self:Clip1() <= 0 then
		self:GetOwner():Notify("The battery is dead.", 0, "lifesupport_battery", 2, nil, Color(255, 120, 120))
		self:EmitSound("buttons/button10.wav", 60)
		return
	end

	LS.Connect(self, ply)
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.5)
	self:Toggle(self:GetOwner())
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 0.5)
	if not SERVER then return end

	if IsValid(self:GetPatient()) then
		self:Toggle()
		return
	end

	local owner = self:GetOwner()
	local tr = hg.eyeTrace(owner, connect_reach)
	local ent = tr and tr.Entity
	if not IsValid(ent) then return end

	local ply = ent:IsPlayer() and ent or (ent:IsRagdoll() and hg.RagdollOwner(ent))
	if IsValid(ply) and ply:Alive() then self:Toggle(ply) end
end

function SWEP:OnRemove()
	if SERVER and IsValid(self:GetPatient()) then hg.LifeSupport.Disconnect(self) end
end

function SWEP:OnDrop()
	if IsValid(self:GetPatient()) then hg.LifeSupport.Disconnect(self) end
end

if CLIENT then
	local tubeMat = Material("cable/cable2")
	local colText = Color(150, 220, 255)
	local colLow = Color(255, 120, 120)

	local function Chest(ply)
		local char = hg.GetCurrentCharacter(ply)
		if not IsValid(char) then return end

		local bone = char:LookupBone("ValveBiped.Bip01_Spine2")
		local mat = bone and char:GetBoneMatrix(bone)
		return mat and mat:GetTranslation() or char:WorldSpaceCenter()
	end

	function SWEP:DrawWorldModel()
		local owner = self:GetOwner()
		if not IsValid(owner) then self:DrawModel() return end

		local bone = owner:LookupBone("ValveBiped.Bip01_R_Hand")
		local pos, ang = bone and owner:GetBonePosition(bone)
		if not pos then return end

		pos = pos + self.Offset.Pos.x * ang:Right() + self.Offset.Pos.y * ang:Forward() + self.Offset.Pos.z * ang:Up()
		ang:RotateAroundAxis(ang:Right(), self.Offset.Ang.p)
		ang:RotateAroundAxis(ang:Up(), self.Offset.Ang.y)
		ang:RotateAroundAxis(ang:Forward(), self.Offset.Ang.r)

		self:SetRenderOrigin(pos)
		self:SetRenderAngles(ang)
		self:SetModelScale(self.Offset.Size, 0)
		self:SetupBones()
		self:DrawModel()

		-- трубка к другому пациенту
		local patient = self:GetPatient()
		local chest = IsValid(patient) and patient ~= owner and Chest(patient)
		if chest then
			render.SetMaterial(tubeMat)
			render.DrawBeam(pos, chest, 1, 0, 1, color_white)
		end
	end

	function SWEP:DrawHUD()
		local charge = self:Clip1()
		local patient = self:GetPatient()
		local status = IsValid(patient) and ("Connected: " .. (patient == LocalPlayer() and "you" or patient:Nick())) or "Disconnected"

		draw.SimpleText("Battery: " .. charge .. "%", "HomigradFont", ScrW() * 0.5, ScrH() * 0.85, charge <= 15 and colLow or colText, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(status, "HomigradFont", ScrW() * 0.5, ScrH() * 0.88, colText, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end
