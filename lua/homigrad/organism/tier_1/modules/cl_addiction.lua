-- Ломка на клиенте (сервер - sv_addiction.lua): тремор рук - прицел мелко дрожит (при алкогольной ломке сильно),
-- по краям экрана чуть темнеет и пульсирует, когда ломка сильная
local function WD(ply, kind) return ply:GetNW2Float("rem_wd_" .. kind, 0) end

hook.Add("CreateMove", "rem_addiction_tremor", function(cmd)
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local amp = WD(ply, "alcohol") * 0.3 + WD(ply, "nicotine") * 0.07
	if amp < 0.01 then return end
	local t = CurTime()
	local ft = math.min(FrameTime() * 60, 3)
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + (math.sin(t * 71) * 0.6 + math.sin(t * 43) * 0.4) * amp * 0.5 * ft, -89, 89)
	ang.y = ang.y + (math.cos(t * 67) * 0.6 + math.sin(t * 37) * 0.4) * amp * 0.5 * ft
	cmd:SetViewAngles(ang)
end)

local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

hook.Add("RenderScreenspaceEffects", "rem_addiction", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local w = math.max(WD(ply, "alcohol"), WD(ply, "nicotine") * 0.6)
	if w < 0.3 then return end
	local k = (w - 0.3) / 0.7
	local pulse = math.sin(CurTime() * 2.6) * 0.5 + 0.5
	cm["$pp_colour_brightness"] = -0.02 * k * pulse
	cm["$pp_colour_contrast"] = 1 + 0.08 * k
	cm["$pp_colour_colour"] = 1 - 0.2 * k
	DrawColorModify(cm)
end)
