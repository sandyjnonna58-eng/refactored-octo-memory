-- Главное меню в стиле хакерского терминала (как меню Watch Dogs 2), рисует cl_menu_panel.lua:
-- * при первом открытии за сессию - загрузка (строки терминала + предупреждение) и экран входа с логотипом FUNKAS;
-- * фон: сцены сменяют друг друга со сбоями картинки - точечные картинки (materials/rem_wd/, генератор
--   tools/menu_wd/gen.py), живая камера по карте вокруг игрока и "воспоминания" (скриншоты hg.screens);
-- * слева внизу список пунктов, выбранный - синяя плашка с "//"; справа внизу карусель карточек со стрелками,
--   точками и кнопкой ACCESS; слева сверху аватар и ник.
hg.WDMenu = hg.WDMenu or {}
local WD = hg.WDMenu

local colBlue = Color(0, 0, 255)
local colText = Color(225, 225, 225)
local colDim = Color(150, 150, 150)
local colBox = Color(22, 22, 22, 215)
local colPanel = Color(12, 12, 12, 225)
local colGreen = Color(60, 230, 60)

local SCENE_TIME = 9     -- секунд на сцену
local GLITCH_TIME = 0.6  -- сбой при смене сцены
local CARD_TIME = 8      -- карточки листаются сами

local scenes = {
	{kind = "image", mat = Material("rem_wd/scene_rings.png", "smooth")},
	{kind = "live"},
	{kind = "image", mat = Material("rem_wd/scene_city.png", "smooth")},
	{kind = "memory"},
	{kind = "image", mat = Material("rem_wd/scene_skulls.png", "smooth")},
	{kind = "live", yaw = 140},
}
local matLogo = Material("rem_wd/logo.png", "smooth")
local matNoise = {}
for i = 1, 4 do matNoise[i] = Material("rem_death/vortex_static" .. i .. ".png") end

local function CreateFonts()
	local sh = ScrH()
	local function mono(name, size, font)
		surface.CreateFont(name, {font = font or "Share Tech Mono", size = math.floor(sh * size), weight = 400, antialias = true, extended = true})
	end
	mono("WD_Item", 0.026)
	mono("WD_Title", 0.025)
	mono("WD_Text", 0.0195)
	mono("WD_Small", 0.017)
	mono("WD_Boot", 0.022, "VT323")
	mono("WD_Login", 0.022)
end
CreateFonts()
hook.Add("OnScreenSizeChanged", "WDMenu_Fonts", CreateFonts)

local function TextW(font, text)
	surface.SetFont(font)
	return (surface.GetTextSize(text))
end

-- ===================== фон =====================

local function DrawImageScene(mat, w, h, st)
	if mat:IsError() then return end
	local zoom = 1 + 0.05 * st / SCENE_TIME
	local iw, ih = w * zoom, h * zoom
	surface.SetMaterial(mat)
	surface.SetDrawColor(115, 115, 115, 255)
	surface.DrawTexturedRect((w - iw) / 2, (h - ih) / 2, iw, ih)
end

local liveView = {drawhud = false, drawviewmodel = false, dopostprocess = false, drawmonitors = false}
local function DrawLiveScene(scene, w, h, st)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	-- медленный облёт вокруг игрока, как съёмка с плеча
	scene.baseYaw = scene.baseYaw or ply:EyeAngles().y -- начинаем оттуда, куда смотрит игрок
	local yaw = (scene.yaw or 0) + st * 5 + scene.baseYaw
	local ang = Angle(8, yaw, 0)
	liveView.origin = ply:EyePos() - ang:Forward() * (70 + st * 6) + Vector(0, 0, 14)
	liveView.angles = ang
	liveView.x, liveView.y, liveView.w, liveView.h = 0, 0, w, h
	liveView.fov = 62
	render.RenderView(liveView)

	surface.SetDrawColor(0, 0, 0, 120)
	surface.DrawRect(0, 0, w, h)
	surface.SetMaterial(matNoise[math.floor(RealTime() * 18) % 4 + 1])
	surface.SetDrawColor(255, 255, 255, 22)
	surface.DrawTexturedRect(0, 0, w, h)
end

local function DrawMemoryScene(w, h, st, index)
	local list = {}
	for _, mat in ipairs(hg.screens or {}) do
		if mat and not mat:IsError() then list[#list + 1] = mat end
	end
	if #list == 0 then return false end
	DrawImageScene(list[index % #list + 1], w, h, st)
	return true
end

local function DrawScene(i, w, h, st)
	local scene = scenes[(i - 1) % #scenes + 1]
	if scene.kind == "image" then
		DrawImageScene(scene.mat, w, h, st)
	elseif scene.kind == "live" then
		DrawLiveScene(scene, w, h, st)
	elseif scene.kind == "memory" then
		if not DrawMemoryScene(w, h, st, i) then DrawImageScene(scenes[1].mat, w, h, st) end
	end
end

-- сбой: экран режется на полосы, полосы съезжают и мигают синим/белым
local function DrawGlitch(w, h, k, seed)
	local strips = 14
	local sh = h / strips
	local step = math.floor(RealTime() * 30)
	for s = 0, strips - 1 do
		local r = util.SharedRandom("wdglitch", 0, 1, seed * 131 + step * 17 + s)
		if r < 0.55 * k then
			local off = (util.SharedRandom("wdglitchx", -1, 1, seed * 7 + step * 3 + s)) * w * 0.08 * k
			surface.SetDrawColor(0, 0, 0, 230)
			surface.DrawRect(0, s * sh, w, sh)
			local c = r < 0.15 * k and colBlue or Color(255, 255, 255, 40)
			surface.SetDrawColor(c.r, c.g, c.b, (c.a or 255) * 0.35 * k)
			surface.DrawRect(off, s * sh + sh * 0.3, w * 0.6, sh * 0.25)
		end
	end
end

function WD.DrawBackground(w, h)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, w, h)

	local t = RealTime()
	local i = math.floor(t / SCENE_TIME)
	local st = t - i * SCENE_TIME
	DrawScene(i + 1, w, h, st)

	if st < GLITCH_TIME then
		local k = 1 - st / GLITCH_TIME
		-- в начале сбоя мелькает прошлая сцена
		if util.SharedRandom("wdflash", 0, 1, math.floor(RealTime() * 20)) < 0.4 * k then
			DrawScene(i, w, h, SCENE_TIME)
		end
		DrawGlitch(w, h, k, i)
	end
end

-- ===================== список =====================

-- items: {text = "Settings"}; selected - индекс; возвращает прямоугольники для мыши
function WD.DrawList(items, selected, alpha)
	local sw, sh = ScrW(), ScrH()
	local mul = alpha / 255
	local lineH, gap = sh * 0.04, sh * 0.0065
	local x = sh * 0.03
	local y = sh * 0.93 - #items * (lineH + gap)
	local padX = sh * 0.008
	local rects = {}
	surface.SetFont("WD_Item")
	for i, item in ipairs(items) do
		local sel = i == selected
		local text = sel and ("// " .. item.text) or item.text
		local tw = TextW("WD_Item", text)
		-- тёмная плашка у невыбранных тянется чуть дальше текста, синяя - ровно по тексту
		local bw = tw + padX * 2 + (sel and 0 or sh * 0.05)
		if sel then
			surface.SetDrawColor(colBlue.r, colBlue.g, colBlue.b, 255 * mul)
		else
			surface.SetDrawColor(colBox.r, colBox.g, colBox.b, colBox.a * mul)
		end
		surface.DrawRect(x, y, bw, lineH)
		draw.SimpleText(text, "WD_Item", x + padX, y + lineH / 2, ColorAlpha(sel and color_white or colText, 255 * mul), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		rects[i] = {x, y, bw, lineH}
		y = y + lineH + gap
	end
	return rects
end

-- ===================== карусель =====================

local function Wrap(text, font, maxW)
	local lines, line = {}, ""
	for word in string.gmatch(text, "%S+") do
		local try = line == "" and word or (line .. " " .. word)
		if TextW(font, try) > maxW and line ~= "" then
			lines[#lines + 1] = line
			line = word
		else
			line = try
		end
	end
	if line ~= "" then lines[#lines + 1] = line end
	return lines
end

local function Triangle(cx, cy, s, dir)
	draw.NoTexture()
	if dir > 0 then
		surface.DrawPoly({{x = cx - s * 0.5, y = cy - s * 0.6}, {x = cx + s * 0.6, y = cy}, {x = cx - s * 0.5, y = cy + s * 0.6}})
	else
		surface.DrawPoly({{x = cx + s * 0.5, y = cy - s * 0.6}, {x = cx + s * 0.5, y = cy + s * 0.6}, {x = cx - s * 0.6, y = cy}})
	end
end

-- cards: {title, text, mat, badge}; возвращает зоны кнопок {prev, next, access, dots}
function WD.DrawCarousel(cards, index, alpha, hover)
	local sw, sh = ScrW(), ScrH()
	local mul = alpha / 255
	local card = cards[index]
	local x0, y0, x1, y1 = sw * 0.375, sh * 0.63, sw * 0.95, sh * 0.91
	local zones = {}

	surface.SetDrawColor(colPanel.r, colPanel.g, colPanel.b, colPanel.a * mul)
	surface.DrawRect(x0, y0, x1 - x0, y1 - y0)

	-- картинка с белым значком
	local ix, iy, iw, ih = sw * 0.387, sh * 0.652, sw * 0.265, sh * 0.2
	if card.mat and not card.mat:IsError() then
		surface.SetMaterial(card.mat)
		surface.SetDrawColor(255, 255, 255, 255 * mul)
		surface.DrawTexturedRect(ix, iy, iw, ih)
	end
	surface.SetDrawColor(255, 255, 255, 40 * mul)
	surface.DrawOutlinedRect(ix, iy, iw, ih, 1)
	if card.badge then
		local r = ih * 0.28
		local cx, cy = ix + iw - r * 1.4, iy + ih * 0.32
		draw.NoTexture()
		surface.SetDrawColor(255, 255, 255, 255 * mul)
		local poly = {}
		for k = 0, 23 do
			local a = math.rad(k * 15)
			poly[#poly + 1] = {x = cx + math.cos(a) * r, y = cy + math.sin(a) * r}
		end
		surface.DrawPoly(poly)
		draw.SimpleText(card.badge, "WD_Title", cx, cy, Color(10, 10, 10, 255 * mul), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	-- заголовок и текст
	local tx = sw * 0.663
	draw.SimpleText(string.upper(card.title), "WD_Title", tx, sh * 0.66, ColorAlpha(color_white, 255 * mul), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	local ty = sh * 0.705
	for _, line in ipairs(Wrap(card.text, "WD_Text", x1 - tx - sw * 0.012)) do
		draw.SimpleText(line, "WD_Text", tx, ty, ColorAlpha(colText, 235 * mul), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		ty = ty + sh * 0.0205
	end

	-- стрелки и точки
	local by, bs = sh * 0.885, sh * 0.028
	local function button(name, cx, dir)
		local hot = hover == name
		surface.SetDrawColor(255, 255, 255, (hot and 255 or 225) * mul)
		surface.DrawRect(cx - bs * 0.7, by - bs * 0.5, bs * 1.4, bs)
		surface.SetDrawColor(0, 0, 0, 255 * mul)
		Triangle(cx, by, bs * 0.55, dir)
		zones[name] = {cx - bs * 0.7, by - bs * 0.5, bs * 1.4, bs}
	end
	button("prev", sw * 0.452, -1)
	button("next", sw * 0.582, 1)
	local n = #cards
	for k = 1, n do
		local cx = sw * 0.482 + (k - 1) * (sw * 0.07 / math.max(n - 1, 1))
		local r = sh * 0.0055
		draw.NoTexture()
		local poly = {}
		for s = 0, 15 do
			local a = math.rad(s * 22.5)
			poly[#poly + 1] = {x = cx + math.cos(a) * r, y = by + math.sin(a) * r}
		end
		if k == index then
			surface.SetDrawColor(255, 255, 255, 255 * mul)
			surface.DrawPoly(poly)
		else
			surface.DrawCircle(cx, by, r, 255, 255, 255, 200 * mul)
		end
	end

	-- ACCESS
	local ax, aw = sw * 0.662, sw * 0.076
	local hot = hover == "access"
	surface.SetDrawColor(hot and colBlue.r or 255, hot and colBlue.g or 255, hot and colBlue.b or 255, 255 * mul)
	surface.DrawRect(ax, by - bs * 0.55, aw, bs * 1.1)
	draw.SimpleText("ACCESS", "WD_Item", ax + aw / 2 + sh * 0.013, by, hot and ColorAlpha(color_white, 255 * mul) or Color(0, 0, 0, 255 * mul), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	surface.SetDrawColor(hot and 255 or 0, hot and 255 or 0, hot and 255 or 0, 255 * mul)
	surface.DrawOutlinedRect(ax + sh * 0.008, by - bs * 0.3, bs * 0.6, bs * 0.6, 2)
	zones.access = {ax, by - bs * 0.55, aw, bs * 1.1}
	zones.panel = {x0, y0, x1 - x0, y1 - y0}
	return zones
end

-- ник сверху слева (аватар - отдельная панель AvatarImage)
function WD.DrawProfile(nick, alpha)
	local sh = ScrH()
	draw.SimpleText(nick, "WD_Login", sh * 0.06, sh * 0.026, Color(210, 210, 210, 230 * alpha / 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end

-- ===================== загрузка и вход =====================

local BOOT_LINES = {
	{"_ Loading, please wait..."},
	{""},
	{"[  2.20261028] sd 0:0:0:0:0 fnkbu22 [Fnk] Assuming drive cache: write through"},
	{"Valid path for Logical Volume."},
	{""},
	{"/usr/player: clean, 1704684/10121989 files, 3813438/7532544 blocks"},
	{"Started:   ", "Attempting to mount Funkware fuse mount.", green = true},
	{"See \"systemctl status \"runFunkware\\\\fuse.mount\"\" for details."},
	{""},
	{"[ 0.000000] init_memory_mapping: [mem 0x00100000-0xdefa4fff]"},
	{"[ 1.169734] [mem 0x00100000-0x001fffff]"},
	{"[ 0.310006] NetLabel: protocols = UNLABELED FNKSec0v4"},
	{""},
	{"Freeing initrd memory: 18780K (ffff880035b42000 - ffff880036d99000)"},
	{"PCI-DMA: Using software bounce buffering for IO (SFFnk)"},
	{""},
	{"status: ", "Ok", " EXT4-fs (sda1): orphan cleanup on readonly fs", ok = true},
	{"status: ", "Ok", " EXT4-fs (sda1): recovery complete", ok = true},
	{"status: ", "Ok", " EXT4-fs (sda1): mounted filesystem with ordered data mode.", ok = true},
	{"status: ", "Ok", " found CITY MP-table mapped at [mem 0x10121989-0x000f9bff]", ok = true},
	{""},
	{"Scanning 1 areas for low memory corruption"},
	{"Monitoring of city mirrors... ng dmeventd or progress polling."},
	{"init_memory_mapping: [mem 0x00000000-0x000ACK]"},
	{""},
	{"Mounted device Funkware: funkas00 login:"},
	{""},
	{"- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"},
}
local WARNING = "A very small percentage of individuals may experience epileptic seizures when exposed to certain light patterns or flashing lights. Exposure to certain patterns or backgrounds on a computer screen may induce an epileptic seizure in these individuals. If you, or anyone in your family, have an epileptic condition, consult your physician prior to playing. If you experience dizziness, altered vision, eye or muscle twitches, loss of awareness, disorientation, any involuntary movement, or convulsions - IMMEDIATELY discontinue use and consult your physician before resuming play."
local DISCLAIMER = "This server is a work of fiction. Any resemblance to actual events or any real persons, living or dead, is purely coincidental. No organization has approved, endorsed or authorized it."

local LINE_TIME = 0.08
local TERMINAL_END = #BOOT_LINES * LINE_TIME + 1.6
local LOGIN_END = TERMINAL_END + 3.6
WD.BootLength = LOGIN_END + 0.5

local function DrawTerminal(t, w, h)
	local sh = h
	local x, y, lh = sh * 0.022, sh * 0.01, sh * 0.02
	local shown = math.floor(t / LINE_TIME)
	for i = 1, math.min(shown, #BOOT_LINES) do
		local l = BOOT_LINES[i]
		local cx = x
		if l.ok then
			cx = cx + TextW("WD_Boot", l[1])
			draw.SimpleText(l[1], "WD_Boot", x, y, colText)
			draw.SimpleText(l[2], "WD_Boot", cx, y, colGreen)
			draw.SimpleText(l[3], "WD_Boot", cx + TextW("WD_Boot", l[2]), y, colText)
		elseif l.green then
			draw.SimpleText(l[1], "WD_Boot", x, y, colGreen)
			draw.SimpleText(l[2], "WD_Boot", x + TextW("WD_Boot", l[1]), y, colText)
		else
			draw.SimpleText(l[1], "WD_Boot", x, y, colText)
		end
		y = y + lh
	end
	if shown > #BOOT_LINES then
		y = y + lh
		for _, line in ipairs(Wrap(WARNING, "WD_Boot", w * 0.86)) do
			draw.SimpleText(line, "WD_Boot", sh * 0.11, y, colText)
			y = y + lh
		end
	end
end

local function DrawLogin(t, w, h, nick)
	local sh = h
	local a = math.Clamp(t / 0.6, 0, 1)
	if not matLogo:IsError() then
		local lw = sh * 1.1
		local lh = lw * 520 / 1100
		surface.SetMaterial(matLogo)
		surface.SetDrawColor(255, 255, 255, 120 * a)
		surface.DrawTexturedRect(w / 2 - lw / 2, h * 0.42 - lh / 2, lw, lh)
	end

	local fw, fh = sh * 0.42, sh * 0.034
	local fy = h * 0.41
	local x1, x2 = w / 2 - sh * 0.43, w / 2 + sh * 0.01
	local typed = math.Clamp(math.floor((t - 0.5) * 14), 0, #nick)
	local stars = math.Clamp(math.floor((t - 0.5 - #nick / 14) * 20), 0, 18)
	for k, fx in ipairs({x1, x2}) do
		surface.SetDrawColor(60, 60, 60, 220 * a)
		surface.DrawRect(fx, fy, fw, fh)
		surface.SetDrawColor(130, 130, 130, 200 * a)
		surface.DrawOutlinedRect(fx, fy, fw, fh, 1)
		local text = k == 1 and string.sub(nick, 1, typed) or string.rep("*", stars)
		draw.SimpleText(text, "WD_Login", fx + sh * 0.008, fy + fh / 2, Color(170, 170, 170, 255 * a), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local by, bh = fy + fh + sh * 0.035, sh * 0.042
	if stars >= 18 then
		surface.SetDrawColor(colBlue.r, colBlue.g, colBlue.b, 255)
		surface.DrawRect(x1, by, x2 + fw - x1, bh)
		draw.SimpleText("Logging as " .. nick, "WD_Login", w / 2, by + bh / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local ty = by + bh + sh * 0.035
	for _, line in ipairs(Wrap(DISCLAIMER, "WD_Small", x2 + fw - x1)) do
		draw.SimpleText(line, "WD_Small", w / 2, ty, Color(150, 150, 150, 230 * a), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		ty = ty + sh * 0.021
	end
end

-- t - секунды с начала; поверх всего; true, пока загрузка ещё идёт
function WD.DrawBoot(t, nick)
	local w, h = ScrW(), ScrH()
	if t >= WD.BootLength then return false end
	local fade = math.Clamp((WD.BootLength - t) / 0.5, 0, 1)
	surface.SetDrawColor(0, 0, 0, 255 * fade)
	surface.DrawRect(0, 0, w, h)
	if t < TERMINAL_END then
		DrawTerminal(t, w, h)
	elseif t < LOGIN_END then
		DrawLogin(t - TERMINAL_END, w, h, nick)
	end
	return true
end
