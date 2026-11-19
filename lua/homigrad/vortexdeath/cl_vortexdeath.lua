-- Экран умирания "вихрь" (таймер смерти, sv_vortexdeath.lua) под песню rem_death_cfyt.ogg:
-- чёрный экран, по одному проступают красные "!!!", ниже "Give up"; потом из темноты поднимается красный
-- пиксельный шум, тёмные спиральные рукава вокруг тёмного центра; ничего не вращается - краснота наползает с краёв
-- экрана к центру: темнота сначала больше экрана и сжимается, а рукава распрямляются в лучи до самого конца таймера.
-- Пока он идёт, остальная музыка затихает (hg.RemAudio); зажатый прыжок - "Give up": время смерти (и песня) идёт быстрее.
hg.VortexDeath = hg.VortexDeath or {}
local DV = hg.VortexDeath

local SONG = "sound/rem_death_cfyt.ogg"
DV.GiveUpSpeed = 4 -- во сколько раз быстрее идёт время, пока зажат "Give up" (так же в sv_vortexdeath.lua)
local FADE_IN, FADE_OUT = 0.6, 1.5

local RAMP_START, RAMP_TIME = 4, 12 -- когда начинает проступать красный и за сколько доходит до максимума
local GROW_TIME = 78                 -- за сколько тёмный центр сжимается, а рукава распрямляются (почти весь таймер, 84 с)
-- тёмный центр (полуось по горизонтали, в долях высоты экрана): в начале больше экрана - красный только по краям,
-- к концу - небольшое пятно посередине, как в Fading Vitality
local CORE_START, CORE_END = 1.25, 0.45
local CORE_EASE = 6  -- сжатие сначала быстрое, потом еле заметное (больше - резче в начале)
local CORE_ASPECT = 0.6 -- эллипс: высота / ширина
local CORE_LAYERS = 3   -- сколько раз накладывать пятно (гуще середина, край остаётся мягким)
local CORE_TEX_R = 0.22 -- радиус заметной части пятна в vortex_centre.png (в долях ширины текстуры)
local MARKS_DOT = {0.4, 0.9, 1.4}    -- когда появляются точки
local MARKS_BANG = {1.2, 2.6, 4.0}   -- когда точка становится "!"
local GIVEUP_TIME = 7
local SWIRL_ANGLE, RAYS_ANGLE = 0, 0 -- вихрь не крутится (как в оригинале): только медленно растёт
local NOISE_FPS = 0 -- шум стоит неподвижно (0 - один кадр; >0 - мерцает с этой частотой)

local matSwirl = Material("rem_death/vortex_swirl.png", "smooth")
local matRays = Material("rem_death/vortex_rays.png", "smooth")
local matCentre = Material("rem_death/vortex_centre.png", "smooth")
local matNoise = {}
for i = 1, 4 do
	matNoise[i] = Material("rem_death/vortex_static" .. i .. ".png") -- без smooth: крупные пиксели
end

local function CreateFonts()
	local sh = ScrH()
	surface.CreateFont("DeathVortex_Info", {font = "VT323", size = math.floor(sh * 0.036), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_Marks", {font = "VT323", size = math.floor(sh * 0.17), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_GiveUp", {font = "VT323", size = math.floor(sh * 0.075), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_Key", {font = "VT323", size = math.floor(sh * 0.035), weight = 400, antialias = false, extended = true})
	surface.CreateFont("DeathVortex_Desc", {font = "VT323", size = math.floor(sh * 0.05), weight = 400, antialias = false, extended = true})
end
CreateFonts()
hook.Add("OnScreenSizeChanged", "DeathVortex_Fonts", CreateFonts)

local function smooth(a)
	a = math.Clamp(a, 0, 1)
	return a * a * (3 - 2 * a)
end

-- текстура, повёрнутая внутри неповёрнутого прямоугольника (эллипс остаётся горизонтальным);
-- ang растёт - картинка крутится по часовой стрелке (поворачиваем UV в обратную сторону)
local poly = {{}, {}, {}, {}}
local corners = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}
local function DrawSpun(mat, cx, cy, w, h, ang, a, zoom)
	local c, s = math.cos(math.rad(-ang)), math.sin(math.rad(-ang))
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

-- t - секунды с начала звука; alpha 0..255 - общая прозрачность (затухание в конце); skipKey - подпись клавиши,
-- holding - клавиша зажата (надпись ярче)
function DV.Draw(t, alpha, skipKey, holding)
	local sw, sh = ScrW(), ScrH()
	local mul = alpha / 255
	local k = smooth((t - RAMP_START) / RAMP_TIME)

	surface.SetDrawColor(math.floor(150 * k), 0, 0, alpha)
	surface.DrawRect(0, 0, sw, sh)

	if k > 0 then
		-- красный шум
		surface.SetMaterial(matNoise[NOISE_FPS > 0 and math.floor(t * NOISE_FPS) % 4 + 1 or 1])
		surface.SetDrawColor(math.floor(255 * (0.75 + 0.25 * k)), 25, 25, math.floor(255 * k * mul))
		surface.DrawTexturedRect(0, 0, sw, sh)

		-- рост: равномерно весь таймер
		local g = math.Clamp((t - RAMP_START) / GROW_TIME, 0, 1)

		-- темнота сначала больше экрана (красный виден только по краям и углам) и сжимается к центру - первые ~20 с
		-- быстро, потом еле заметно (как в видео); красный наползает с краёв; a - полуось тёмного эллипса по горизонтали в пикселях
		local e = (1 - math.exp(-CORE_EASE * g)) / (1 - math.exp(-CORE_EASE))
		local a = sh * Lerp(e, CORE_START, CORE_END)

		-- рукава держатся вокруг края темноты и сжимаются вместе с ней: в начале почти целиком за экраном,
		-- к концу - короткие лучи вокруг маленького тёмного центра
		local size = a * Lerp(g, 3.4, 2.7)
		local rays = smooth((g - 0.15) / 0.5)
		local armsAlpha = math.min(1, k * 3) * mul
		-- текстура целиком (zoom 1): прямоугольник теперь бывает меньше экрана, а у полной текстуры края прозрачные -
		-- не видно обрезанных кончиков лучей; масштаб тот же, что у середины 72% при ширине size
		local aw, ah = size / 0.72, size
		if rays < 1 then DrawSpun(matSwirl, sw / 2, sh / 2, aw, ah, SWIRL_ANGLE, 242 * (1 - rays) * armsAlpha, 1) end
		if rays > 0 then DrawSpun(matRays, sw / 2, sh / 2, aw, ah, RAYS_ANGLE, 230 * rays * armsAlpha, 1) end

		-- тёмный центр: заметная часть пятна (из Base44, зернистый край) - ~0.22 ширины текстуры от середины,
		-- поэтому ширина = a / CORE_TEX_R; рисуем несколько раз, чтобы внутри было глухо-чёрно, а мягкий край - у границы
		local cw = a / CORE_TEX_R
		local ch = cw * CORE_ASPECT
		surface.SetMaterial(matCentre)
		surface.SetDrawColor(255, 255, 255, math.floor(255 * mul))
		for _ = 1, CORE_LAYERS do
			surface.DrawTexturedRect(sw / 2 - cw / 2, sh / 2 - ch / 2, cw, ch)
		end
	end

	-- "!!!": сначала точки, потом по одному восклицательные знаки
	local marks = {}
	for i = 1, 3 do
		marks[i] = t >= MARKS_BANG[i] and "!" or (t >= MARKS_DOT[i] and "." or " ")
	end
	draw.SimpleText(table.concat(marks, " "), "DeathVortex_Marks", sw / 2, sh * 0.5, Color(225, 20, 20, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	if t >= GIVEUP_TIME then
		local a = math.floor(255 * math.min(1, (t - GIVEUP_TIME) / 1.5) * mul)
		local col = holding and Color(255, 45, 45, a) or Color(200, 20, 20, a)
		-- на ярко-красном фоне надпись получает тёмную обводку, как в оригинале
		if k > 0.5 then
			draw.SimpleTextOutlined("Give up", "DeathVortex_GiveUp", sw / 2, sh * 0.78, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(40, 0, 0, a))
		else
			draw.SimpleText("Give up", "DeathVortex_GiveUp", sw / 2, sh * 0.78, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		if skipKey then
			draw.SimpleText("hold [" .. skipKey .. "]", "DeathVortex_Key", sw / 2, sh * 0.78 + sh * 0.055, Color(170, 20, 20, math.floor(a * 0.7)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

-- Экран после смерти ("Deceased.", autorun/client/cl_cdeath.lua) в том же стиле, под звук смерти (rem_brutaldeath.mp3):
-- вспышка - красный пиксельный шум с закрученными рукавами вокруг тёмного центра, за ~7 с уходит в черноту;
-- надпись печатается красным пиксельным шрифтом по буквам. Фон и надпись раздельно: между ними cl_cdeath рисует силуэт тела.
local DECEASED_TYPE_START, DECEASED_TYPE_SPEED = 0.25, 12 -- букв в секунду

-- flash 1..0 - сила вспышки, alpha 0..255 - общая прозрачность
function DV.DrawDeceasedBackground(t, alpha, flash)
	local sw, sh = ScrW(), ScrH()
	local mul = alpha / 255
	local k = flash * flash

	surface.SetDrawColor(math.floor(150 * k), 0, 0, alpha)
	surface.DrawRect(0, 0, sw, sh)
	if k <= 0 then return end

	surface.SetMaterial(matNoise[NOISE_FPS > 0 and math.floor(t * NOISE_FPS) % 4 + 1 or 1])
	surface.SetDrawColor(255, 25, 25, math.floor(255 * k * mul))
	surface.DrawTexturedRect(0, 0, sw, sh)

	local size = math.max(sw, sh) * 1.5
	DrawSpun(matSwirl, sw / 2, sh / 2, size, size * 0.72, SWIRL_ANGLE, 230 * k * mul, 0.72)

	local cw = sw * (0.75 + 0.5 * (1 - flash)) * 0.3 / CORE_TEX_R -- размер подогнан под старое пятно (радиус 0.3)
	surface.SetMaterial(matCentre)
	surface.SetDrawColor(255, 255, 255, math.floor(242 * k * mul))
	surface.DrawTexturedRect(sw / 2 - cw / 2, sh / 2 - cw * 0.25, cw, cw * 0.5)
end

local function Typed(str, t)
	return string.sub(str, 1, math.Clamp(math.floor(t * DECEASED_TYPE_SPEED), 0, #str))
end

function DV.DrawDeceasedText(t, alpha, flash, text, desc, skipKey, info)
	local sw, sh = ScrW(), ScrH()
	-- на яркой вспышке надпись тёмная, по мере ухода в черноту - красная
	local k = flash * flash
	local col = Color(Lerp(k, 225, 15), Lerp(k, 20, 0), Lerp(k, 20, 0), alpha)
	local outline = Color(Lerp(k, 20, 90), 0, 0, alpha)

	-- заголовок, потом подпись; мигающий курсор в конце печатаемой строки
	local tt = t - DECEASED_TYPE_START
	local title = Typed(text, tt)
	local titleDone = #title == #text
	local sub = titleDone and Typed(desc, tt - #text / DECEASED_TYPE_SPEED - 0.3) or ""
	local blink = math.floor(CurTime() * 2.5) % 2 == 0

	-- выравнивание по ширине полной строки, чтобы текст не прыгал, пока печатается
	surface.SetFont("DeathVortex_Marks")
	local titleW = surface.GetTextSize(text)
	surface.SetFont("DeathVortex_Desc")
	local descW = surface.GetTextSize(desc)

	local cursorTitle = (not titleDone or (#sub == 0 and blink)) and "_" or ""
	draw.SimpleTextOutlined(title .. cursorTitle, "DeathVortex_Marks", (sw - titleW) / 2, sh * 0.45, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 3, outline)
	if #sub > 0 then
		local cursorDesc = (#sub < #desc or blink) and "_" or ""
		draw.SimpleTextOutlined(sub .. cursorDesc, "DeathVortex_Desc", (sw - descW) / 2, sh * 0.6, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 2, outline)
	end

	-- сводка: печатается после подписи, мелко и тусклее
	if info and #sub == #desc then
		local it = tt - (#text + #desc) / DECEASED_TYPE_SPEED - 0.8
		local icol = Color(col.r, col.g, col.b, math.floor(alpha * 0.8))
		for i, line in ipairs(info) do
			local typed = Typed(line, it * 2.5)
			if #typed == 0 then break end
			draw.SimpleText(typed, "DeathVortex_Info", sw / 2, sh * 0.7 + (i - 1) * sh * 0.042, icol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			it = it - #line / (DECEASED_TYPE_SPEED * 2.5) - 0.15
		end
	end

	if skipKey then
		draw.SimpleText("[" .. skipKey .. "] skip", "DeathVortex_Key", sw / 2, sh * 0.92, Color(Lerp(k, 170, 15), Lerp(k, 20, 0), Lerp(k, 20, 0), math.floor(alpha * 0.7)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end

-- Сводка на экране смерти (как "Time of death" / "Last recorded mental state" в Fading Vitality): пока жив, раз в 0.5 с
-- запоминаем состояние (настроение - только в сознании: в отключке остаётся последнее), умер - замораживаем.
local MOOD = { -- по порядку: первое подходящее
	{"Berserk", function(ply) return ply:GetNW2Int("rem_rage_stage", 0) >= 3 end},
	{"Euphoric", function(ply) return ply:GetNW2Float("rem_high", 0) >= 0.5 end},
	{"Agonized", function(_, org) return (org.pain or 0) >= 90 end},
	{"Terrified", function(_, org) return (org.fear or 0) > 0.5 end},
	{"Enraged", function(ply) return ply:GetNW2Int("rem_rage_stage", 0) >= 1 end},
	{"Hopeless", function(_, org) return (org.depression or 0) >= 0.6 end},
	{"Miserable", function(_, org) return (org.depression or 0) >= 0.3 or (org.pain or 0) >= 60 end},
	{"Fading", function(_, org) return (org.blood or 5000) < 3500 or (org.consciousness or 1) < 0.5 end},
	{"Suffering", function(_, org) return (org.pain or 0) >= 30 end},
	{"Uneasy", function(_, org) return (org.fear or 0) > 0.2 or (org.depression or 0) >= 0.1 end},
}

local CAUSE = {
	melee = "Melee wounds", gun = "Gunshot wounds", explosion = "Explosion", player = "Killed", npc = "Killed",
	suicide = "Suicide", fire = "Burned", fall = "Fall", drown = "Drowned", poison = "Poisoned",
	shock = "Electrocuted", brain = "Brain death",
}

-- что отказало у организма (для причины "organism" или если причины нет)
local function OrganCause(org)
	if org.headamputated then return "Decapitated" end
	if (org.blood or 5000) < 3000 then return "Blood loss" end
	if org.heartstop then return "Cardiac arrest" end
	if (org.brain or 0) >= 0.5 then return "Brain damage" end
	local o2 = istable(org.o2) and (org.o2[1] or 30) / (org.o2.range or 30) or 1
	if o2 < 0.4 then return "Asphyxia" end
end

local rec = {}
local frozen
local nextRec = 0
local wasAlive = false

hook.Add("Think", "rem_vortex_summary", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local alive = ply:Alive()
	if alive and not wasAlive then rec = {} frozen = nil end -- новая жизнь
	if not alive and wasAlive then
		frozen = {
			time = math.max(0, CurTime() - (zb and zb.ROUND_START or 0)),
			mood = rec.mood or (rec.otrub and "Unconscious") or "Calm",
			organ = rec.organ,
		}
	end
	wasAlive = alive
	if not alive or CurTime() < nextRec then return end
	nextRec = CurTime() + 0.5
	local org = ply.organism
	if not istable(org) then return end
	rec.organ = OrganCause(org)
	rec.otrub = org.otrub
	if org.otrub then return end
	rec.mood = "Calm"
	for _, m in ipairs(MOOD) do
		if m[2](ply, org) then rec.mood = m[1] break end
	end
end)

-- строки под "Deceased.": время смерти (от начала раунда), причина, последнее настроение; causeKey - причина от сервера
function DV.DeathSummary(causeKey)
	-- жив (предпросмотр rem_test_vortex) - по текущим записям
	local f = frozen or {time = math.max(0, CurTime() - (zb and zb.ROUND_START or 0)), mood = rec.mood or "Calm", organ = rec.organ}
	local s = math.floor(f.time)
	local lines = {("Time of death: %d:%d:%02d"):format(math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)}
	local cause = (causeKey == "organism" or not causeKey) and f.organ or CAUSE[causeKey]
	if causeKey == "organism" and not cause then cause = "Organ failure" end
	if cause then lines[#lines + 1] = "Cause of death: " .. cause end
	lines[#lines + 1] = "Last recorded mental state: " .. f.mood
	return lines
end

local MusicVolume = GetConVar("snd_musicvolume")
-- песни таймера смерти (вихрь, последние моменты) громче обычной музыки: 3 = 300%
local DyingVolume = CreateClientConVar("rem_dying_music_volume", "3", true, false, "Volume of the death timer songs (vortex, last moments), 1 = 100%, 3 = 300%", 0, 5)
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

-- свои часы вихря: идут быстрее, пока зажат прыжок, и подтягиваются к серверным (rem_vortex_start сдвигает сервер)
local clock = 0
local holding = false
local wasActive = false

local function ServerClock()
	return CurTime() - LocalPlayer():GetNWFloat("rem_vortex_start", CurTime())
end

local function JumpHeld()
	if gui.IsGameUIVisible() or vgui.GetKeyboardFocus() or (IsValid(LocalPlayer()) and LocalPlayer():IsTyping()) then return false end
	local key = input.LookupBinding("+jump")
	local code = key and input.GetKeyCode(key)
	return code and code > 0 and input.IsButtonDown(code) or false
end

hook.Add("Think", "rem_vortexdeath", function()
	local active = DV.Active()
	local dt = FrameTime()
	if active and not wasActive then clock = ServerClock() end
	wasActive = active

	-- "Give up": пока прыжок зажат (и надпись уже появилась), время идёт быстрее
	local hold = active and clock >= GIVEUP_TIME and JumpHeld()
	if hold ~= holding then
		holding = hold
		net.Start("rem_vortexdeath_giveup")
		net.WriteBool(hold)
		net.SendToServer()
	end
	local rate = holding and DV.GiveUpSpeed or 1

	if active then
		local target = ServerClock()
		clock = clock + dt * rate
		if math.abs(clock - target) > 1 then clock = target else clock = Lerp(math.min(dt * 2, 1), clock, target) end
	end

	if active and not IsValid(station) and not loading then
		loading = true
		clock = ServerClock()
		sound.PlayFile(SONG, "noblock noplay", function(chan)
			loading = false
			if not IsValid(chan) then return end
			if not DV.Active() then chan:Stop() return end

			station = chan
			if hg.RemAudio then hg.RemAudio.SetExempt(chan) end
			-- песня идёт с начала таймера: догоняем, если звук загрузился с опозданием
			if clock > 0.5 then chan:SetTime(clock) end
			volume = 1
			chan:SetVolume(MusicVolume:GetFloat() * DyingVolume:GetFloat())
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
	station:SetVolume(volume * MusicVolume:GetFloat() * DyingVolume:GetFloat())
	if active then
		-- песня ускоряется вместе со временем и держится вровень с экраном
		station:SetPlaybackRate(rate)
		if math.abs(station:GetTime() - clock) > 0.75 and clock < station:GetLength() then station:SetTime(clock) end
	end
end)

hook.Add("Dying Screen Processing", "rem_vortexdeath", function()
	if visible <= 0 then return end
	DV.Draw(clock, math.floor(255 * visible), DV.Active() and JumpKeyName() or nil, holding)
end)

-- прыжок во время вихря не прыгает
hook.Add("PlayerBindPress", "rem_vortexdeath", function(ply, bind, pressed)
	if DV.Active() and string.find(bind, "+jump", 1, true) then return true end
end)

-- Предпросмотр (rem_test_vortex [скорость], у себя, без урона): вихрь целиком (84 с / скорость), потом
-- экран Deceased со сводкой. Повторный вызов или rem_test_vortex 0 - остановить.
local preview
concommand.Add("rem_test_vortex", function(_, _, args)
	local speed = tonumber(args[1] or "") or 4
	if preview or speed <= 0 then preview = nil return end
	preview = {start = RealTime(), speed = speed}
end)

hook.Add("DrawOverlay", "rem_test_vortex", function()
	if not preview then return end
	local pt = (RealTime() - preview.start)
	local vortexLen = 84 / preview.speed
	if pt < vortexLen then
		DV.Draw(pt * preview.speed, 255, nil, false)
		return
	end
	pt = pt - vortexLen
	if pt > 9 then preview = nil return end
	local flash = 1 - math.Clamp(pt / 6, 0, 1)
	DV.DrawDeceasedBackground(pt, 255, flash)
	DV.DrawDeceasedText(pt, 255, flash, "Deceased.", "You are no longer a witness to the world.", nil, DV.DeathSummary("organism"))
end)
