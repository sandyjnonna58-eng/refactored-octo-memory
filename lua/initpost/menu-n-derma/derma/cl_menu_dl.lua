-- Кнопки главного меню в стиле Dying Light (cl_menu_panel.lua): список надписей на наклонённой в перспективе
-- плоскости, слева две тёмные планки с повёрнутыми "MAIN MENU" и "FUNKAS"; под мышью пункт заливается оранжевой
-- плашкой с тёмным жирным текстом и стрелкой.
-- Перспектива - проективная матрица (гомография) в cam.PushModelMatrix; мышь переводится обратно обратной матрицей.
-- Шрифты: Montserrat Medium и Barlow Semi Condensed Bold (OFL, resource/fonts/*-OFL.txt), раздаёт sv_menu_title_font.lua.
hg.DLMenu = hg.DLMenu or {}
local DL = hg.DLMenu

local colText = Color(240, 238, 232, 245)
local colHover = Color(240, 110, 20, 255)
local colHoverText = Color(25, 15, 5, 255)
local colArrow = Color(255, 215, 175, 255)
local colBar = Color(18, 16, 14, 235)
local colSide = Color(240, 150, 30, 255)
local colSideTitle = Color(235, 235, 230, 255)

-- размеры в долях высоты экрана
local LINE = 0.066       -- высота строки
local WIDTH = 0.72       -- ширина плоскости меню
local SIDE = 0.11        -- место под планки слева
local BAR_W, BAR_GAP = 0.042, 0.007
local HOVER_GROW = 6     -- как быстро растёт плашка
-- плоскость на экране: левый край, наклон и перспектива (правый край дальше и выше)
local LEFT = 0.13        -- доля ширины экрана
local TILT = 0.10        -- насколько правый край выше (доля ширины меню)
local FAR = 0.06         -- насколько правый край короче с каждой стороны (доля высоты меню)
local SHEAR = 0.03       -- низ чуть правее верха (доля высоты меню)

local function CreateFonts()
	local sh = ScrH()
	surface.CreateFont("DLMenu_Item", {font = "Montserrat Medium", size = math.floor(sh * 0.05), weight = 500, antialias = true, extended = true})
	surface.CreateFont("DLMenu_ItemHover", {font = "Barlow Semi Condensed", size = math.floor(sh * 0.066), weight = 700, antialias = true, extended = true})
	surface.CreateFont("DLMenu_Side", {font = "Montserrat Medium", size = math.floor(sh * 0.03), weight = 500, antialias = true, extended = true})
	surface.CreateFont("DLMenu_SideTitle", {font = "Barlow Semi Condensed", size = math.floor(sh * 0.05), weight = 700, antialias = true, extended = true})
end
CreateFonts()
hook.Add("OnScreenSizeChanged", "DLMenu_Fonts", CreateFonts)

-- квадрат (0..1, 0..1) -> четырёхугольник p0..p3 (по часовой с левого верхнего), Heckbert
local function SquareToQuad(p)
	local x0, y0, x1, y1, x2, y2, x3, y3 = p[1][1], p[1][2], p[2][1], p[2][2], p[3][1], p[3][2], p[4][1], p[4][2]
	local dx1, dx2, dx3 = x1 - x2, x3 - x2, x0 - x1 + x2 - x3
	local dy1, dy2, dy3 = y1 - y2, y3 - y2, y0 - y1 + y2 - y3
	local den = dx1 * dy2 - dx2 * dy1
	local g = (dx3 * dy2 - dx2 * dy3) / den
	local h = (dx1 * dy3 - dx3 * dy1) / den
	return {
		x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
		y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
		g, h, 1,
	}
end

local function Invert3(m)
	local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
	local A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
	local det = a * A + b * B + c * C
	return {
		A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
		B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
		C / det, -(a * h - b * g) / det, (a * e - b * d) / det,
	}
end

local function Apply(m, x, y)
	local w = m[7] * x + m[8] * y + m[9]
	return (m[1] * x + m[2] * y + m[3]) / w, (m[4] * x + m[5] * y + m[6]) / w
end

-- раскладка: размеры в пикселях меню, матрица меню -> экран и обратная
function DL.Layout(count, offX, offY)
	local sw, sh = ScrW(), ScrH()
	local line, mw = sh * LINE, sh * WIDTH
	local mh = line * count + line * 0.4
	local L, T = sw * LEFT + (offX or 0), sh * 0.5 - mh / 2 + (offY or 0)
	local quad = {
		{L, T},
		{L + mw * 0.93, T - mw * TILT + mh * FAR},
		{L + mw * 0.93 + mh * SHEAR, T + mh - mw * TILT - mh * FAR},
		{L + mh * SHEAR, T + mh},
	}
	local s = SquareToQuad(quad)
	-- из пикселей меню в квадрат: делим на ширину и высоту
	local m = {s[1] / mw, s[2] / mh, s[3], s[4] / mw, s[5] / mh, s[6], s[7] / mw, s[8] / mh, s[9]}

	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(quad) do
		minX, minY = math.min(minX, p[1]), math.min(minY, p[2])
		maxX, maxY = math.max(maxX, p[1]), math.max(maxY, p[2])
	end

	return {
		sh = sh, line = line, mw = mw, mh = mh, m = m, inv = Invert3(m),
		textX = sh * (SIDE + 0.02), barW = sh * BAR_W, barGap = sh * BAR_GAP,
		bounds = {math.floor(minX), math.floor(minY), math.ceil(maxX - minX), math.ceil(maxY - minY)},
	}
end

local function RowTop(lay, i) return lay.line * 0.3 + (i - 1) * lay.line end

local function TextWidth(font, text)
	surface.SetFont(font)
	return (surface.GetTextSize(text))
end

-- какой пункт под точкой экрана (или nil)
function DL.Pick(lay, items, x, y)
	local u, v = Apply(lay.inv, x, y)
	for i, item in ipairs(items) do
		local top = RowTop(lay, i)
		if v >= top and v < top + lay.line then
			local w = math.max(TextWidth("DLMenu_Item", item.text), TextWidth("DLMenu_ItemHover", item.text) * item.hover)
			if u >= lay.textX - lay.line * 0.3 and u <= lay.textX + w + lay.line * 1.2 then return i end
		end
	end
end

function DL.UpdateHover(items, hovered, dt)
	for i, item in ipairs(items) do
		item.hover = math.Approach(item.hover or 0, i == hovered and 1 or 0, dt * HOVER_GROW)
	end
end

local function ToMatrix(m)
	local mat = Matrix()
	mat:SetUnpacked(
		m[1], m[2], 0, m[3],
		m[4], m[5], 0, m[6],
		0, 0, 1, 0,
		m[7], m[8], 0, m[9]
	)
	return mat
end

local poly4 = {{}, {}, {}, {}}
local function Quad(x1, y1, x2, y2, x3, y3, x4, y4)
	poly4[1].x, poly4[1].y = x1, y1
	poly4[2].x, poly4[2].y = x2, y2
	poly4[3].x, poly4[3].y = x3, y3
	poly4[4].x, poly4[4].y = x4, y4
	surface.DrawPoly(poly4)
end

-- стрелка ">" из двух плеч
local function Chevron(x, y, s, t)
	Quad(x, y - s, x + t, y - s, x + s + t, y, x + s, y)
	Quad(x + s, y, x + s + t, y, x + t, y + s, x, y + s)
end

local function VerticalText(base, text, font, col, x, y)
	local mat = Matrix()
	mat:Translate(Vector(x, y, 0))
	mat:Rotate(Angle(0, 90, 0))
	cam.PushModelMatrix(base * mat)
		draw.SimpleText(text, font, 0, 0, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	cam.PopModelMatrix()
end

-- items: {text = "SETTINGS", hover = 0..1}, сверху вниз; alpha 0..255
function DL.Draw(lay, items, alpha)
	local mul = alpha / 255
	local line, bw, gap = lay.line, lay.barW, lay.barGap
	local base = ToMatrix(lay.m)

	cam.PushModelMatrix(base)
		draw.NoTexture()
		-- две тёмные планки слева
		surface.SetDrawColor(colBar.r, colBar.g, colBar.b, colBar.a * mul)
		surface.DrawRect(0, line * 0.6, bw, lay.mh - line * 0.6)
		surface.DrawRect(bw + gap, line * 0.3, bw, lay.mh - line * 0.5)
	cam.PopModelMatrix()

	VerticalText(base, "< MAIN MENU", "DLMenu_Side", ColorAlpha(colSide, colSide.a * mul), bw * 0.88, line * 1.4)
	VerticalText(base, "FUNKAS", "DLMenu_SideTitle", ColorAlpha(colSideTitle, colSideTitle.a * mul), bw * 2 + gap - bw * 0.05, line * 0.9)

	cam.PushModelMatrix(base)
		local x = lay.textX
		for i, item in ipairs(items) do
			local top = RowTop(lay, i)
			local cy = top + line * 0.5
			local k = item.hover or 0

			if k > 0.01 then
				-- оранжевая плашка вырастает слева направо
				local tw = TextWidth("DLMenu_ItemHover", item.text)
				local full = tw + line * 1.1
				local w = full * math.ease.OutCubic(k)
				draw.NoTexture()
				surface.SetDrawColor(colHover.r, colHover.g, colHover.b, colHover.a * mul)
				Quad(x - line * 0.18, top + line * 0.03, x - line * 0.18 + w, top - line * 0.03, x - line * 0.18 + w, top + line * 0.94, x - line * 0.18, top + line)
			end

			if k > 0.35 then
				draw.SimpleText(item.text, "DLMenu_ItemHover", x, cy, ColorAlpha(colHoverText, colHoverText.a * mul), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				local tw = TextWidth("DLMenu_ItemHover", item.text)
				draw.NoTexture()
				surface.SetDrawColor(colArrow.r, colArrow.g, colArrow.b, colArrow.a * mul * math.Clamp((k - 0.35) / 0.65, 0, 1))
				Chevron(x + tw + line * 0.38, cy, line * 0.2, line * 0.07)
			else
				draw.SimpleText(item.text, "DLMenu_Item", x, cy, ColorAlpha(colText, colText.a * mul), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
		end
	cam.PopModelMatrix()
end
