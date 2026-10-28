-- Фон главного меню как в Dying Light: размытый город в закатной дымке (materials/rem_menu/menu_bg_soft.jpg),
-- а в столбах дыма клубы медленно перекатываются: 20 заранее просчитанных кадров (materials/rem_menu/smoke/,
-- генератор - tools/menu_smoke/gen.py) по кругу плавно перетекают друг в друга.
-- Кадры - премультиплицированный RGBA: смешиваем их без провала прозрачности посередине перехода.
hg.MenuSmoke = hg.MenuSmoke or {}
local MS = hg.MenuSmoke

local bgMat = Material("rem_menu/menu_bg_soft.jpg", "smooth")
local FRAMES = 20
local PERIOD = 20 -- секунд на весь цикл (так же в генераторе)
local frames = {}
for i = 1, FRAMES do
	frames[i] = Material(string.format("rem_menu/smoke/smoke_%02d.png", i), "smooth")
end

-- запас по краям под сдвиг от мыши
local OVERSCAN = 1.04

-- кадр дыма с весом k: dst = dst * (1 - a*k) + rgb*k
local function DrawPremultiplied(mat, x, y, w, h, k)
	if k <= 0.002 or mat:IsError() then return end
	surface.SetMaterial(mat)

	render.OverrideBlend(true, BLEND_ZERO, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
	surface.SetDrawColor(255, 255, 255, 255 * k)
	surface.DrawTexturedRect(x, y, w, h)

	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetDrawColor(255 * k, 255 * k, 255 * k, 255)
	surface.DrawTexturedRect(x, y, w, h)

	render.OverrideBlend(false)
end

-- рисует фон с дымом на весь экран; offsetX/offsetY - сдвиг от мыши (параллакс), alpha - прозрачность фона,
-- smokeAlpha - прозрачность дыма (по умолчанию как фон)
function MS.Draw(w, h, offsetX, offsetY, alpha, smokeAlpha)
	alpha = alpha or 255
	local bw, bh = w * OVERSCAN, h * OVERSCAN
	local x0 = (w - bw) * 0.5 - (offsetX or 0)
	local y0 = (h - bh) * 0.5 - (offsetY or 0)

	surface.SetMaterial(bgMat)
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.DrawTexturedRect(x0, y0, bw, bh)

	local mul = (smokeAlpha or alpha) / 255
	local pos = (RealTime() % PERIOD) / PERIOD * FRAMES
	local i = math.floor(pos)
	local f = pos - i
	DrawPremultiplied(frames[i % FRAMES + 1], x0, y0, bw, bh, (1 - f) * mul)
	DrawPremultiplied(frames[(i + 1) % FRAMES + 1], x0, y0, bw, bh, f * mul)
end
