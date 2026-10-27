-- Экран умирания "вихрь" (таймер смерти, sv_vortexdeath.lua) под песню rem_death_cfyt.ogg:
-- чёрный экран, по одному проступают красные "!!!", ниже "Give up"; потом из темноты поднимается красный
-- пиксельный шум, тёмные спиральные рукава закручиваются к тёмному центру и со временем распрямляются в лучи.
-- Пока он идёт, остальная музыка затихает (hg.RemAudio); прыжок - "Give up", сдаться и умереть сразу.
hg.VortexDeath = hg.VortexDeath or {}
local DV = hg.VortexDeath

local SONG = "sound/rem_death_cfyt.ogg"
local FADE_IN, FADE_OUT = 0.6, 1.5

local RAMP_START, RAMP_TIME = 9, 48 -- когда начинает проступать красный и за сколько доходит до максимума
local MARKS_DOT = {0.4, 0.9, 1.4}    -- когда появляются точки
local MARKS_BANG = {1.2, 2.6, 4.0}   -- когда точка становится "!"
local GIVEUP_TIME = 7
local SWIRL_SPIN, RAYS_SPIN = 7, 4   -- градусов в секунду
local NOISE_FPS = 20

local matSwirl = Material("rem_death/vortex_swirl.png", "smooth")
local matRays = Material("rem_death/vortex_rays.png", "smooth")
local matCentre = Material("rem_death/vortex_centre.png", "smooth")
local matNoise = {}
for i = 1, 4 do
	matNoise[i] = Material("rem_death/vortex_noise" .. i .. ".png") -- без smooth: крупные пиксели
end

local function CreateFonts()
	local sh = ScrH()
	surface.CreateFont("DeathVortex_Marks", {font = "VT323", size = math.floor(sh * 0.17), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_GiveUp", {font = "VT323", size = math.floor(sh * 0.075), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_Key", {font = "VT323", size = math.floor(sh * 0.035), weight = 400, antialias = false, extended = true})
end
CreateFonts()
hook.Add("OnScreenSizeChanged", "DeathVortex_Fonts", CreateFonts)

local function smooth(a)
	a = math.Clamp(a, 0, 1)
	return a * a * (3 - 2 * a)
end

-- текстура, повёрнутая внутри неповёрнутого прямоугольника (эллипс остаётся горизонтальным)
local poly = {{}, {}, {}, {}}
local corners = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}
local function DrawSpun(mat, cx, cy, w, h, ang, a, zoom)
	local c, s = math.cos(math.rad(ang)), math.sin(math.rad(ang))
	for i = 1, 4 do
		local dx, dy = corners[i][1], corners[i][2]
		local p = poly[i]
		p.x, p.y = cx + dx * w, cy + dy * h
		p.u = 0.5 + (dx * c - dy * s) * zoom
		p.v = 0.5 + (dx * s + dy * c) * zoom
	end
	surface.SetMaterial(mat)
	surface.SetDrawColor(255, 255, 255, a)
	surface.DrawPoly(poly)
end

-- t - секунды с начала звука; alpha 0..255 - общая прозрачность (затухание в конце); skipKey - подпись клавиши пропуска
function DV.Draw(t, alpha, skipKey)
	local sw, sh = ScrW(), ScrH()
	local mul = alpha / 255
	local k = smooth((t - RAMP_START) / RAMP_TIME)

	surface.SetDrawColor(math.floor(150 * k), 0, 0, alpha)
	surface.DrawRect(0, 0, sw, sh)

	if k > 0 then
		-- красный шум
		surface.SetMaterial(matNoise[math.floor(t * NOISE_FPS) % 4 + 1])
		surface.SetDrawColor(math.floor(255 * (0.75 + 0.25 * k)), 25, 25, math.floor(255 * k * mul))
		surface.DrawTexturedRect(0, 0, sw, sh)

		-- рукава: сначала закрученные, потом прямые лучи
		local size = math.max(sw, sh) * (1.55 - 0.15 * k)
		local rays = smooth((k - 0.35) / 0.55)
		local armsAlpha = math.min(1, k * 3) * mul
		if rays < 1 then DrawSpun(matSwirl, sw / 2, sh / 2, size, size * 0.72, t * SWIRL_SPIN, 242 * (1 - rays) * armsAlpha, 0.72) end
		if rays > 0 then DrawSpun(matRays, sw / 2, sh / 2, size, size * 0.72, t * RAYS_SPIN, 230 * rays * armsAlpha, 0.72) end

		-- тёмный центр сжимается
		local cw = sw * (1.25 - 0.55 * k)
		surface.SetMaterial(matCentre)
		surface.SetDrawColor(255, 255, 255, math.floor(242 * math.min(1, k * 4) * mul))
		surface.DrawTexturedRect(sw / 2 - cw / 2, sh / 2 - cw * 0.25, cw, cw * 0.5)
	end

	-- "!!!": сначала точки, потом по одному восклицательные знаки
	local marks = {}
	for i = 1, 3 do
		marks[i] = t >= MARKS_BANG[i] and "!" or (t >= MARKS_DOT[i] and "." or " ")
	end
	draw.SimpleText(table.concat(marks, " "), "DeathVortex_Marks", sw / 2, sh * 0.5, Color(225, 20, 20, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	if t >= GIVEUP_TIME then
		local a = math.floor(255 * math.min(1, (t - GIVEUP_TIME) / 1.5) * mul)
		local col = Color(200, 20, 20, a)
		-- на ярко-красном фоне надпись получает тёмную обводку, как в оригинале
		if k > 0.5 then
			draw.SimpleTextOutlined("Give up", "DeathVortex_GiveUp", sw / 2, sh * 0.78, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(40, 0, 0, a))
		else
			draw.SimpleText("Give up", "DeathVortex_GiveUp", sw / 2, sh * 0.78, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		if skipKey then
			draw.SimpleText("[" .. skipKey .. "]", "DeathVortex_Key", sw / 2, sh * 0.78 + sh * 0.055, Color(170, 20, 20, math.floor(a * 0.7)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

local MusicVolume = GetConVar("snd_musicvolume")
local station, loading
local volume, visible = 0, 0

function DV.Active()
	local ply = LocalPlayer()
	return IsValid(ply) and ply:Alive() and ply:GetNWFloat("rem_vortex_until", 0) > CurTime()
end

local function JumpKeyName()
	local key = input.LookupBinding("+jump")
	return key and string.upper(key) or "SPACE"
end

hook.Add("Think", "rem_vortexdeath", function()
	local active = DV.Active()
	local dt = FrameTime()

	if active and not IsValid(station) and not loading then
		loading = true
		sound.PlayFile(SONG, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then return end
			if not DV.Active() then chan:Stop() return end

			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			-- песня идёт с начала таймера: догоняем, если звук загрузился с опозданием
			local late = CurTime() - LocalPlayer():GetNWFloat("rem_vortex_start", CurTime())
			if late > 0.5 then chan:SetTime(late) end
			volume = 1
			chan:SetVolume(MusicVolume:GetFloat())
			chan:Play()
		end)
	end

	visible = math.Approach(visible, active and 1 or 0, dt / (active and FADE_IN or FADE_OUT))
	if hg.RemAudio then hg.RemAudio.Duck("vortexdeath", active and 0 or nil) end

	if not IsValid(station) then return end
	volume = math.Approach(volume, active and 1 or 0, dt / FADE_OUT)
	if volume <= 0 and not active then
		station:Stop()
		station = nil
		return
	end
	station:SetVolume(volume * MusicVolume:GetFloat())
end)

hook.Add("Post Post Pre Post Processing", "rem_vortexdeath", function()
	if visible <= 0 then return end
	local t = CurTime() - LocalPlayer():GetNWFloat("rem_vortex_start", CurTime())
	DV.Draw(t, math.floor(255 * visible), DV.Active() and JumpKeyName() or nil)
end)

-- "Give up": прыжок во время вихря - сдаться
local nextGiveUp = 0
hook.Add("PlayerBindPress", "rem_vortexdeath", function(ply, bind, pressed)
	if not pressed or not DV.Active() or not string.find(bind, "+jump", 1, true) then return end
	if CurTime() - ply:GetNWFloat("rem_vortex_start", 0) < GIVEUP_TIME then return true end -- надпись ещё не появилась
	if nextGiveUp > CurTime() then return true end
	nextGiveUp = CurTime() + 1
	net.Start("rem_vortexdeath_giveup")
	net.SendToServer()
	return true
end)
