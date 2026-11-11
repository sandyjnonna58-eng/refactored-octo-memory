-- ЭКГ-монитор - верхняя часть панели осмотра (cl_health_indicator.lua): один фон и одна рамка с силуэтом.
-- Сверху "BPM / SpO2", посередине бегущая пиксельная кардиограмма (новое справа - ярче, со свечением),
-- снизу светлая полоса с давлением. Формы - по примерам пользователя (SCAV Prototype):
--   1 быстрый пульс (> 110): узкий высокий зубец и глубокий провал, частые удары;
--   2 низкий пульс (< 60): широкий зубец, плато, длинные ровные паузы;
--   3 норма: узкий зубец, провал и приподнятый пологий спад после него;
--   4 желудочковая тахикардия (fib > 50): ровные большие треугольники;
--   5 аритмия (fib > 15): мелкие частые волны; фибрилляция (fib > 75) - те же волны, чаще, неровнее и слабее к 100%;
--   6 остановка сердца - красная прямая.
hg.ECG = hg.ECG or {}
local E = hg.ECG

E.cv = CreateClientConVar("rem_ecg", "1", true, false, "ECG monitor above the body in the health inspect panel", 0, 1)

local WINDOW = 3.2     -- секунд кардиограммы на экране
local SR = 240         -- отсчётов в секунду (в столбик пикселя попадают min/max - узкий зубец не теряется)

-- шрифты по размеру (создаются один раз)
local fonts = {}
local function Font(size)
	size = math.max(10, math.floor(size))
	local name = "RemECG" .. size
	if not fonts[size] then
		fonts[size] = true
		surface.CreateFont(name, {font = "VT323", size = size, weight = 400, antialias = false, extended = true})
	end
	return name
end

-- кусочно-линейная форма: {t0, v0, t1, v1, ...}
local function PL(t, p)
	if t <= p[1] then return p[2] end
	for i = 3, #p, 2 do
		if t <= p[i] then
			local t0, v0 = p[i - 2], p[i - 1]
			return Lerp((t - t0) / math.max(p[i] - t0, 1e-4), v0, p[i + 1])
		end
	end
	return p[#p]
end

-- время в секундах (у VT и волн - доли периода). 0 - изолиния, 1 - верх зубца
local SHAPE = {
	fast = {0, 0, 0.03, 0.12, 0.06, 0.12, 0.08, 0, 0.10, 0, 0.115, 1, 0.13, 1, 0.16, -0.6, 0.18, -0.6, 0.20, 0,
		0.24, 0, 0.25, 0.18, 0.33, 0.18, 0.34, 0},
	slow = {0, 0, 0.02, 0.1, 0.07, 0.1, 0.09, 0, 0.13, 0.35, 0.16, 0.9, 0.19, 1, 0.22, 0.9, 0.25, 0.2, 0.28, -0.45,
		0.31, -0.45, 0.34, 0, 0.40, 0.05, 0.43, 0.22, 0.62, 0.22, 0.66, 0.1, 0.70, 0},
	normal = {0, 0, 0.03, 0.12, 0.07, 0.12, 0.09, 0, 0.12, 0, 0.135, 1, 0.15, 1, 0.175, -0.45, 0.19, -0.45,
		0.205, 0.35, 0.26, 0.3, 0.32, 0.15, 0.36, 0.15, 0.40, 0},
	vt = {0, -0.55, 0.42, 0.85, 0.52, 0.85, 0.95, -0.55, 1, -0.55},
	wave = {0, -0.2, 0.3, 0.48, 0.42, 0.48, 0.55, 0.29, 0.62, 0.32, 0.85, -0.2, 1, -0.2},
}
local SHAPE_LEN = {fast = 0.34, slow = 0.70, normal = 0.40}

local function Rhythm(org)
	if not org then return "normal", 70, 0 end
	local fib = isnumber(org.fib) and org.fib or (org.arrhythmia or 0) * 100
	local hr = org.heartbeat or 70
	if org.heartstop or hr <= 0 or fib >= 99 then return "flat", 0, fib end
	if fib > 75 then return "vf", hr, fib end
	if fib > 50 then return "vt", hr, fib end
	if fib > 15 then return "arr", hr, fib end
	if hr > 110 then return "fast", hr, fib end
	if hr < 60 then return "slow", hr, fib end
	return "normal", hr, fib
end

-- текущий удар
local beatT, beatLen, beatAmp = 0, 0.85, 1

local function NextBeat(kind, hr, fib)
	beatT, beatAmp = 0, 1
	if kind == "vt" then
		beatLen = 60 / math.Clamp(hr, 160, 240)
	elseif kind == "arr" then
		beatLen = 60 / math.Clamp(hr * 2.2, 200, 320) * math.Rand(0.85, 1.15)
		beatAmp = math.Rand(0.8, 1.1)
	elseif kind == "vf" then
		local k = math.Clamp((fib - 75) / 24, 0, 1) -- к 100% слабеет
		beatLen = 60 / math.Rand(300, 380)
		beatAmp = math.Rand(0.6, 1.2) * (1 - k * 0.7)
	else
		beatLen = 60 / math.Clamp(hr, 20, 300)
	end
end

local function Sample(kind, hr, fib, dt)
	if kind == "flat" then beatT = 0 return 0 end
	beatT = beatT + dt
	if beatT >= beatLen then NextBeat(kind, hr, fib) end
	if kind == "vt" then return PL(beatT / beatLen, SHAPE.vt) end
	if kind == "arr" or kind == "vf" then return PL(beatT / beatLen, SHAPE.wave) * beatAmp end
	-- быстрый удар сжимается, если не влезает в период
	local s = math.min(1, beatLen * 0.92 / SHAPE_LEN[kind])
	return PL(beatT / s, SHAPE[kind])
end

-- столбики пикселей: min / max / последнее значение за время столбика
local cols, C, head, colT, acc, lastTime = {}, 0, 1, 0, 0, nil

local function Reset(n)
	C, head, colT = n, 1, 0
	for i = 1, n do cols[i] = {0, 0, 0} end
	for i = n + 1, #cols do cols[i] = nil end
end

local function Update(org, n)
	if n ~= C then Reset(n) end
	local now = RealTime()
	local dt = lastTime and math.min(now - lastTime, 0.25) or 0
	lastTime = now
	local kind, hr, fib = Rhythm(org)
	E.kind = kind
	local colDt = WINDOW / C
	acc = acc + dt * SR
	while acc >= 1 do
		acc = acc - 1
		local v = Sample(kind, hr, fib, 1 / SR)
		colT = colT + 1 / SR
		local c = cols[head]
		if colT >= colDt then
			colT = colT - colDt
			head = head % C + 1
			c = cols[head]
			c[1], c[2], c[3] = v, v, v
		else
			c[1], c[2], c[3] = math.min(c[1], v), math.max(c[2], v), v
		end
	end
end

local LO, HI = -0.7, 1.1 -- диапазон значений по высоте графика

-- x, y, w, h - верхняя часть панели (фон и рамку рисует cl_health_indicator.lua); a - прозрачность 0..1
function E.Draw(x, y, w, h, org, a)
	a = math.Clamp(a or 1, 0, 1)
	x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
	local pad = math.max(2, math.floor(h * 0.05))

	-- текст подгоняется под ширину (по самой длинной строке)
	local fs = h * 0.17
	surface.SetFont(Font(fs))
	local tw = surface.GetTextSize("BPM: 300  SpO2: 100%")
	if tw > w - pad * 2 then fs = fs * (w - pad * 2) / tw end
	local font = Font(fs)
	surface.SetFont(font)
	local _, th = surface.GetTextSize("0")

	-- пиксельная сетка графика
	local P = math.max(2, math.floor(h / 45))
	local gx, gy = x + pad, y + th + pad
	local footH = th
	local gw, gh = w - pad * 2, h - th - footH - pad * 3
	local n, rows = math.floor(gw / P), math.floor(gh / P)
	gx = gx + math.floor((gw - n * P) / 2)
	if n < 4 or rows < 4 then return end
	Update(org, n)
	if a <= 0.01 then return end

	local hr = org and math.Round(org.heartbeat or 0) or 0
	local o2 = org and istable(org.o2) and math.Round(math.Clamp((org.o2[1] or 30) / (org.o2.range or 30) * 100, 0, 100)) or 100
	local sys, dia = org and math.Round(org.systolic or 0) or 0, org and math.Round(org.diastolic or 0) or 0
	local flat = E.kind == "flat"
	if flat then hr = 0 end

	-- поле графика чуть темнее панели
	surface.SetDrawColor(14, 22, 18, 235 * a)
	surface.DrawRect(gx, gy, n * P, rows * P)

	draw.SimpleText(("BPM: %d  SpO2: %d%%"):format(hr, o2), font, x + pad, y + pad * 0.5,
		flat and Color(255, 90, 80, 255 * a) or Color(235, 240, 235, 255 * a))

	local function Row(v)
		return math.Clamp(math.Round((HI - v) / (HI - LO) * (rows - 1)), 0, rows - 1)
	end

	-- два прохода: свечение (только у свежей части), потом сама линия
	local glow = math.max(1, P)
	for pass = 1, 2 do
		local prev
		for i = 1, n do
			local c = cols[(head + i - 1) % n + 1]
			local r1, r2, rl = Row(c[2]), Row(c[1]), Row(c[3])
			if prev then r1, r2 = math.min(r1, prev), math.max(r2, prev) end
			prev = rl
			local fresh = math.Clamp((i / n - 0.5) / 0.4, 0, 1)
			local px, py, ph = gx + (i - 1) * P, gy + r1 * P, (r2 - r1 + 1) * P
			if pass == 1 then
				if fresh > 0 then
					if flat then
						surface.SetDrawColor(120, 20, 15, 200 * fresh * a)
					else
						surface.SetDrawColor(30, 150, 70, 235 * fresh * a)
					end
					surface.DrawRect(px - glow, py - glow, P + glow * 2, ph + glow * 2)
				end
			else
				if flat then
					surface.SetDrawColor(Lerp(fresh, 170, 255), Lerp(fresh, 40, 80), Lerp(fresh, 30, 60), 255 * a)
				else
					surface.SetDrawColor(Lerp(fresh, 50, 120), Lerp(fresh, 140, 255), Lerp(fresh, 80, 150), Lerp(fresh, 200, 255) * a)
				end
				surface.DrawRect(px, py, P, ph)
			end
		end
	end

	-- светлая полоса снизу с давлением
	local fy = y + h - footH - pad
	surface.SetDrawColor(175, 182, 176, 225 * a)
	surface.DrawRect(gx, fy, n * P, footH)
	draw.SimpleText(("%d/%d mmHg"):format(sys, dia), font, gx + pad, fy + 1, Color(30, 36, 32, 255 * a))
end
