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

local meta = FindMetaTable("IGModAudioChannel")
meta.RemRawSetVolume = meta.RemRawSetVolume or meta.SetVolume
local rawSetVolume = meta.RemRawSetVolume

function meta:SetVolume(vol)
	RA.Channels[self] = vol
	rawSetVolume(self, (RA.Exempt[self] or RA.Factor >= 1) and vol or vol * RA.Factor)
end

local function Track(play)
	return function(path, flags, callback, ...)
		return play(path, flags, function(chan, ...)
			if IsValid(chan) and RA.Channels[chan] == nil then RA.Channels[chan] = 1 end
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
	if RA.Factor >= 1 and old >= 1 then return end

	for chan, vol in pairs(RA.Channels) do
		if not RA.Exempt[chan] and IsValid(chan) then rawSetVolume(chan, vol * RA.Factor) end
	end
end)
