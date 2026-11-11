-- ЭКГ-монитор над силуэтом в осмотре (cl_health_indicator.lua), как в SCAV Prototype: сверху "BPM / SpO2",
-- бегущая кардиограмма, снизу давление. Форма зубцов - по ритму (шкала фибрилляции org.fib, sv_pulse.lua):
--   норма (синусовый ритм, частота = пульс; медленный пульс - длинные паузы, быстрый - сжатые удары),
--   аритмия (> 15%) - удары с неровными промежутками и уродливые широкие "лишние" сокращения,
--   желудочковая тахикардия (> 50%) - ровная частая пила, фибрилляция желудочков (> 75%) - мелкий хаос,
--   слабеющий к 100%, остановка сердца - красная прямая.
hg.ECG = hg.ECG or {}
local E = hg.ECG

E.cv = CreateClientConVar("rem_ecg", "1", true, false, "ECG monitor above the body in the health inspect panel", 0, 1)

-- шрифт под высоту монитора (пересоздаётся, если сменилось разрешение)
local fontSize
local function Font(h)
	local size = math.max(12, math.floor(h * 0.2))
	if size ~= fontSize then
		fontSize = size
		surface.CreateFont("RemECG", {font = "VT323", size = size, weight = 400, antialias = false, extended = true})
	end
	return "RemECG"
end

local SR = 90          -- отсчётов в секунду
local N = 230          -- столько отсчётов на экране (~2.5 с)
local buf = {}
for i = 1, N do buf[i] = 0 end
local head = 0         -- индекс последнего записанного
local acc = 0
local lastTime

-- текущий удар
local beatT, beatLen, beatKind = 0, 0.85, "sinus"
local vfPhase = {math.Rand(0, 6), math.Rand(0, 6), math.Rand(0, 6)}

local function Rhythm(org)
	if not org then return "sinus", 70, 0 end
	local fib = isnumber(org.fib) and org.fib or (org.arrhythmia or 0) * 100
	local hr = org.heartbeat or 70
	if org.heartstop or hr <= 0 then return "flat", 0, fib end
	if fib > 75 then return "vf", hr, fib end
	if fib > 50 then return "vt", hr, fib end
	if fib > 15 then return "af", hr, fib end
	return "sinus", hr, fib
end

local function Tri(x) -- треугольник 0..1..0
	return 1 - math.abs(x * 2 - 1)
end

-- обычный удар: P, QRS, T; s - сжатие по времени (быстрый пульс)
local function Sinus(t, s)
	t = t / s
	if t < 0.08 then return 0.12 * math.sin(math.pi * t / 0.08) end
	if t < 0.14 then return 0 end
	if t < 0.16 then return -0.12 end
	if t < 0.175 then return Lerp((t - 0.16) / 0.015, -0.12, 1) end
	if t < 0.19 then return Lerp((t - 0.175) / 0.015, 1, -0.32) end
	if t < 0.22 then return Lerp((t - 0.19) / 0.03, -0.32, 0) end
	if t < 0.30 then return 0.02 end
	if t < 0.46 then return 0.26 * math.sin(math.pi * (t - 0.30) / 0.16) end
	return 0
end

-- уродливое широкое сокращение (при аритмии)
local function Ectopic(t, s)
	t = t / s
	if t < 0.06 then return Lerp(t / 0.06, 0, 0.9) end
	if t < 0.16 then return Lerp((t - 0.06) / 0.1, 0.9, -0.55) end
	if t < 0.26 then return Lerp((t - 0.16) / 0.1, -0.55, 0.12) end
	if t < 0.45 then return 0.12 * Tri((t - 0.26) / 0.19) end
	return 0
end

local function NextBeat(kind, hr, fib)
	local period = 60 / math.Clamp(hr, 20, 300)
	beatKind = "sinus"
	if kind == "af" then
		period = period * (1 + math.Rand(-0.45, 0.45) * math.min(fib / 50, 1))
		if math.random() < fib / 160 then beatKind = "ectopic" end
	end
	beatLen = math.max(period, 0.2)
	beatT = 0
end

local function Sample(kind, hr, fib, dt)
	if kind == "flat" then return 0 end
	if kind == "vt" then
		-- ровная пила с широкими зубцами
		local period = 60 / math.Clamp(math.max(hr, 150), 150, 260)
		beatT = (beatT + dt) % period
		local x = beatT / period
		return (x < 0.55 and Lerp(x / 0.55, -0.45, 0.85) or Lerp((x - 0.55) / 0.45, 0.85, -0.45)) + math.Rand(-0.03, 0.03)
	end
	if kind == "vf" then
		-- мелкий хаос, к 100% слабеет
		local amp = 0.5 * (1 - math.Clamp((fib - 75) / 25, 0, 1) * 0.65)
		local v = 0
		for i = 1, 3 do
			vfPhase[i] = vfPhase[i] + dt * math.pi * 2 * (4 + i * 1.7 + math.Rand(-0.8, 0.8))
			v = v + math.sin(vfPhase[i]) / i
		end
		return v * amp * 0.6 + math.Rand(-0.06, 0.06) * amp
	end
	beatT = beatT + dt
	if beatT >= beatLen then NextBeat(kind, hr, fib) end
	local s = math.min(1, beatLen / 0.75)
	return (beatKind == "ectopic" and Ectopic or Sinus)(beatT, s)
end

-- дописать отсчёты за прошедшее время
local function Update(org)
	local now = RealTime()
	local dt = lastTime and math.min(now - lastTime, 0.25) or 0
	lastTime = now
	local kind, hr, fib = Rhythm(org)
	E.kind = kind
	acc = acc + dt * SR
	while acc >= 1 do
		acc = acc - 1
		head = head % N + 1
		buf[head] = Sample(kind, hr, fib, 1 / SR)
	end
end

local colBg, colFrame = Color(14, 22, 18, 235), Color(70, 140, 95, 120)
local colText = Color(200, 235, 205)

-- x, y, w, h - коробка монитора; a - прозрачность 0..1
function E.Draw(x, y, w, h, org, a)
	Update(org)
	a = math.Clamp(a or 1, 0, 1)
	if a <= 0.01 then return end
	local hr = org and math.Round(org.heartbeat or 0) or 0
	local o2 = org and istable(org.o2) and math.Round(math.Clamp((org.o2[1] or 30) / (org.o2.range or 30) * 100, 0, 100)) or 100
	local sys, dia = org and math.Round(org.systolic or 0) or 0, org and math.Round(org.diastolic or 0) or 0
	local flat = E.kind == "flat"
	if flat then hr = 0 end

	surface.SetDrawColor(colBg.r, colBg.g, colBg.b, colBg.a * a)
	surface.DrawRect(x, y, w, h)
	surface.SetDrawColor(colFrame.r, colFrame.g, colFrame.b, colFrame.a * a)
	surface.DrawOutlinedRect(x, y, w, h, 1)

	local pad = math.max(3, math.floor(h * 0.04))
	surface.SetFont(Font(h))
	local _, th = surface.GetTextSize("0")
	local tc = Color(colText.r, colText.g, colText.b, 255 * a)
	draw.SimpleText(("BPM: %d   SpO2: %d%%"):format(hr, o2), "RemECG", x + pad, y + pad * 0.5, flat and Color(255, 90, 80, 255 * a) or tc)
	draw.SimpleText(("%d/%d mmHg"):format(sys, dia), "RemECG", x + pad, y + h - th - pad * 0.5, tc)

	-- кардиограмма: старое слева, новое справа (ярче)
	local gx, gw = x + pad, w - pad * 2
	local gy, gh = y + th + pad, h - th * 2 - pad * 2
	local mid = gy + gh * 0.62
	local amp = gh * 0.55
	local step = gw / (N - 1)
	local px, py
	for i = 1, N do
		local idx = (head + i - 1) % N + 1
		local v = buf[idx]
		local cx, cy = gx + (i - 1) * step, math.Clamp(mid - v * amp, gy, gy + gh)
		if px then
			local fresh = i / N
			if flat then
				surface.SetDrawColor(220, 50, 40, 255 * a)
			else
				surface.SetDrawColor(40, 110 + 120 * fresh, 70 + 60 * fresh, (90 + 165 * fresh) * a)
			end
			-- толстая "пиксельная" линия
			surface.DrawLine(px, py, cx, cy)
			surface.DrawLine(px, py + 1, cx, cy + 1)
			surface.DrawLine(px + 1, py, cx + 1, cy)
		end
		px, py = cx, cy
	end
end
