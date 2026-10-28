-- Невыносимая боль: с 120% боли (100% = 120, с 140% вырубает, sv_pain.lua) звучит rem_excruciatingpain.ogg,
-- и чем сильнее боль, тем он громче. Боль спала, отключился или умер - затихает.
local path = "sound/rem_excruciatingpain.ogg"
local PAIN_100 = 120
local START, FULL = 1.2, 1.4 -- с какой доли боли звучит и на какой - на полную
local VOLUME_MIN, VOLUME_MAX = 0.2, 1.5
local FADE_IN, FADE_OUT = 1, 2.5 -- за сколько секунд громкость догоняет боль / затихает

local station
local loading = false
local volume = 0

hook.Add("Think", "rem_excruciatingpain", function()
	local ply = LocalPlayer()
	local org = IsValid(ply) and ply:Alive() and ply.organism
	local pain = org and not org.otrub and (org.pain or 0) / PAIN_100 or 0

	local target = 0
	if pain >= START then
		target = Lerp(math.Clamp((pain - START) / (FULL - START), 0, 1), VOLUME_MIN, VOLUME_MAX)
	end

	if target > 0 and not IsValid(station) and not loading then
		loading = true
		sound.PlayFile(path, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then return end
			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			volume = 0
			chan:EnableLooping(true)
			chan:SetVolume(0)
			chan:Play()
		end)
	end

	if not IsValid(station) then return end

	volume = math.Approach(volume, target, FrameTime() * VOLUME_MAX / (target > volume and FADE_IN or FADE_OUT))
	if volume <= 0 and target <= 0 then
		station:Stop()
		station = nil
		return
	end
	station:SetVolume(volume)
end)
