-- Давление и пульс с монитора осмотра (cl_ecg.lua: BPM и систолическое mmHg) действуют на самого игрока.
-- Здесь только уровни 0..1 - их одинаково считают сервер (sv_cardio.lua: скорость, выносливость, головная боль,
-- кровь из носа, падение) и клиент (cl_cardio.lua: темнеет в глазах, стучит в висках, удар сердца толкает прицел).
hg.Cardio = hg.Cardio or {}
local C = hg.Cardio

-- систолическое давление (норма ~120-150, sv_pulse.lua: bloodPressure * 1.38 + пульс * 0.12)
C.low_from, C.low_full = 100, 65    -- низкое: с 100 слабость, к 65 - в полную силу
C.high_from, C.high_full = 165, 215 -- высокое: с 165 болит голова, к 215 - в полную силу
-- частота сердца
C.tachy_from, C.tachy_full = 130, 200 -- сердце колотится
C.brady_from, C.brady_full = 55, 30   -- редкий пульс - слабость

local function R(v, a, b) return math.Clamp((v - a) / (b - a), 0, 1) end

-- тест rem_test_bp (sh_remtests.lua): сервер подменяет org.systolic / org.heartbeat, клиенту уходят они же
function C.Levels(org, out)
	out = out or {}
	out.low, out.high, out.tachy, out.brady = 0, 0, 0, 0
	if not org or org.heartstop or org.alive == false then return out end
	local sys, hr = tonumber(org.systolic) or 120, tonumber(org.heartbeat) or 70
	out.sys, out.hr = sys, hr
	out.low = R(sys, C.low_from, C.low_full)
	out.high = R(sys, C.high_from, C.high_full)
	if hr > 0 then
		out.tachy = R(hr, C.tachy_from, C.tachy_full)
		out.brady = R(hr, C.brady_from, C.brady_full)
	end
	return out
end
