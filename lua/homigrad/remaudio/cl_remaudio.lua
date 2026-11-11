-- Общая "заглушка" музыки: модуль может попросить приглушить всю остальную музыку (каналы sound.PlayFile/PlayURL
-- любых модулей) до доли громкости, а свой канал пометить как исключение. Громкость возвращается сама,
-- когда никто больше не просит. Используют последние моменты и голоса.
hg.RemAudio = hg.RemAudio or {}
local RA = hg.RemAudio

local duck_fade = 1.5

RA.Channels = RA.Channels or setmetatable({}, {__mode = "k"}) -- канал -> громкость, которую он себе просил
RA.Exempt = RA.Exempt or setmetatable({}, {__mode = "k"})
RA.Requests = RA.Requests or {}
RA.Factor = RA.Factor or 1
RA.Global = RA.Global or 1 -- общий множитель для ВСЕХ каналов, и особых тоже (уход сознания, cl_remaudio_fading.lua)
RA.Taps = RA.Taps or setmetatable({}, {__mode = "k"}) -- каналы-эхо: их громкость ставит cl_remaudio_fading.lua сам

local meta = FindMetaTable("IGModAudioChannel")
meta.RemRawSetVolume = meta.RemRawSetVolume or meta.SetVolume
local rawSetVolume = meta.RemRawSetVolume

-- Музыка ли это: на неё действует уход сознания (cl_remaudio_fading.lua - эхо, "издалека", тишина в отключке).
-- Только явный список: раньше "музыкой" считалось всё, кроме .wav, и эхо удваивало звуки - инсульт (rem_lobotomy),
-- звон в ушах, судороги, хрипы, двигатели машин; а фоновая музыка режима (.wav-слои zcity_ost) как раз не попадала.
-- Песни экрана смерти и последних моментов сюда не входят: они звучат, когда ты уже без сознания.
RA.MusicPatterns = {
	"sound/zcity_ost/", "sound/zc_dyna_music/",        -- фоновая музыка режима (dynamic_music_v2, dynmusic)
	"rem_letitgo", "rem_rage/", "rem_panic/",           -- критическое состояние, ярость, паника
	"rem_excruciatingpain", "rem_despair", "rem_pain.mp3", "rem_aftermath", -- боль, отчаяние, суицид
	"rem_laststand", "rem_lastbattle", "zbattle/pharmacia", -- последний бой, берсерк
}
local musicCache = setmetatable({}, {__mode = "k"})
function RA.IsMusic(chan)
	local v = musicCache[chan]
	if v ~= nil then return v end
	local name = string.lower(chan:GetFileName() or "")
	v = false
	for _, s in ipairs(RA.MusicPatterns) do
		if string.find(name, s, 1, true) then v = true break end
	end
	musicCache[chan] = v
	return v
end

local function Apply(chan, vol)
	local f = (RA.Exempt[chan] or RA.Factor >= 1) and 1 or RA.Factor
	local g = (RA.Global < 1 and RA.IsMusic(chan)) and RA.Global or 1
	rawSetVolume(chan, vol * f * g)
end
RA.Apply = Apply

function meta:SetVolume(vol)
	if RA.Taps[self] then rawSetVolume(self, vol) return end
	RA.Channels[self] = vol
	Apply(self, vol)
end

local function Track(play)
	return function(path, flags, callback, ...)
		return play(path, flags, function(chan, ...)
			if IsValid(chan) and RA.Channels[chan] == nil and not RA.Taps[chan] then RA.Channels[chan] = 1 end
			if callback then return callback(chan, ...) end
		end, ...)
	end
end

sound.RemRawPlayFile = sound.RemRawPlayFile or sound.PlayFile
sound.RemRawPlayURL = sound.RemRawPlayURL or sound.PlayURL
sound.PlayFile = Track(sound.RemRawPlayFile)
sound.PlayURL = Track(sound.RemRawPlayURL)

-- factor 0..1 - до какой доли глушить остальное; nil или 1 - снять просьбу
function RA.Duck(id, factor)
	RA.Requests[id] = (factor and factor < 1) and factor or nil
end

-- этот канал не глушится (своя музыка того, кто просит)
function RA.SetExempt(chan)
	if IsValid(chan) then RA.Exempt[chan] = true end
end

hook.Add("Think", "rem_audio_duck", function()
	local target = 1
	for _, factor in pairs(RA.Requests) do target = math.min(target, factor) end

	local old = RA.Factor
	RA.Factor = math.Approach(RA.Factor, target, FrameTime() / duck_fade)
	if RA.Factor >= 1 and old >= 1 and RA.Global >= 1 and not RA.GlobalDirty then return end
	RA.GlobalDirty = RA.Global < 1

	for chan, vol in pairs(RA.Channels) do
		if IsValid(chan) then Apply(chan, vol) end
	end
end)
