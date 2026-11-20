-- Звуки кардиомонитора по SCAV (wiki Heart_rate), только у себя:
--   фибрилляция > 60% - тревога (sound/rem_heart/alarm.wav по кругу, пока в сознании и сердце бьётся);
--   с 80% пульс слабеет - звук фибрилляции тише (hg.remFibVol: 1 -> 0.35 к 99%, его берёт cl_main.lua);
--   сердце остановилось - непрерывный тон (rem_heart/flatline.wav, 3.5 с) вместе с прежним звуком остановки.
-- Звуки - свой синтез, tools/sounds/make_heart_monitor.py. Выкл.: rem_heart_alarm 0, rem_heart_flatline 0.
local cvAlarm = CreateClientConVar("rem_heart_alarm", "1", true, false, "Heart monitor alarm when fibrillation is above 60%", 0, 1)
local cvFlat = CreateClientConVar("rem_heart_flatline", "1", true, false, "Flatline tone when the heart stops", 0, 1)

local ALARM, FLAT = "sound/rem_heart/alarm.wav", "sound/rem_heart/flatline.wav"
local alarm_from, alarm_vol = 60, 0.4
local weak_from, weak_to, weak_min = 80, 99, 0.35

local station, loading, vol = nil, false, 0
local wasStopped
local keepFlat -- ссылка на канал тона: без неё сборщик мусора обрывает звук

local function Exempt(ch)
	if hg.RemAudio and hg.RemAudio.SetExempt then hg.RemAudio.SetExempt(ch) end -- музыку глушим, этот звук - нет
end

hook.Add("Think", "rem_heart_alarm", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local org = ply:Alive() and (ply.new_organism or ply.organism) or nil
	local fib = org and (org.fib or (org.arrhythmia or 0) * 100) or 0
	local stopped = org and org.heartstop or false

	hg.remFibVol = Lerp(math.Clamp((fib - weak_from) / (weak_to - weak_from), 0, 1), 1, weak_min)

	-- тон остановки - по переходу в остановку
	if stopped and wasStopped == false and cvFlat:GetBool() and file.Exists(FLAT, "GAME") then
		sound.PlayFile(FLAT, "noblock", function(ch)
			if not IsValid(ch) then return end
			keepFlat = ch
			Exempt(ch)
			ch:SetVolume(0.5)
			ch:Play()
		end)
	end
	wasStopped = org and stopped or nil

	-- тревога
	local want = (cvAlarm:GetBool() and org and not stopped and not org.otrub and fib > alarm_from) and alarm_vol or 0
	if want > 0 and not IsValid(station) and not loading and file.Exists(ALARM, "GAME") then
		loading = true
		sound.PlayFile(ALARM, "noplay noblock", function(ch)
			loading = false
			if not IsValid(ch) then return end
			station = ch
			Exempt(ch)
			ch:EnableLooping(true)
			ch:SetVolume(0)
			ch:Play()
		end)
	end
	if not IsValid(station) then return end
	vol = math.Approach(vol, want, FrameTime() * 1.5)
	station:SetVolume(vol)
	if want <= 0 and vol <= 0 then
		station:Stop()
		station = nil
	end
end)
