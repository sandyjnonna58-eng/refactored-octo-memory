-- Музыка критического состояния: rem_letitgo.mp3, пока крови мало или не хватает кислорода.
-- Включается еле слышно и нарастает до 100%; чем хуже состояние, тем быстрее.
local music_path = "sound/rem_letitgo.mp3"

-- кровь в мл (норма 5000) и кислород (норма 30)
local blood_critical = 3900
local blood_worst = 2600
local o2_critical = 12
local o2_worst = 4

local start_volume = 0.05
-- за сколько секунд громкость доходит до 100% при только-только критическом состоянии
local ramp_time = 60
local fade_out_time = 4

local MusicVolume = GetConVar("snd_musicvolume")

local station
local loading = false
local volume = 0
local wantPlay = false

local function Remap01(value, from, to)
	return math.Clamp((value - from) / (to - from), 0, 1)
end

-- 0 - не критично, (0..1] - насколько плохо
local function Severity(org)
	local blood = org.blood or 5000
	local o2 = istable(org.o2) and org.o2[1] or 30

	if blood > blood_critical and o2 > o2_critical then return 0 end

	return math.max(Remap01(blood, blood_critical, blood_worst), Remap01(o2, o2_critical, o2_worst), 0.001)
end

local function Stop()
	if IsValid(station) then station:Stop() end
	station = nil
	volume = 0
end

local function Start()
	if loading or IsValid(station) then return end
	loading = true

	sound.PlayFile(music_path, "noblock noplay", function(chan)
		loading = false
		if not IsValid(chan) then return end

		-- пока грузилось, всё могло закончиться
		if not wantPlay then chan:Stop() return end

		station = chan
		volume = start_volume
		chan:EnableLooping(true)
		chan:SetVolume(volume * MusicVolume:GetFloat())
		chan:Play()
	end)
end

hook.Add("Think", "rem_critmusic", function()
	local ply = LocalPlayer()
	local org = IsValid(ply) and ply:Alive() and (ply.new_organism or ply.organism)
	local lastBattle = hg.LastBattle and hg.LastBattle.IsActive and hg.LastBattle.IsActive()
	local severity = (org and not lastBattle) and Severity(org) or 0

	wantPlay = severity > 0
	local dt = FrameTime()

	if wantPlay then
		Start()
		if not IsValid(station) then return end

		-- от еле слышно до 100%: базовая скорость + быстрее, если состояние тяжелее
		volume = math.min(volume + dt * (1 - start_volume) / ramp_time * (1 + severity * 3), 1)
	else
		if not IsValid(station) then return end

		volume = volume - dt / fade_out_time
		if volume <= 0 then Stop() return end
	end

	station:SetVolume(volume * MusicVolume:GetFloat())
end)
