if SERVER then AddCSLuaFile() end
-- Камера Far Cry отдельным предметом: выдаётся сама, когда достаёшь мачете FC3 (homigrad/fccamera/sh_fccamera.lua).
-- Пока она в руках, видоискатель поднят: навести на игрока/NPC - отметится, ЛКМ - отметить/снять, ПКМ - зум,
-- X - обратно к мачете. Вся логика камеры - в homigrad/fccamera, здесь только предмет.
SWEP.Base = "weapon_base"
SWEP.PrintName = "Far Cry Camera"
SWEP.Instructions = "Look through the camera to tag players and NPCs.\n\nAim at a target to tag it.\nLMB to tag/untag.\nRMB to zoom.\nX to go back to the machete."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.ViewModel = ""
SWEP.WorldModel = "models/maxofs2d/camera.mdl"
SWEP.HoldType = "camera"
SWEP.UseHands = false
SWEP.DrawCrosshair = false
SWEP.DrawAmmo = false
SWEP.Slot = 0
SWEP.SlotPos = 9
SWEP.Weight = 1
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

SWEP.FCCamera = true       -- камера разрешена
SWEP.FCCameraAlways = true -- и поднята, пока предмет в руках

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
end

function SWEP:Deploy()
	self:SetHoldType(self.HoldType)
	return true
end

-- отметки и зум делает клиентская часть камеры
function SWEP:PrimaryAttack() end
function SWEP:SecondaryAttack() end
function SWEP:Reload() end

-- в руках камеру рисует homigrad/fccamera (перед лицом), на земле - сама модель
function SWEP:DrawWorldModel()
	if not IsValid(self:GetOwner()) then self:DrawModel() end
end
