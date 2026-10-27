-- Экран смерти "вихрь" (идёт в паре со звуком rem_death_cfyt.ogg, см. cl_cdeath.lua):
-- чёрный экран, по одному проступают красные "!!!", ниже "Give up"; потом из темноты поднимается красный
-- пиксельный шум, тёмные спиральные рукава закручиваются к тёмному центру и со временем распрямляются в лучи.
DeathVortex = DeathVortex or {}
local DV = DeathVortex

DV.Duration = 82 -- сколько длится экран (звук ~85 с)
DV.FadeOut = 2

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
