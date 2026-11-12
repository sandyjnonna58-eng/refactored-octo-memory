include("shared.lua")

local gradR = Material("vgui/gradient-r")
local glow = Material("sprites/light_glow02_add")

function ENT:Draw()
	self:DrawModel()
end

function ENT:DrawTranslucent()
	local ply = LocalPlayer()
	local dist = ply:EyePos():Distance(self:GetPos())
	if dist > 700 then return end

	local alpha = math.Clamp((700 - dist) / 200, 0, 1)
	local thinking = self:GetThinking()
	local t = CurTime()

	local pos = self:LocalToWorld(Vector(0, 0, self:OBBMaxs().z + 14 + math.sin(t * 2) * 2))

	-- Светящаяся сфера над терминалом
	local pulse = thinking and (0.6 + math.abs(math.sin(t * 8)) * 0.4) or (0.5 + math.sin(t * 2) * 0.15)
	render.SetMaterial(glow)
	render.DrawSprite(pos - Vector(0, 0, 6), 46 * pulse, 46 * pulse, Color(130, 110, 255, 255 * alpha))

	-- Табличка, всегда повёрнутая к игроку
	local yaw = (ply:EyePos() - pos):Angle().y

	cam.Start3D2D(pos + Vector(0, 0, 18), Angle(0, yaw + 90, 90), 0.08)
		local w, h = 420, 120
		local a = 255 * alpha
		draw.RoundedBox(16, -w / 2, -h / 2, w, h, Color(14, 15, 22, 235 * alpha))
		surface.SetMaterial(gradR)
		surface.SetDrawColor(60, 180, 255, a)
		surface.DrawTexturedRect(-w / 2 + 16, h / 2 - 6, w - 32, 4)
		surface.SetDrawColor(130, 110, 255, a)
		surface.DrawRect(-w / 2 + 16, h / 2 - 6, (w - 32) / 2, 4)

		draw.SimpleText("ИИ ТЕРМИНАЛ", "GeminiAI_3D_Title", 0, -22, Color(235, 238, 245, a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		local sub, col
		if thinking then
			sub = "Думаю" .. string.rep(".", math.floor(t * 3) % 4)
			col = Color(60, 180, 255, a)
		else
			sub = "Нажмите [E], чтобы поговорить"
			col = Color(150, 155, 175, a)
		end
		draw.SimpleText(sub, "GeminiAI_3D_Sub", 0, 24, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	cam.End3D2D()

	-- Мягкая подсветка вокруг
	local dl = DynamicLight(self:EntIndex())
	if dl then
		dl.pos = pos
		dl.r, dl.g, dl.b = 130, 110, 255
		dl.brightness = thinking and 3 or 1
		dl.decay = 1000
		dl.size = 160 * pulse
		dl.dietime = CurTime() + 0.1
	end
end

surface.CreateFont("GeminiAI_3D_Title", { font = "Roboto", size = 52, weight = 900, extended = true, antialias = true })
surface.CreateFont("GeminiAI_3D_Sub", { font = "Roboto", size = 30, weight = 600, extended = true, antialias = true })
