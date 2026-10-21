local MODE = MODE

MODE.name = "turfwar"

local MusicVolume = GetConVar("snd_musicvolume")

-- после конца раунда музыка затихает за столько секунд
local music_fade_time = 4

local variant
local ended

local teams = {
	[0] = {name = "a Bloodz Member", objective = "Take the turf from Groove", color = Color(180, 0, 0)},
	[1] = {name = "a Groove Member", objective = "Take the turf from Bloodz", color = Color(0, 180, 0)},
}

local variantColors = {
	[1] = Color(255, 170, 60),
	[2] = Color(0, 162, 255),
}

local function StopMusic()
	if IsValid(TURFWAR_Station) then TURFWAR_Station:Stop() end
	TURFWAR_Station = nil
end

net.Receive("turfwar_start", function()
	variant = net.ReadUInt(2)
	ended = nil
	zb.RemoveFade()
	StopMusic()

	sound.PlayFile("sound/rem_turfwarost.mp3", "noblock", function(station)
		if not IsValid(station) then return end

		StopMusic()
		TURFWAR_Station = station
		station:EnableLooping(true)
		station:SetVolume(MusicVolume:GetFloat())
		station:Play()
	end)
end)

net.Receive("turfwar_end", function()
	ended = CurTime()
end)

surface.CreateFont("TurfWar_Timer", {
	font = "Courier Prime",
	size = ScreenScale(12),
	extended = true,
	weight = 650,
	antialias = true,
})

function MODE:RenderScreenspaceEffects()
	if zb.ROUND_START + 7.5 < CurTime() then return end
	local fade = math.Clamp(zb.ROUND_START + 7.5 - CurTime(), 0, 1)
	surface.SetDrawColor(0, 0, 0, 255 * fade)
	surface.DrawRect(-1, -1, ScrW() + 1, ScrH() + 1)
end

local function UpdateMusic()
	if not IsValid(TURFWAR_Station) then return end

	local volume = MusicVolume:GetFloat()
	if ended then
		volume = volume * math.Clamp(1 - (CurTime() - ended) / music_fade_time, 0, 1)
		if volume <= 0 then StopMusic() return end
	end

	TURFWAR_Station:SetVolume(volume)
end

function MODE:HUDPaint()
	UpdateMusic()

	local start = zb.ROUND_START or CurTime()
	local current = variant or GetGlobalInt("turfwar_variant", 0)

	if not ended and start + 8.5 < CurTime() then
		local left = math.max(start + (zb.ROUND_TIME or 240) - CurTime(), 0)
		draw.SimpleText(string.FormattedTime(left, "%02i:%02i:%02i"), "TurfWar_Timer", sw * 0.5, sh * 0.05, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	if start + 8.5 < CurTime() then return end
	if not lply:Alive() then return end

	zb.RemoveFade()
	local fade = math.Clamp(start + 8 - CurTime(), 0, 1)
	local info = teams[lply:Team()]

	local variantColor = variantColors[current] or color_white
	draw.SimpleText("ZBattle | Turf War: " .. (self.VariantNames[current] or "?"), "ZB_HomicideMediumLarge", sw * 0.5, sh * 0.1, ColorAlpha(variantColor, 255 * fade), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	if not info then return end
	draw.SimpleText("You are " .. info.name, "ZB_HomicideMediumLarge", sw * 0.5, sh * 0.5, ColorAlpha(info.color, 255 * fade), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(current == self.VARIANT_MELEE and info.objective .. ". No guns - only what you hold." or info.objective .. ".", "ZB_HomicideMedium", sw * 0.5, sh * 0.9, ColorAlpha(info.color, 255 * fade), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function MODE:RoundStart()
	-- раунд сменился, а музыка от прошлого ещё играет
	if ended then StopMusic() end
end
