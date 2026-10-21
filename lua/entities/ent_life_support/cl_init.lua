include("shared.lua")

local tubeMat = Material("cable/cable2")
local labelColor = Color(225, 225, 225)
local labelOffset = Vector(0, 0, 60)

local function PatientChest(ply)
	local char = hg.GetCurrentCharacter(ply)
	if not IsValid(char) then return end

	local bone = char:LookupBone("ValveBiped.Bip01_Spine2")
	local mat = bone and char:GetBoneMatrix(bone)
	return mat and mat:GetTranslation() or char:WorldSpaceCenter()
end

function ENT:Draw()
	self:DrawModel()

	if LocalPlayer():GetPos():DistToSqr(self:GetPos()) > 300 * 300 then return end

	local patient = self:GetPatient()
	local text = IsValid(patient) and ("LIFE SUPPORT: " .. patient:Nick()) or "LIFE SUPPORT - press E to connect"

	cam.Start3D2D(self:GetPos() + labelOffset, Angle(0, LocalPlayer():EyeAngles().y - 90, 90), 0.08)
		draw.SimpleTextOutlined(text, "RemUI_Title", 0, 0, labelColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
	cam.End3D2D()
end

-- трубка от аппарата к груди пациента
function ENT:DrawTranslucent()
	local patient = self:GetPatient()
	if not IsValid(patient) then return end

	local chest = PatientChest(patient)
	if not chest then return end

	render.SetMaterial(tubeMat)
	render.DrawBeam(self:WorldSpaceCenter(), chest, 1.5, 0, 1, color_white)
end
