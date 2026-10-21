include("shared.lua")

local labelColor = Color(230, 190, 0)
local labelOffset = Vector(0, 0, 80)

function ENT:Draw()
	self:DrawModel()

	if LocalPlayer():GetPos():DistToSqr(self:GetPos()) > 300 * 300 then return end

	-- надпись всегда повёрнута к игроку
	cam.Start3D2D(self:GetPos() + labelOffset, Angle(0, LocalPlayer():EyeAngles().y - 90, 90), 0.1)
		draw.SimpleTextOutlined("MUTATION STATION", "RemUI_Title", 0, 0, labelColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
	cam.End3D2D()
end
