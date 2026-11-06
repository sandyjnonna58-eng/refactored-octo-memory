-- Алкоголь на экране (сервер - sv_alcohol.lua, NW2 "rem_bac_eff" - действующее опьянение, промилле):
-- двоится и плывёт (размытие движения), камеру покачивает, взгляд сам гуляет; с ~1.8 промилле сильно мотает -
-- камеру кренит и уводит, мир "кружится"
hg = hg or {}
hg.Alcohol = hg.Alcohol or {}
local AL = hg.Alcohol

-- считается один раз за кадр (зовут и эффекты, и камера)
local lerped, lastFrame, lastK, lastHeavy = 0, -1, 0, 0
local function Level()
	local frame = FrameNumber()
	if frame == lastFrame then return lastK, lastHeavy end
	lastFrame = frame
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then lerped, lastK, lastHeavy = 0, 0, 0 return 0, 0 end
	lerped = Lerp(math.min(FrameTime() * 1.6, 1), lerped, ply:GetNW2Float("rem_bac_eff", 0)) -- раньше считалось дважды за кадр по 0.8
	lastK, lastHeavy = math.Clamp((lerped - 0.3) / 2.2, 0, 1), math.Clamp((lerped - 1.8) / 1.2, 0, 1)
	return lastK, lastHeavy
end
AL.Level = Level

-- одна таблица на все кадры, без мусора
local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}

hook.Add("RenderScreenspaceEffects", "rem_alcohol", function()
	local k, heavy = Level()
	if k <= 0.01 then return end
	DrawMotionBlur(0.12 - 0.06 * heavy, 0.35 + 0.5 * k + 0.1 * heavy, 0.01)
	cm["$pp_colour_addr"] = 0.01 * k
	cm["$pp_colour_addg"] = 0.006 * k
	cm["$pp_colour_contrast"] = 1 - 0.06 * k
	cm["$pp_colour_colour"] = 1 + 0.25 * k
	DrawColorModify(cm)
	if heavy > 0.05 then DrawSharpen(-0.6 * heavy, 1.2) end
end)

-- покачивание камеры (вызывается из CalcView в cl_camera.lua)
function AL.FilterView(ply, view)
	if not istable(view) then return end
	local k, heavy = Level()
	if k <= 0.01 then return end
	local t = CurTime()
	local roll = math.sin(t * 0.9) * 7 * k + (math.sin(t * 0.33) * 14 + math.sin(t * 1.7) * 4) * heavy
	local pitch = math.sin(t * 0.8) * 1.5 * k + math.sin(t * 0.61) * 4 * heavy
	local yaw = math.sin(t * 0.55) * 2 * k + math.sin(t * 0.27) * 7 * heavy
	view.angles = view.angles + Angle(pitch, yaw, roll)
	view.fov = (view.fov or 90) + math.sin(t * 0.6) * (4 * k + 6 * heavy)
	return view
end

-- взгляд сам уплывает, сильно пьяного - сильно
hook.Add("CreateMove", "rem_alcohol_aim", function(cmd)
	local k, heavy = Level()
	if k <= 0.05 then return end
	local t = CurTime()
	local ft = FrameTime() * 60
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + (math.sin(t * 0.7) * 0.05 * k + math.sin(t * 0.37) * 0.14 * heavy) * ft, -89, 89)
	ang.y = ang.y + (math.cos(t * 0.45) * 0.08 * k + math.cos(t * 0.23) * 0.25 * heavy) * ft
	cmd:SetViewAngles(ang)
end)
