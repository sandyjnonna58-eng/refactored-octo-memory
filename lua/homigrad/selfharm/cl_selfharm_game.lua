-- Мини-игра самоповреждения, как в Fading Vitality. Во время позыва (modules/sv_depression.lua, NW "rem_selfharm_wave_end";
-- нож уже в руках - сервер сам его достаёт) вместо "жми E" на экране тёмная панель с белым контуром предплечья
-- (materials/rem_selfharm/arm.png, tools/selfharm/make.py) и точка - рука с ножом. Точку всё время тянет к руке; игрок
-- сопротивляется, мотая головой мышью туда-сюда: каждый размах в другую сторону отбрасывает руку от предплечья, голова
-- (взгляд) при этом правда мотается, но не дальше SHAKE_YAW от начала; вверх-вниз мышь не работает, нож не машет. Дотянуло - порез: красная рваная полоса вдоль предплечья,
-- капли, экран на миг чернеет, серверу уходит "rem_selfharm_cut" и нож режет по-настоящему (DoSelfHarmCut). Чем дольше
-- позыв, тем сильнее тянет. Позыв кончился - панель гаснет.
local G = {
	panel = 0.42,        -- сторона панели, доля меньшей стороны экрана
	cx = 0.24, cy = 0.5, -- центр панели, доли экрана (как в оригинале - левее середины)
	pullStart = 0.16,    -- притяжение в начале позыва, панелей в секунду
	pullEnd = 0.55,      -- в конце
	swingMin = 70,       -- пикселей мыши в одну сторону, чтобы размах засчитался
	push = 0.075,        -- на сколько панели отбрасывает руку за размах
	yawPerPx = 0.03,     -- градусов поворота головы на пиксель
	shakeYaw = 28,       -- дальше этого от начала голова не поворачивается
	armR = 0.085,        -- полуширина предплечья, доля панели
	cutCooldown = 1.2,   -- после пореза точку отбрасывает и тянуть начинает снова через столько секунд
	cutLen = 0.42,       -- длина пореза, доля панели
	hold = 0.12, fade = 0.55, -- затемнение после пореза: держится и тает
}
-- ось предплечья на текстуре (0..1): от запястья вниз к локтю
local ARM_A, ARM_B = {0.385, 0.43}, {0.545, 1.0}

local armMat = Material("rem_selfharm/arm.png", "smooth")
local white = Material("vgui/white")
local grain = {}
for i = 1, 4 do grain[i] = Material("rem_death/vortex_static" .. i .. ".png") end

local active = false
local startTime, endTime = 0, 0
local px, py = 0.88, 0.5 -- точка в долях панели
local swingDir, swing = 0, 0 -- текущее направление размаха мышью и его длина
local baseYaw, headYaw = 0, 0 -- взгляд в начале позыва и текущий поворот головы от него
local shakeKick = 0 -- толчок панели от последнего размаха (для отдачи на экране)
local cuts = {}
local lastCut = -100
local jitterSeed = 0

local function Active()
	local ply = LocalPlayer()
	return IsValid(ply) and ply:Alive() and ply:GetNWFloat("rem_selfharm_wave_end", 0) > CurTime()
end
hg.SelfHarmGame = {Active = function() return active end}

-- ближайшая точка оси предплечья: параметр 0..1 и расстояние (в долях панели)
local function Nearest(x, y)
	local ax, ay, bx, by = ARM_A[1], ARM_A[2], ARM_B[1], ARM_B[2]
	local dx, dy = bx - ax, by - ay
	local t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)
	t = math.Clamp(t, 0, 1)
	local nx, ny = ax + dx * t, ay + dy * t
	return t, math.sqrt((x - nx) ^ 2 + (y - ny) ^ 2), nx, ny
end

local function Rand01(seed)
	local v = math.sin(seed * 12.9898) * 43758.5453
	return v - math.floor(v)
end

local function DoCut(t)
	local now = CurTime()
	lastCut = now
	jitterSeed = jitterSeed + 1
	cuts[#cuts + 1] = {start = now, t = math.Clamp(t, 0.15, 0.85), seed = jitterSeed * 17}
	-- руку отдёргивает к краю
	px, py = 0.86 + math.Rand(-0.04, 0.04), 0.5 + math.Rand(-0.15, 0.15)
	net.Start("rem_selfharm_cut")
	net.SendToServer()
end

hook.Add("Think", "rem_selfharm_game", function()
	local now = CurTime()
	local want = Active()
	if want and not active then
		active = true
		startTime = now
		px, py = 0.88, 0.5
		swingDir, swing, headYaw = 0, 0, 0
		baseYaw = LocalPlayer():EyeAngles().y
		cuts = {}
		lastCut = -100
	elseif not want and active then
		active = false
	end
	if not active then return end
	endTime = LocalPlayer():GetNWFloat("rem_selfharm_wave_end", 0)

	local dt = FrameTime()
	-- дрожь руки
	px = px + math.sin(now * 13 + 1) * 0.0008 + math.sin(now * 7.3) * 0.0012
	py = py + math.cos(now * 11 + 2) * 0.0010

	-- тянет к руке (после пореза - пауза)
	if now > lastCut + G.cutCooldown then
		local progress = math.Clamp((now - startTime) / math.max(endTime - startTime, 1), 0, 1)
		local speed = Lerp(progress, G.pullStart, G.pullEnd)
		local t, dist, nx, ny = Nearest(px, py)
		if dist > 0.001 then
			local k = math.min(speed * dt / dist, 1)
			px, py = px + (nx - px) * k, py + (ny - py) * k
		end
		if dist < G.armR then DoCut(t) end
	end
	px, py = math.Clamp(px, 0.03, 0.97), math.Clamp(py, 0.03, 0.97)
	shakeKick = math.Approach(shakeKick, 0, dt * 4)
end)

-- размах засчитан: руку отбрасывает от предплечья (к правому краю, где она была в начале)
local function Push(dir)
	local t, dist, nx, ny = Nearest(px, py)
	local ax, ay = px - nx, py - ny
	local l = math.sqrt(ax * ax + ay * ay)
	if l < 0.001 then ax, ay, l = 1, 0, 1 end
	px = px + ax / l * G.push + math.Rand(-0.01, 0.01)
	py = py + ay / l * G.push * 0.5 + math.Rand(-0.02, 0.02)
	shakeKick = dir
end

-- мотаешь головой: мышь влево-вправо крутит голову (в пределах shakeYaw), каждая смена направления после
-- достаточного размаха - толчок руки прочь от предплечья; вверх-вниз - ничего
hook.Add("InputMouseApply", "rem_selfharm_game", function(cmd, x, y, ang)
	if not active then return end
	local dx = cmd:GetMouseX()
	if dx ~= 0 then
		local dir = dx > 0 and 1 or -1
		if dir ~= swingDir then
			if swingDir ~= 0 and swing >= G.swingMin and CurTime() > lastCut + 0.25 then Push(dir) end
			swingDir, swing = dir, 0
		end
		swing = swing + math.abs(dx)
		headYaw = math.Clamp(headYaw - dx * G.yawPerPx, -G.shakeYaw, G.shakeYaw)
	end
	local a = cmd:GetViewAngles()
	a.y = baseYaw + headYaw
	cmd:SetViewAngles(a)
	cmd:SetMouseX(0)
	cmd:SetMouseY(0)
	return true
end)

-- ножом не машем
hook.Add("CreateMove", "rem_selfharm_game", function(cmd)
	if not active then return end
	cmd:RemoveKey(IN_ATTACK)
	cmd:RemoveKey(IN_ATTACK2)
end)

local function Seg(x1, y1, x2, y2, w, r, g, b, a)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.5 then return end
	surface.SetMaterial(white)
	surface.SetDrawColor(r, g, b, a)
	surface.DrawTexturedRectRotated((x1 + x2) * 0.5, (y1 + y2) * 0.5, len, w, -math.deg(math.atan2(dy, dx)))
end

hook.Add("HUDPaint", "rem_selfharm_game", function()
	local now = CurTime()
	-- затемнение после пореза - и когда панели уже нет
	local since = now - lastCut
	local black = since < G.hold and 1 or math.Clamp(1 - (since - G.hold) / G.fade, 0, 1)
	if not active then
		if black > 0 then
			surface.SetDrawColor(0, 0, 0, math.floor(255 * black))
			surface.DrawRect(0, 0, ScrW(), ScrH())
		end
		return
	end

	local S = math.floor(math.min(ScrW(), ScrH()) * G.panel)
	local x0, y0 = math.floor(ScrW() * G.cx - S * 0.5 + shakeKick * S * 0.03), math.floor(ScrH() * G.cy - S * 0.5)

	-- панель: тёмная, с зерном
	surface.SetDrawColor(0, 0, 0, 175)
	surface.DrawRect(x0, y0, S, S)
	if not grain[1]:IsError() then
		surface.SetMaterial(grain[math.floor(now * 8) % 4 + 1])
		surface.SetDrawColor(255, 255, 255, 14)
		surface.DrawTexturedRect(x0, y0, S, S)
	end
	surface.SetDrawColor(255, 255, 255, 18)
	surface.DrawOutlinedRect(x0, y0, S, S, 1)

	-- рука
	surface.SetMaterial(armMat)
	surface.SetDrawColor(255, 255, 255, 235)
	surface.DrawTexturedRect(x0, y0, S, S)

	-- порезы: рваная красная полоса вдоль оси предплечья, растёт за 0.3 с, потом капли вниз
	local ax, ay, bx, by = x0 + ARM_A[1] * S, y0 + ARM_A[2] * S, x0 + ARM_B[1] * S, y0 + ARM_B[2] * S
	local ux, uy = bx - ax, by - ay
	local ul = math.sqrt(ux * ux + uy * uy)
	ux, uy = ux / ul, uy / ul
	local nx, ny = -uy, ux
	for _, c in ipairs(cuts) do
		local age = now - c.start
		local L = math.min(age / 0.3, 1) * S * G.cutLen
		local cx, cy = ax + ux * ul * c.t, ay + uy * ul * c.t
		local n = 9
		local lx, ly
		for i = 0, n do
			local f = i / n - 0.5
			local off = (Rand01(c.seed + i) - 0.5) * S * 0.02
			local x, y = cx + ux * L * f + nx * off, cy + uy * L * f + ny * off
			if lx then
				Seg(lx, ly, x, y, math.max(S * 0.014, 3), 150, 0, 0, 170)
				Seg(lx, ly, x, y, math.max(S * 0.006, 1.5), 235, 25, 25, 255)
			end
			lx, ly = x, y
		end
		-- капли
		for i = 1, 3 do
			local f = Rand01(c.seed + 100 + i) - 0.5
			local dl = math.min(math.max(age - 0.3, 0) / 4, 1) * S * (0.05 + 0.06 * Rand01(c.seed + 200 + i))
			local x, y = cx + ux * L * f * 0.8, cy + uy * L * f * 0.8
			Seg(x, y, x + math.sin(i) * dl * 0.1, y + dl, math.max(S * 0.005, 1.5), 200, 15, 15, 220)
		end
	end

	-- точка - рука с ножом
	local dx, dy = x0 + px * S, y0 + py * S
	surface.SetDrawColor(255, 255, 255, 60)
	surface.DrawRect(dx - 4, dy - 4, 8, 8)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.DrawRect(dx - 2, dy - 2, 4, 4)

	-- подсказка
	local col = Color(255, 255 - 120 * (0.5 + 0.5 * math.sin(now * 6)), 255 - 120 * (0.5 + 0.5 * math.sin(now * 6)), 220)
	draw.SimpleText("< SHAKE IT OFF >", "HomigradFontSmall", x0 + S * 0.5 + math.random(-2, 2), y0 + S + ScreenScale(6) + math.random(-1, 1), col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	if black > 0 then
		surface.SetDrawColor(0, 0, 0, math.floor(255 * black))
		surface.DrawRect(0, 0, ScrW(), ScrH())
	end
end)
