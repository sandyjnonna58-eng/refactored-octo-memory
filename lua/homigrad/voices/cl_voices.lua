-- Голоса (sv_voices.lua): звучат в голове, остальная музыка на это время приглушается (hg.RemAudio)
local path = "sound/rem_theytalktoyou.mp3"
local volume_max = 0.8
local fade_in, fade_out = 0.8, 1.5
local duck_to = 0.25
-- во время суицида (позыв, оружие у головы) голоса тише
local suicide_mul = 0.35
local suicide_fade = 0.5 -- за сколько секунд стихают / возвращаются

local suicideK = 1

local function Suiciding(ply)
	local now = CurTime()
	return ply:GetNWBool("suiciding", false) or ply:GetNWFloat("rem_suicide_hold", 0) > now or ply:GetNWFloat("rem_urges_end", 0) > now
end

local station

local function Stop()
	if IsValid(station) then station:Stop() end
	station = nil
	if hg.RemAudio then hg.RemAudio.Duck("voices", nil) end
end

net.Receive("rem_voices", function()
	if IsValid(station) then return end

	sound.PlayFile(path, "noblock noplay", function(chan)
		if not IsValid(chan) then return end
		if IsValid(station) then chan:Stop() return end

		station = chan
		suicideK = Suiciding(LocalPlayer()) and suicide_mul or 1
		if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
		chan:SetVolume(0)
		chan:Play()
	end)
end)

hook.Add("Think", "rem_voices", function()
	if not IsValid(station) then return end

	if not LocalPlayer():Alive() or station:GetState() == GMOD_CHANNEL_STOPPED then
		Stop()
		return
	end

	local t, len = station:GetTime(), station:GetLength()
	local vol = math.min(t / fade_in, (len - t) / fade_out, 1)
	suicideK = math.Approach(suicideK, Suiciding(LocalPlayer()) and suicide_mul or 1, FrameTime() / suicide_fade)
	station:SetVolume(math.max(vol, 0) * volume_max * suicideK)

	if hg.RemAudio then hg.RemAudio.Duck("voices", duck_to) end
end)
