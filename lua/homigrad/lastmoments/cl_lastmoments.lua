-- Последние моменты (sv_lastmoments.lua): песня и воспоминания - скриншоты жизни из data/dreams,
-- которые раз в минуту делает cl_main.lua (лежат в hg.screens)
local song_path = "sound/rem_theseareyourlastmoments.mp3"
local fade_in, fade_out = 1.5, 2
local intro_time = 5
local memory_time_min, memory_time_max = 4, 12
local memory_zoom = 0.08
local colMemory = Color(225, 215, 200)
local colText = Color(235, 235, 235)

local MusicVolume = GetConVar("snd_musicvolume")

local station
local loading = false
local volume = 0
local startTime = 0
local visible = 0

-- пока идут последние моменты, звучит только их песня: остальную музыку глушит hg.RemAudio (remaudio/cl_remaudio.lua)

local function Active()
	local ply = LocalPlayer()
	return IsValid(ply) and ply:Alive() and ply:GetNWFloat("rem_lastmoments_until", 0) > CurTime()
end

hook.Add("Think", "rem_lastmoments", function()
	local active = Active()
	local dt = FrameTime()

	if active and not IsValid(station) and not loading then
		loading = true
		startTime = CurTime()
		sound.PlayFile(song_path, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then return end
			if not Active() then chan:Stop() return end

			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			volume = 0
			chan:SetVolume(0)
			chan:Play()
		end)
	end

	visible = math.Approach(visible, active and 1 or 0, dt / (active and fade_in or fade_out))

	if hg.RemAudio then hg.RemAudio.Duck("lastmoments", active and 0 or nil) end

	if not IsValid(station) then return end

	volume = math.Approach(volume, active and 1 or 0, dt / (active and fade_in or fade_out))
	if volume <= 0 and not active then
		station:Stop()
		station = nil
		return
	end

	station:SetVolume(volume * MusicVolume:GetFloat())
end)

-- воспоминания по очереди: плавно проявляются, медленно приближаются и гаснут
hook.Add("Post Post Pre Post Processing", "rem_lastmoments", function()
	if visible <= 0 then return end

	local sw, sh = ScrW(), ScrH()
	local ply = LocalPlayer()
	local t = CurTime() - startTime
	local window = math.max(ply:GetNWFloat("rem_lastmoments_until", 0) - startTime, intro_time)

	local memories = {}
	for _, mat in ipairs(hg.screens or {}) do
		if mat and not mat:IsError() then memories[#memories + 1] = mat end
	end

	surface.SetDrawColor(0, 0, 0, 255 * visible)
	surface.DrawRect(0, 0, sw, sh)

	if #memories > 0 then
		local per = math.Clamp((window - intro_time) / #memories, memory_time_min, memory_time_max)
		local mt = math.max(t - intro_time, 0)
		local index = math.floor(mt / per) % #memories + 1
		local frac = (mt % per) / per
		local a = (t > intro_time and math.ease.InOutSine(math.sin(frac * math.pi)) or 0) * visible
		local zoom = 1 + memory_zoom * frac
		local w, h = sw * zoom, sh * zoom

		surface.SetMaterial(memories[index])
		surface.SetDrawColor(colMemory.r, colMemory.g, colMemory.b, 200 * a)
		surface.DrawTexturedRect((sw - w) / 2, (sh - h) / 2, w, h)
	end

	local introA = math.Clamp(1 - math.abs(t - intro_time / 2) / (intro_time / 2), 0, 1)
	if #memories == 0 then introA = math.max(introA, 0.6 + 0.2 * math.sin(CurTime() * 1.5)) end
	if introA > 0 then
		draw.SimpleText("These are your last moments.", "RemDeathStateFont", sw / 2, sh * 0.5, ColorAlpha(colText, 255 * introA * visible), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end)
