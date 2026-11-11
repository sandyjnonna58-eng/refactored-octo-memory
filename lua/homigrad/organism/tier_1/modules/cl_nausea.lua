-- Тошнота на экране (уровень - NW2 "rem_nausea", сервер - sv_vomit.lua / sv_gorenausea.lua):
-- с 0.2 мир чуть зеленеет и тускнеет, с 0.45 экран мутно плывёт волнами и покачивает прицел,
-- с 0.8 ("сейчас вырвет") края темнеют и пульсируют, качает сильнее.
local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}
local shown = 0

local function Level()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return 0 end
	return ply:GetNW2Float("rem_nausea", 0)
end

hook.Add("RenderScreenspaceEffects", "rem_nausea", function()
	shown = math.Approach(shown, Level(), FrameTime() * 0.5) -- плавно (приходит шагами по 0.1)
	if shown < 0.2 then return end
	local k = (shown - 0.2) / 0.8
	local t = CurTime()
	local wave = math.sin(t * 1.7) * 0.5 + 0.5
	cm["$pp_colour_addg"] = 0.03 * k
	cm["$pp_colour_addr"] = -0.01 * k
	cm["$pp_colour_colour"] = 1 - 0.3 * k
	cm["$pp_colour_contrast"] = 1 - 0.06 * k
	cm["$pp_colour_brightness"] = shown >= 0.8 and -0.05 * wave or 0
	DrawColorModify(cm)
	if shown >= 0.45 then
		DrawMaterialOverlay("effects/water_warp01", 0.008 * k + 0.006 * k * wave)
	end
	if shown >= 0.8 then DrawMotionBlur(0.2, 0.35 * wave, 0.02) end
end)

hook.Add("CreateMove", "rem_nausea_sway", function(cmd)
	if shown < 0.45 then return end
	local k = (shown - 0.45) / 0.55
	local t = CurTime()
	local ft = math.min(FrameTime() * 60, 3)
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + math.sin(t * 0.9) * 0.05 * k * ft, -89, 89)
	ang.y = ang.y + math.cos(t * 0.6) * 0.07 * k * ft
	cmd:SetViewAngles(ang)
end)
