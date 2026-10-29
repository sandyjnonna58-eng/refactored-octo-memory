-- Главное меню в стиле хакерского терминала (как меню Watch Dogs 2), рисует cl_menu_panel.lua:
-- * при заходе в игру - загрузка (строки терминала + предупреждение) и экран входа с логотипом FUNKAS, дальше по клавише;
-- * фон: сцены из точек (materials/rem_wd/, генератор tools/menu_wd/gen.py) сменяют друг друга со сбоями картинки;
--   точки мерцают, сцена проявляется из шума, у каждой своё движение (волны колец, наезд, сканирование, дрейф);
-- * слева внизу список пунктов, выбранный - синяя плашка с "//"; справа внизу карусель карточек со стрелками,
--   точками и кнопкой ACCESS; слева сверху аватар и ник.
hg.WDMenu = hg.WDMenu or {}
local WD = hg.WDMenu

-- личный видеофон: если у игрока есть этот файл (в репозиторий и на сервер он не попадает, см. .gitignore),
-- вместо точечных сцен за меню крутится видео (HTML-панель с <video>)
WD.PrivateVideo = "materials/rem_wd_private/menu_bg.webm"
function WD.HasPrivateVideo()
	return file.Exists(WD.PrivateVideo, "GAME")
end
function WD.PrivateVideoHTML()
	return [[<html><head><style>html,body{margin:0;padding:0;overflow:hidden;background:#000}
video{position:absolute;left:0;top:0;width:100%;height:100%}</style></head><body>
<video src="asset://garrysmod/]] .. WD.PrivateVideo .. [[" autoplay loop muted></video></body></html>]]
end

local colBlue = Color(0, 0, 255)
local colText = Color(225, 225, 225)
local colBox = Color(22, 22, 22, 215)
local colPanel = Color(12, 12, 12, 225)
local colGreen = Color(60, 230, 60)

local SCENE_TIME = 9     -- секунд на сцену
local GLITCH_TIME = 0.6  -- сбой при смене сцены
local CARD_TIME = 8      -- карточки листаются сами

local function Mat(name) return Material("rem_wd/" .. name .. ".png", "smooth") end
local function Pair(name) return {Mat(name), Mat(name .. "_b")} end

-- сцены из точек; у каждой своё движение
local scenes = {
	{mats = Pair("scene_rings"), anim = "pulse"},
	{mats = Pair("scene_hood"), anim = "zoom"},
	{mats = Pair("scene_city"), anim = "scan"},
	{mats = Pair("scene_skulls"), anim = "drift"},
}
local matDotNoise = Mat("scene_noise")
local matLogo = Mat("logo")

local DOT = 115          -- яркость точек
local FLICKER_FPS = 8    -- два разброса точек сменяют друг друга
local RESOLVE_TIME = 1.2 -- сцена проявляется из шума

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

local function Rect(mat, cx, cy, w, h, v, a)
	surface.SetMaterial(mat)
	surface.SetDrawColor(v, v, v, a)
	surface.DrawTexturedRect(cx - w / 2, cy - h / 2, w, h)
end

local function DrawDots(scene, w, h, st, a)
	local mat = scene.mats[math.floor(RealTime() * FLICKER_FPS) % 2 + 1]
	if mat:IsError() then return end
	local cx, cy = w / 2, h / 2

	if scene.anim == "pulse" then
		-- кольца расходятся волнами: две копии растут и гаснут по очереди
		for k = 0, 1 do
			local p = (st / 4.5 + k * 0.5) % 1
			local s = 0.8 + p * 0.5
			Rect(mat, cx, cy, w * s, h * s, DOT, a * math.sin(p * math.pi))
		end
	elseif scene.anim == "zoom" then
		local s = 1 + 0.12 * st / SCENE_TIME
		Rect(mat, cx, cy, w * s, h * s, DOT, a)
	elseif scene.anim == "scan" then
		local s = 1.03
		Rect(mat, cx, cy, w * s, h * s, DOT * 0.8, a)
		-- полоса сканирования: в узкой полосе те же точки ярче
		local band = h * 0.16
		local y = (st / 3 % 1) * (h + band) - band
		render.SetScissorRect(0, math.floor(y), w, math.ceil(y + band), true)
			Rect(mat, cx, cy, w * s, h * s, 235, a)
		render.SetScissorRect(0, 0, 0, 0, false)
	elseif scene.anim == "drift" then
		-- два слоя: дальний медленно вправо, ближний крупнее и быстрее влево
		Rect(mat, cx - w * 0.05 + st * 6, cy, w * 1.12, h * 1.12, DOT, a)
		Rect(mat, cx + w * 0.12 - st * 16, cy + h * 0.04, w * 1.55, h * 1.55, DOT * 0.55, a * 0.6)
	end
end

local function DrawScene(i, w, h, st)
	local scene = scenes[(i - 1) % #scenes + 1]
	local k = math.Clamp(st / RESOLVE_TIME, 0, 1)
	-- проявление: из шума точек в картинку
	if k < 1 and not matDotNoise:IsError() then
		Rect(matDotNoise, w / 2, h / 2, w, h, DOT, 255 * (1 - k))
	end
	DrawDots(scene, w, h, st, 255 * k)
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
local TERMINAL_READY = #BOOT_LINES * LINE_TIME + 0.4 -- все строки и предупреждение на экране
local FADE_OUT = 0.5
local KEY_LOCK = 0.4 -- после смены этапа нажатия не принимаются (одно нажатие не пролетает два этапа)

local function LoginReady(nick) return 0.5 + #nick / 14 + 18 / 20 + 0.05 end -- ник, пароль и синяя полоса

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

-- ===================== загрузка при входе в игру =====================
-- Терминал, потом экран входа; дальше только по клавише: первое нажатие допечатывает текст,
-- следующее - к экрану входа / в игру. rem_boot_screen 0 - не показывать.
local cvBoot = CreateClientConVar("rem_boot_screen", "1", true, false, "Show the boot terminal and login screen when joining", 0, 1)

local function Nick()
	local ply = LocalPlayer()
	return IsValid(ply) and ply:Nick() or "player"
end

-- личные звуки загрузки (как и видеофон: только у себя, см. .gitignore); нет файла - тишина
local BOOT_SOUNDS = {terminal = "sound/rem_wd_private/boot_terminal.ogg", login = "sound/rem_wd_private/boot_login.ogg"}
local BOOT_SOUND_VOLUME = 0.8
local bootChannels = {}

local function PlayBootSound(name, delay)
	local path = BOOT_SOUNDS[name]
	if not file.Exists(path, "GAME") then return end
	timer.Create("WDMenu_BootSound_" .. name, delay or 0, 1, function()
		if not WD.BootActive() then return end
		sound.PlayFile(path, "noplay noblock", function(chan)
			if not IsValid(chan) then return end
			if IsValid(bootChannels[name]) then bootChannels[name]:Stop() end
			bootChannels[name] = chan
			chan:SetVolume(BOOT_SOUND_VOLUME)
			chan:Play()
		end)
	end)
end

local function StopBootSound(name)
	timer.Remove("WDMenu_BootSound_" .. name)
	if IsValid(bootChannels[name]) then bootChannels[name]:Stop() end
	bootChannels[name] = nil
end

local function StageReady(stage, t)
	if stage == 1 then return t >= TERMINAL_READY end
	return t >= LoginReady(Nick())
end

function WD.BootActive()
	return IsValid(WD.BootPanel)
end

-- нажатие клавиши на загрузке
function WD.BootKey()
	local pnl = WD.BootPanel
	if not IsValid(pnl) or pnl.FadeStart then return end
	-- одно и то же нажатие может прийти дважды (клавиша и Esc через меню паузы) - второе отсекаем
	if RealTime() - (pnl.LastKey or 0) < KEY_LOCK then return end
	pnl.LastKey = RealTime()
	local t = RealTime() - pnl.StageStart
	if not StageReady(pnl.Stage, t) then
		-- допечатать сразу
		pnl.StageStart = RealTime() - (pnl.Stage == 1 and TERMINAL_READY or LoginReady(Nick()))
		return
	end
	surface.PlaySound("ui/rem_select.wav")
	if pnl.Stage == 1 then
		pnl.Stage = 2
		pnl.StageStart = RealTime()
		StopBootSound("terminal")
		-- щелчок подтверждения в конце звука - вместе с синей полосой "Logging as"
		PlayBootSound("login", math.max(LoginReady(Nick()) - 1.55, 0))
	else
		pnl.FadeStart = RealTime()
	end
end

function WD.StartBoot()
	if IsValid(WD.BootPanel) then WD.BootPanel:Remove() end
	local pnl = vgui.Create("EditablePanel")
	WD.BootPanel = pnl
	pnl:SetPos(0, 0)
	pnl:SetSize(ScrW(), ScrH())
	pnl:MakePopup()
	pnl:SetMouseInputEnabled(false)
	pnl:SetKeyboardInputEnabled(true)
	pnl:SetZPos(32767)
	pnl.Stage = 1
	pnl.StageStart = RealTime()
	PlayBootSound("terminal", 0.15)
	function pnl:OnRemove()
		StopBootSound("terminal")
		StopBootSound("login")
	end

	function pnl:OnKeyCodePressed(code)
		WD.BootKey()
	end

	function pnl:Paint(w, h)
		local fade = self.FadeStart and math.Clamp(1 - (RealTime() - self.FadeStart) / FADE_OUT, 0, 1) or 1
		if fade <= 0 then
			self:Remove()
			return
		end
		local oldMul = surface.GetAlphaMultiplier()
		surface.SetAlphaMultiplier(fade)
		surface.SetDrawColor(0, 0, 0, 255)
		surface.DrawRect(0, 0, w, h)
		local t = RealTime() - self.StageStart
		local ok, err
		if self.Stage == 1 then
			ok, err = pcall(DrawTerminal, t, w, h)
		else
			ok, err = pcall(DrawLogin, t, w, h, Nick())
		end
		-- если рисование сломалось - пишем в консоль и уходим в игру, а не висим невидимым экраном
		if not ok then
			ErrorNoHalt("[boot screen] " .. tostring(err) .. "\n")
			self.FadeStart = self.FadeStart or RealTime()
		end
		surface.SetAlphaMultiplier(oldMul)
	end
end

-- файлы initpost грузятся уже на InitPostEntity (autorun/loader.lua), так что запускаем сразу, один раз за сессию
if not WD.BootShown then
	WD.BootShown = true
	timer.Simple(0, function()
		if cvBoot:GetBool() then WD.StartBoot() end
	end)
end

concommand.Add("rem_boot_screen_test", function() WD.StartBoot() end)
