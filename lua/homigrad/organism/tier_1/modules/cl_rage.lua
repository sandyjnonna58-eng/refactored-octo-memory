-- Ярость на клиенте (сервер - sv_rage.lua, NW2 "rem_rage" 0..1 и "rem_rage_stage" 0..3):
--   музыка (sound/rem_rage_private/anger.mp3, приватный пак): у каждой стадии свой кусок трека, он крутится по кругу;
--   стадия сменилась - трек прыгает на её начало; ярость прошла - музыка затихает. Пока играет, остальная музыка глушится.
--   экран краснеет и контрастнее (3-я стадия пульсирует), со 2-й стадии прицел мелко дрожит - руки трясутся.
local SONG = "sound/rem_rage_private/anger.mp3"
-- куски трека по стадиям, секунды (3-я - до конца трека)
local SEGMENTS = {{0, 59}, {58, 117}, {117, math.huge}}
local FADE_IN, FADE_OUT = 1.5, 3
local DUCK = 0.15 -- до какой доли глушится остальная музыка

local MusicVolume = GetConVar("snd_musicvolume")
local RageVolume = CreateClientConVar("rem_rage_music_volume", "1", true, false, "Volume of the rage music, 1 = 100%", 0, 3)

local hasSong = file.Exists(SONG, "GAME")
local station, loading
local volume, curStage = 0, 0

local function Stage(ply)
	return ply:GetNW2Int("rem_rage_stage", 0)
end

hook.Add("Think", "rem_rage_music", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local stage = ply:Alive() and Stage(ply) or 0
	-- на экране умирания своя песня
	if hg.VortexDeath and hg.VortexDeath.Active and hg.VortexDeath.Active() then stage = 0 end
	local want = hasSong and stage > 0

	if hg.RemAudio then hg.RemAudio.Duck("rage", (want or volume > 0.05) and DUCK or nil) end

	if want and not IsValid(station) and not loading then
		loading = true
		sound.PlayFile(SONG, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then hasSong = false return end
			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			curStage = 0
			volume = 0
			chan:SetVolume(0)
			chan:Play()
		end)
	end
	if not IsValid(station) then return end

	-- новая стадия - на начало её куска
	if want and stage ~= curStage then
		curStage = stage
		station:SetTime(SEGMENTS[stage][1])
	end
	-- кусок кончился - по кругу
	if curStage > 0 then
		local seg = SEGMENTS[curStage]
		local stop = math.min(seg[2], station:GetLength() - 0.1)
		if station:GetTime() >= stop or station:GetState() == GMOD_CHANNEL_STOPPED then
			station:SetTime(seg[1])
			if station:GetState() ~= GMOD_CHANNEL_PLAYING then station:Play() end
		end
	end

	volume = math.Approach(volume, want and 1 or 0, FrameTime() / (want and FADE_IN or FADE_OUT))
	if volume <= 0 and not want then
		station:Stop()
		station = nil
		curStage = 0
		return
	end
	station:SetVolume(volume * MusicVolume:GetFloat() * RageVolume:GetFloat())
end)

-- экран: краснее и резче; одна таблица на все кадры
local cm = {
	["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
}
local lerped = 0

hook.Add("RenderScreenspaceEffects", "rem_rage", function()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then lerped = 0 return end
	lerped = Lerp(math.min(FrameTime() * 2, 1), lerped, ply:GetNW2Float("rem_rage", 0))
	if lerped < 0.15 then return end
	local k = math.Clamp((lerped - 0.15) / 0.85, 0, 1)
	-- 3-я стадия - пульсирует
	local pulse = lerped >= 0.8 and (math.sin(CurTime() * 7) * 0.5 + 0.5) * 0.04 or 0
	cm["$pp_colour_addr"] = 0.03 * k + pulse
	cm["$pp_colour_contrast"] = 1 + 0.25 * k
	cm["$pp_colour_colour"] = 1 - 0.25 * k
	cm["$pp_colour_mulr"] = 0.4 * k
	cm["$pp_colour_brightness"] = -0.03 * k
	DrawColorModify(cm)
end)

-- со 2-й стадии руки трясутся
hook.Add("CreateMove", "rem_rage_tremor", function(cmd)
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local stage = Stage(ply)
	if stage < 2 then return end
	local amp = stage == 3 and 0.12 or 0.06
	local t = CurTime()
	local ft = math.min(FrameTime() * 60, 3)
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p + (math.sin(t * 61) * 0.6 + math.sin(t * 29) * 0.4) * amp * ft, -89, 89)
	ang.y = ang.y + (math.cos(t * 57) * 0.6 + math.sin(t * 33) * 0.4) * amp * ft
	cmd:SetViewAngles(ang)
end)
