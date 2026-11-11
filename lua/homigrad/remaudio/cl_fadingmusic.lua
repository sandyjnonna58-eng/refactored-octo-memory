-- Музыка при уходе сознания: вся музыка (каналы sound.PlayFile, cl_remaudio.lua) сначала начинает звучать эхом
-- (к каждому треку - отстающие копии того же файла), потом будто издалека: тише, чуть медленнее, эхо гуще;
-- отключился (org.otrub) - сам трек быстро гаснет, последним тает хвост эха - и тишина. Очнулся - всё возвращается.
-- Сила - от org.consciousness (клиенту приходит из sendtable): с C.start начинается, к C.full - полностью.
local RA = hg.RemAudio
if not RA then return end

local C = {
	start = 0.75, full = 0.35,   -- сознание: начало эффекта и полный эффект (отключка - около 0.3)
	echoFrom = 0, farFrom = 0.45, -- с какой силы эффекта эхо и "издалека"
	taps = { -- эхо: задержка (с) и громкость от трека; первые - сразу, остальные - когда "издалека"
		{delay = 0.19, vol = 0.45, far = false},
		{delay = 0.41, vol = 0.32, far = true},
		{delay = 0.68, vol = 0.22, far = true},
	},
	farVolume = 0.3,   -- громкость самого трека "издалека"
	farRate = 0.94,    -- и скорость (чуть ниже и медленнее)
	lostMain = 1.2,    -- отключился: за столько секунд гаснет трек
	lostTail = 3.0,    -- и хвост эха
	wake = 2.5,        -- очнулся: за столько секунд музыка возвращается
	resync = 0.08,     -- эхо разошлось с треком больше чем на столько - подтягиваем
}

local rawSetVolume = FindMetaTable("IGModAudioChannel").RemRawSetVolume
local echoes = setmetatable({}, {__mode = "k"}) -- трек -> {[i] = канал эха}
local loading = setmetatable({}, {__mode = "k"})
local rateSet = setmetatable({}, {__mode = "k"})
local level, lostSince, wakeMul = 0, nil, 1

local function Org()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	return ply.new_organism or ply.organism
end

local function Smooth(x) x = math.Clamp(x, 0, 1) return x * x * (3 - 2 * x) end

local function StopEchoes(chan)
	for _, tap in pairs(echoes[chan] or {}) do
		if IsValid(tap) then tap:Stop() end
	end
	echoes[chan], loading[chan] = nil, nil
	if rateSet[chan] and IsValid(chan) then chan:SetPlaybackRate(1) end
	rateSet[chan] = nil
end

local function SpawnTap(chan, i)
	local path = chan:GetFileName()
	if not path or path == "" or string.find(path, "://", 1, true) then return end -- поток по ссылке не дублируем
	loading[chan] = loading[chan] or {}
	if loading[chan][i] then return end
	loading[chan][i] = true
	sound.RemRawPlayFile(path, "noplay noblock", function(tap)
		if loading[chan] then loading[chan][i] = nil end
		if not IsValid(tap) then return end
		if not IsValid(chan) then tap:Stop() return end
		RA.Taps[tap] = true
		rawSetVolume(tap, 0)
		tap:EnableLooping(chan:IsLooping())
		tap:SetTime(math.max(chan:GetTime() - C.taps[i].delay, 0))
		tap:Play()
		echoes[chan] = echoes[chan] or {}
		echoes[chan][i] = tap
	end)
end

hook.Add("Think", "rem_fadingmusic", function()
	local org = Org()
	local now, dt = CurTime(), FrameTime()

	-- сила эффекта
	local target = 0
	local otrub = org and org.otrub
	if org and not otrub then target = Smooth((C.start - (org.consciousness or 1)) / (C.start - C.full)) end
	if otrub then
		lostSince = lostSince or now
		target = 1
		wakeMul = 0
	else
		if lostSince then lostSince = nil end
		wakeMul = math.Approach(wakeMul, 1, dt / C.wake)
	end
	level = math.Approach(level, target, dt * (target > level and 0.6 or 1.2))

	-- отключился: трек гаснет быстро, эхо - медленнее
	local lostT = lostSince and (now - lostSince) or 0
	local mainLost = lostSince and math.max(1 - lostT / C.lostMain, 0) or 1
	local tailLost = lostSince and math.max(1 - lostT / C.lostTail, 0) or 1

	local far = Smooth((level - C.farFrom) / (1 - C.farFrom))
	RA.Global = Lerp(far, 1, C.farVolume) * mainLost * (lostSince and 1 or wakeMul)
	if not org then RA.Global = 1 end

	for chan, vol in pairs(RA.Channels) do
		if not IsValid(chan) or RA.Taps[chan] or not RA.IsMusic(chan) then continue end
		local playing = chan:GetState() == GMOD_CHANNEL_PLAYING
		if not playing or level < 0.02 or (vol or 0) < 0.01 or not org then
			if echoes[chan] or rateSet[chan] then StopEchoes(chan) end
			continue
		end

		-- чуть медленнее "издалека"
		local rate = Lerp(far, 1, C.farRate)
		if math.abs(rate - 1) > 0.002 or rateSet[chan] then
			chan:SetPlaybackRate(rate)
			rateSet[chan] = true
		end

		-- громкость трека, как её видит слушатель (с приглушением RemAudio, но без нашего множителя)
		local f = (RA.Exempt[chan] or RA.Factor >= 1) and 1 or RA.Factor
		local heard = vol * f
		for i, t in ipairs(C.taps) do
			local want = t.far and far or Smooth(level / 0.4)
			local tap = echoes[chan] and echoes[chan][i]
			if want > 0.01 and not IsValid(tap) then SpawnTap(chan, i) end
			if IsValid(tap) then
				tap:SetPlaybackRate(rate)
				rawSetVolume(tap, heard * t.vol * want * tailLost * (lostSince and 1 or wakeMul))
				-- держим отставание
				local should = chan:GetTime() - t.delay
				if should > 0 and math.abs(tap:GetTime() - should) > C.resync then tap:SetTime(should) end
				if tap:GetState() ~= GMOD_CHANNEL_PLAYING then tap:Play() end
			end
		end
	end

	-- эхо от погасших треков
	for chan in pairs(echoes) do
		if not IsValid(chan) or chan:GetState() ~= GMOD_CHANNEL_PLAYING then StopEchoes(chan) end
	end
end)
