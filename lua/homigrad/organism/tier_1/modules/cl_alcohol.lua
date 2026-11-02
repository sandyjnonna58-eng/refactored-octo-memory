-- Алкоголь на экране (сервер - sv_alcohol.lua, NW2 "rem_bac" - промилле):
-- двоится и плывёт (размытие движения), камеру покачивает, взгляд сам гуляет
hg = hg or {}
hg.Alcohol = hg.Alcohol or {}
local AL = hg.Alcohol

local lerped = 0
local function Level()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then lerped = 0 return 0 end
	lerped = Lerp(math.min(FrameTime() * 0.8, 1), lerped, ply:GetNW2Float("rem_bac", 0))
	return math.Clamp((lerped - 0.3) / 2.2, 0, 1)
end
AL.Level = Level

hook.Add("RenderScreenspaceEffects", "rem_alcohol", function()
	local k = Level()
	if k <= 0.01 then return end
	DrawMotionBlur(0.12, 0.35 + 0.5 * k, 0.01)
	DrawColorModify({
		["$pp_colour_addr"] = 0.01 * k,
		["$pp_colour_addg"] = 0.006 * k,
		["$pp_colour_addb"] = 0,
		["$pp_colour_brightness"] = 0,
		["$pp_colour_contrast"] = 1 - 0.06 * k,
		["$pp_colour_colour"] = 1 + 0.25 * k,
		["$pp_colour_mulr"] = 0,
		["$pp_colour_mulg"] = 0,
		["$pp_colour_mulb"] = 0,
	})
end)

-- покачивание камеры (вызывается из CalcView в cl_camera.lua)
function AL.FilterView(ply, view)
	if not istable(view) then return end
	local k = Level()
	if k <= 0.01 then return end
	local t = CurTime()
	view.angles = view.angles + Angle(math.sin(t * 0.8) * 1.5 * k, math.sin(t * 0.55) * 2 * k, math.sin(t * 0.9) * 7 * k)
	view.fov = (view.fov or 90) + math.sin(t * 0.6) * 4 * k
	return view
end

-- взгляд сам уплывает
hook.Add("CreateMove", "rem_alcohol_aim", function(cmd)
	local k = Level()
	if k <= 0.05 then return end
	local t = CurTime()
	local ft = FrameTime() * 60
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + math.sin(t * 0.7) * 0.05 * k * ft, -89, 89)
	ang.y = ang.y + math.cos(t * 0.45) * 0.08 * k * ft
	cmd:SetViewAngles(ang)
end)
