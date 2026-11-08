-- Паника на клиенте (сервер - sv_panic.lua, NW2 "rem_panic" 0..1, действия тела - sh_panic.lua):
--   чёрные края экрана, которые "плывут" и пульсируют (несколько слоёв rem_fx/tunnel.png со своими колебаниями),
--   экран блекнет; музыка sound/rem_panic/panic.mp3 по кругу (остальная музыка глушится, ярость - важнее);
--   прицел гуляет туда-сюда, при рефлекторном выстреле дёргается к тому, кто появился. Дыхание чаще - cl_main.lua.
local SONG = "sound/rem_panic/panic.mp3"
local FADE_IN, FADE_OUT = 2, 3
local DUCK = 0.15
local ON = 0.35 -- как P.on в sv_panic.lua

local MusicVolume = GetConVar("snd_musicvolume")
local rem_panic_enabled = ConVarExists("rem_panic_enabled") and GetConVar("rem_panic_enabled") or CreateConVar("rem_panic_enabled", 1, FCVAR_REPLICATED + FCVAR_ARCHIVE, "Toggle the panic mechanic", 0, 1)
local PanicVolume = CreateClientConVar("rem_panic_music_volume", "1", true, false, "Volume of the panic music, 1 = 100%", 0, 3)

-- сила паники для эффектов: 0 до начала, 1 на максимуме, плавно
local level = 0
local function Level()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() or not rem_panic_enabled:GetBool() then return 0 end
	return math.Clamp((ply:GetNW2Float("rem_panic", 0) - ON * 0.6) / (1 - ON * 0.6), 0, 1)
end

hook.Add("Think", "rem_panic_level", function()
	level = Lerp(math.min(FrameTime() * 1.5, 1), level, Level())
end)

-- музыка
local hasSong = file.Exists(SONG, "GAME")
local station, loading
local volume = 0

hook.Add("Think", "rem_panic_music", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local want = hasSong and ply:Alive() and ply:GetNW2Float("rem_panic", 0) >= ON and rem_panic_enabled:GetBool()
	if ply:GetNW2Int("rem_rage_stage", 0) > 0 then want = false end -- музыка ярости важнее
	if hg.VortexDeath and hg.VortexDeath.Active and hg.VortexDeath.Active() then want = false end

	if hg.RemAudio then hg.RemAudio.Duck("panic", (want or volume > 0.05) and DUCK or nil) end

	if want and not IsValid(station) and not loading then
		loading = true
		sound.PlayFile(SONG, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then hasSong = false return end
			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			volume = 0
			chan:SetVolume(0)
			chan:EnableLooping(true)
			chan:Play()
		end)
	end
	if not IsValid(station) then return end

	volume = math.Approach(volume, want and 1 or 0, FrameTime() / (want and FADE_IN or FADE_OUT))
	if volume <= 0 and not want then
		station:Stop()
		station = nil
		return
	end
	if station:GetState() == GMOD_CHANNEL_STOPPED then station:Play() end
	station:SetVolume(volume * MusicVolume:GetFloat() * PanicVolume:GetFloat())
end)

-- чёрные плывущие края
local tunnel = Material("rem_fx/tunnel.png", "smooth")
local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}
-- слои: частоты колебаний (x, y, размер) и фазы - разные, поэтому край неровный и всё время ползёт
local LAYERS = {
	{fx = 0.7, fy = 0.9, fs = 1.3, ph = 0, amp = 0.05},
	{fx = 1.6, fy = 1.1, fs = 2.1, ph = 2.1, amp = 0.035},
	{fx = 0.4, fy = 2.3, fs = 0.8, ph = 4.2, amp = 0.06},
}

hook.Add("RenderScreenspaceEffects", "rem_panic", function()
	local k = level
	if k < 0.01 then return end
	local ply = LocalPlayer()
	local t = CurTime()
	local w, h = ScrW(), ScrH()

	-- пульс: края сжимаются в такт сердцу
	local org = ply.organism
	local bpm = org and org.pulse or 100
	local beat = math.max(math.sin(t * math.pi * math.Clamp(bpm, 60, 200) / 60), 0) ^ 4

	cm["$pp_colour_colour"] = 1 - 0.45 * k
	cm["$pp_colour_contrast"] = 1 + 0.15 * k
	cm["$pp_colour_brightness"] = -0.05 * k
	DrawColorModify(cm)

	cam.Start2D()
	surface.SetMaterial(tunnel)
	local base = 2.3 - 1.05 * k - beat * 0.12 * k -- чем сильнее паника - тем уже просвет
	for i, L in ipairs(LAYERS) do
		local s = base + math.sin(t * L.fs + L.ph) * L.amp * 2
		local sw, sh = w * s, h * s * 1.15
		local ox = math.sin(t * L.fx + L.ph) * w * L.amp * k
		local oy = math.cos(t * L.fy + L.ph * 0.7) * h * L.amp * k
		surface.SetDrawColor(0, 0, 0, 255 * math.min(k * (i == 1 and 1.1 or 0.8), 1))
		surface.DrawTexturedRect(w * 0.5 - sw * 0.5 + ox, h * 0.5 - sh * 0.5 + oy, sw, sh)
	end
	-- на сильной панике чернота иногда "накатывает" волной
	local surge = math.max(math.sin(t * 0.9) * math.sin(t * 2.3), 0) * math.max(k - 0.5, 0) * 2
	if surge > 0.01 then
		local s = base * (1 - surge * 0.25)
		surface.SetDrawColor(0, 0, 0, 200 * surge)
		surface.DrawTexturedRect(w * 0.5 - w * s * 0.5, h * 0.5 - h * s * 0.575, w * s, h * s * 1.15)
	end
	cam.End2D()
end)

-- прицел гуляет; при рефлекторном выстреле - рывок к тому, кто появился
hook.Add("CreateMove", "rem_panic_aim", function(cmd)
	local k = level
	if k < 0.02 then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or IsValid(ply.FakeRagdoll) then return end
	local t = CurTime()
	local ft = FrameTime() * 60
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + (math.sin(t * 1.7) * 0.05 + math.sin(t * 4.3) * 0.035) * k * ft, -89, 89)
	ang.y = ang.y + (math.cos(t * 1.3) * 0.07 + math.sin(t * 5.1) * 0.045) * k * ft

	if ply:GetNW2Float("rem_panic_fire", 0) > t then
		local want = (ply:GetNW2Vector("rem_panic_aim", ply:EyePos()) - ply:EyePos()):Angle()
		ang = LerpAngle(math.min(FrameTime() * 12, 1), ang, want)
		ang.r = 0
	end
	cmd:SetViewAngles(ang)
end)
