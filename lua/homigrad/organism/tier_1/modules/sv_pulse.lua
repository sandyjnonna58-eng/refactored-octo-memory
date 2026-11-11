local min, max, Round, halfValue2 = math.min, math.max, math.Round, util.halfValue2
--local Organism = hg.organism
hg.organism.module.pulse = {}
local module = hg.organism.module.pulse
local Clamp, Approach, Remap = math.Clamp, math.Approach, math.Remap
local CurTime = CurTime
local function getBloodVolume(org)
	return Clamp((org.blood - 900) / 4100, 0, 1)
end

local function getHeartEfficiency(org)
	local heart = Clamp(1 - org.heart, 0, 1)
	local ischemia = Clamp(1 - (org.myocardialOxygen or 1), 0, 1)
	local strain = Clamp(org.heartStrain or 0, 0, 1)
	return Clamp(heart - ischemia * 0.35 - strain * 0.25, 0, 1)
end

-- звуки сердца (sound/rem_heart, cl_main.lua) - раздать игрокам
for _, f in ipairs({"sound/rem_heart/heartbeat_bad.mp3", "sound/rem_heart/arrhythmia.mp3"}) do
	if file.Exists(f, "GAME") then resource.AddSingleFile(f) end
end

-- Сердце по образцу SCAV Prototype (scavprototype.wiki.gg/wiki/Heart_rate). Главное - шкала фибрилляции org.fib 0..100:
--   > 15 - аритмия, > 50 - желудочковая тахикардия, > 75 - фибрилляция желудочков, 100 - остановка сердца.
--   org.arrhythmia (= fib / 100) и org.fibrillation (= fib >= 75) - производные: их по-прежнему читают и меняют
--   дефибриллятор, последний бой, жизнеобеспечение, лечение - такие правки переносятся в шкалу (SyncFibIn).
-- Растёт 1%/с (при пульсе выше 280 - 4%/с), сама спадает 0.75%/с, если причин нет.
--   "Сильные" причины (как в SCAV, без потолка - ведут к остановке): пульс > 200, давление < 88 (начинается < 78),
--   кислород < 60% (начинается < 50%), температура < 28.5 (начинается < 28), принудительная (попадание в сердце).
--   "Мягкие" (плохое сердце) - только до своего потолка: повреждение сердца, ишемия, перегрузка, кровь < 4.0 л
--   (к 3.5 л - до тахикардии), шок 3+, высокое давление.
-- Пульс: +1 за процент фибрилляции, +4 за каждый процент выше 75, +30 выше 95; ниже 20 - сразу остановка.
local fib_rate, fib_rate_fast, fib_fall = 1, 4, 0.75
local fib_fast_hr = 280
local fib_hr_start = 200
local fib_sys_start, fib_sys_rise = 78, 88
local fib_o2_start, fib_o2_rise = 50, 60           -- % кислорода
local fib_temp_start, fib_temp_rise = 28, 28.5
local fib_hr_arrest = 20
local fib_blood_start, fib_blood_full = 4000, 3500
-- сознание при аритмии/тахикардии уходит медленно: не выше 1 - fib/100 * arr_consc_mul, спуск за arr_consc_time с
local arr_consc_from = 25
local arr_consc_mul = 0.9
local arr_consc_time = 45
-- давление и фибрилляция желудочков гасят сознание не сразу, а за столько секунд
local hypotension_consc_time = 15
local fibrillation_consc_time = 6

-- производные поля из шкалы и обратно (правки снаружи - в шкалу)
local function SyncFibOut(org)
	org.fib = Clamp(org.fib or 0, 0, 100)
	org.arrhythmia = org.fib / 100
	org.fibrillation = org.fib >= 75
	org.remArrOut, org.remFibOut = org.arrhythmia, org.fibrillation
end
local function SyncFibIn(org)
	org.fib = org.fib or 0
	if org.remFibOut ~= nil and org.fibrillation ~= org.remFibOut then
		if org.fibrillation then org.fib = math.max(org.fib, 76) org.fibForced = true else org.fib = math.min(org.fib, 74) end
	end
	if org.remArrOut ~= nil and math.abs((org.arrhythmia or 0) - org.remArrOut) > 0.0005 then
		org.fib = Clamp((org.arrhythmia or 0) * 100, 0, 100)
	end
	if org.fib <= 0 then org.fibForced = false end
end
hg.organism.SyncFibOut = SyncFibOut

-- нагрузка на сердце (попадание в сердце и т.п.): сразу добавляет фибрилляции
function hg.organism.AddCardiacStress(org, amount)
	if not org or not isnumber(amount) or amount <= 0 then return 0 end
	SyncFibIn(org)
	org.fib = Clamp(org.fib + amount * 60, 0, 100)
	org.heartStrain = Clamp((org.heartStrain or 0) + amount * 0.45, 0, 1)
	SyncFibOut(org)
	return org.arrhythmia
end

-- сразу фибрилляция желудочков, растёт сама, пока не дефибриллируют (принудительная)
function hg.organism.StartFibrillation(org)
	if not org or org.heartstop then return end
	SyncFibIn(org)
	org.fib = math.max(org.fib, 76)
	org.fibForced = true
	org.fibrillationStart = CurTime()
	SyncFibOut(org)
end

function hg.organism.TryRestartHeartWithCPR(org, cprMul)
	if not org or not org.alive or not org.heartstop or org.deathStateKilled then return false end
	if (org.pulse or 0) <= 15 or (org.brain or 0) >= 0.6 or (org.heart or 0) >= 1 then return false end

	cprMul = cprMul or 1
	local adrenaline = Clamp(org.adrenaline or 0, 0, 3)
	local chance = Clamp(6 * cprMul + adrenaline * 12, 6, 45)

	if math.random(100) > chance then return false end

	org.heartstop = false
	org.fib, org.fibForced = 0, false
	SyncFibOut(org)
	org.heartbeat = Clamp(org.heartbeat or 70, 55, 90)
	org.pulse = max(org.pulse or 0, 25)
	org.bloodPressure = max(org.bloodPressure or 0, 35)
	org.cardiacOutput = max(org.cardiacOutput or 0, 0.35)
	org.myocardialOxygen = max(org.myocardialOxygen or 0, 0.35)

	return true
end

module[1] = function(org)
	org.heart = 0
	org.heartstop = false
	org.pulse = 70 -- that's the blood pressure
	org.heartbeat = 70
	org.bloodPressure = 90
	org.systolic = 120
	org.diastolic = 80
	org.cardiacOutput = 1
	org.arrhythmia = 0
	org.fibrillation = false
	org.fib = 0
	org.fibForced = false
	org.remArrOut, org.remFibOut = 0, false
	org.fibrillationStart = 0
	org.myocardialOxygen = 1
	org.heartStrain = 0
	org.hypertension = 0
	org.hypotension = 0
	org.nextArrhythmiaRoll = 0
	org.lastCardiacPain = 0

	org.tempchanging = 0
	org.exertion = 0
	org.heatbuff = 30 -- seconds of heat supply
	org.needed_temp = 36.7
	org.vessels = 0
	org.alcohol = 0
	org.alcoholStomach = 0
	org.nicotine = 0
	org.nausea = 0
end

function hg.organism.should_gain_fear(org)
	return ((org.pain > 30) or (org.blood < 3000) or (org.bleed > 1))// + (org.just_damaged_bone and ((org.just_damaged_bone + 10 - CurTime()) >= 10) and 10 or 0)
end

module[2] = function(owner, org, timeValue)
	SyncFibIn(org)
	local fib = org.fib
	if not org.heartstop and not org.fibrillation and (org.arrhythmia or 0) < 0.25 and (org.myocardialOxygen or 1) > 0.55 then
		org.heartStrain = Approach(org.heartStrain or 0, 0, timeValue / 45)
	end

	local heart = getHeartEfficiency(org)
	local brain = math.Clamp(1 - org.brain * 1.5,0,1)
	local o2 = org.o2
	local o2 = halfValue2(o2[1], o2.range, o2.k)

	//if org.isPly and not org.otrub and (heart == 0) then org.owner:Notify("My torso hurts.",true,"heart",6) end
	//if org.isPly and not org.otrub and org.heartstop then org.owner:Notify("",true,"heartstop",6) end

	local stamina = org.stamina
	
	local bloodVolume = getBloodVolume(org)
	local oxygenation = Clamp(o2, 0, 1)
	local vascularTone = Clamp(1 + min(org.adrenaline, 3) * 0.12 + max(org.fear, 0) * 0.08 + Clamp(org.shock, 0, 45) / 360, 0.65, 1.55)
	-- сужение сосудов поднимает давление, расширение роняет (modules/sv_vessels.lua)
	vascularTone = vascularTone * (1 - (org.vessels or 0) * 0.18)
	local pressureBase = 92 * bloodVolume * heart * vascularTone * Clamp(Remap(org.temperature, 28, 36.7, 0.55, 1), 0.45, 1.1)
	-- насколько сердце качает при сбитом ритме: аритмия чуть хуже, тахикардия желудочков - плохо, фибрилляция - почти никак
	local rhythmMul = fib < 50 and 1 - fib * 0.002 or fib < 75 and Remap(fib, 50, 75, 0.9, 0.45) or Clamp(Remap(fib, 75, 100, 0.4, 0.05), 0.05, 0.4)
	local defibGrace = (org.defibDeathGrace or 0) > CurTime()
	local arrestPressure = defibGrace and 45 or 0
	local pressure = org.alive and (org.heartstop and arrestPressure or pressureBase * rhythmMul) or 0
	local pressureFallSpeed = defibGrace and 4 or 18
	org.bloodPressure = Approach(org.bloodPressure or pressure, pressure, pressure > (org.bloodPressure or 0) and timeValue * 12 or timeValue * pressureFallSpeed)
	org.pulse = Approach(org.pulse, org.bloodPressure, heart == 0 and timeValue * 10 or timeValue * 5)
	org.systolic = Round(Clamp(org.bloodPressure * 1.38 + (org.heartbeat or 70) * 0.12, 0, 240))
	org.diastolic = Round(Clamp(org.bloodPressure * 0.88, 0, 160))
	org.cardiacOutput = org.heartstop and (defibGrace and Clamp((org.pulse or org.bloodPressure) / 70 * 0.35, 0, 0.45) or 0) or Clamp((org.bloodPressure / 90) * heart * rhythmMul, 0, 1.5)
	if not org.heartstop and not org.fibrillation and (org.arrhythmia or 0) < 0.25 and (org.myocardialOxygen or 1) > 0.65 and org.bloodPressure > 55 then
		org.cardiacOutput = Approach(org.cardiacOutput, Clamp(getBloodVolume(org) * heart, 0, 1), timeValue / 20)
	end
	local myocardialTarget = Clamp(oxygenation * bloodVolume * Clamp(org.bloodPressure / 70, 0, 1.2), 0, 1)
	if org.heartstop and defibGrace then myocardialTarget = math.max(myocardialTarget, 0.25) end
	org.myocardialOxygen = Approach(org.myocardialOxygen or 1, myocardialTarget, timeValue / 8)
	org.hypotension = Approach(org.hypotension or 0, Clamp(Remap(org.bloodPressure, 55, 20, 0, 1), 0, 1), timeValue / 8)
	org.hypertension = Approach(org.hypertension or 0, Clamp(Remap(org.bloodPressure, 115, 155, 0, 1), 0, 1), timeValue / 20)

	org.fearadd = math.Clamp(org.fearadd, 0, 3)

	local heartbeat = org.bloodPressure < 70 and 70 + (70 - org.bloodPressure) * 3 or 70

	local runnin_or_exhausted = org.analgesia < 1 and (org.stamina.sub > 0 or org.stamina[1] < (org.stamina.max * 0.66))
	org.heartbeat = math.Approach(org.heartbeat, math.max(heartbeat - 10, runnin_or_exhausted and ((1 - math.min(1, org.stamina[1] / (org.stamina.max * 1))) * 110 + 90) or 60), !runnin_or_exhausted and timeValue * 2 or timeValue * 15)
	
	heartbeat = heartbeat + (owner.suiciding and 50 or 0)
	heartbeat = heartbeat + 40 * math.max(0, org.fear)
	heartbeat = heartbeat + math.Clamp(org.shock, 0, 40)
	heartbeat = heartbeat + math.Clamp(org.pain, 40, 80) - 40
	heartbeat = heartbeat + 40 * math.min(org.adrenaline, 3)
	heartbeat = heartbeat - 40 * math.min(org.analgesia / 2.5, 1)
	heartbeat = heartbeat + 100 * math.Clamp(math.Remap(org.temperature, 40, 42, 0, 1), 0, 1)
	heartbeat = heartbeat - 160 * (1 - math.Clamp(math.Remap(org.temperature, 28, 36.7, 0, 1), 0, 1))
	heartbeat = heartbeat + (org.hypotension or 0) * 55
	heartbeat = heartbeat - (org.myocardialOxygen and (1 - org.myocardialOxygen) or 0) * 35
	-- фибрилляция гонит пульс (SCAV): +1 за процент, +4 выше 75, +30 выше 95; при аритмии он ещё и скачет
	heartbeat = heartbeat + fib + max(fib - 75, 0) * 4 + max(fib - 95, 0) * 30
	if fib > 15 and fib < 75 then heartbeat = heartbeat + math.Rand(-0.6, 0.6) * fib end

	org.heartbeat = math.Approach(org.heartbeat, heartbeat, heartbeat > org.heartbeat and timeValue * 5 or timeValue * 3)
	
	local ischemia = Clamp(1 - (org.myocardialOxygen or 1), 0, 1)
	-- шкала фибрилляции
	local o2pct = istable(org.o2) and (org.o2[1] or 30) / (org.o2.range or 30) * 100 or 100
	local sys = org.systolic or 120
	local hr = org.heartbeat or 70
	local alive = org.alive and not org.heartstop
	local strongStart = alive and (hr > fib_hr_start or sys < fib_sys_start or o2pct < fib_o2_start or org.temperature < fib_temp_start)
	local strongRise = alive and (hr > fib_hr_start or sys < fib_sys_rise or o2pct < fib_o2_rise or org.temperature < fib_temp_rise or org.fibForced)
	-- "плохое сердце": растёт только до своего потолка
	local ceil = 0
	if (org.heart or 0) >= 0.2 then ceil = max(ceil, 20 + org.heart * 70) end
	if ischemia >= 0.35 then ceil = max(ceil, ischemia * 80) end
	if (org.heartStrain or 0) >= 0.5 then ceil = max(ceil, org.heartStrain * 50) end
	if (org.blood or 5000) < fib_blood_start then ceil = max(ceil, Clamp(Remap(org.blood, fib_blood_start, fib_blood_full, 20, 60), 20, 60)) end
	if (org.shockStage or 0) >= 3 then ceil = max(ceil, 40) end
	if (org.hypertension or 0) >= 0.6 then ceil = max(ceil, 30) end
	if not alive then ceil = 0 end

	if fib <= 0 and (strongStart or ceil > 0) then fib = 1 end
	if fib > 0 then
		if strongRise or fib < ceil then
			fib = fib + timeValue * (hr > fib_fast_hr and fib_rate_fast or fib_rate)
		elseif not org.fibForced then
			fib = max(fib - timeValue * fib_fall, 0)
		end
	end
	fib = Clamp(fib, 0, 100)
	if fib >= 100 and alive then
		org.heartstop = true -- фибрилляция дошла до конца - остановка сердца
	end
	org.fib = fib

	-- аритмия / тахикардия: сначала мысль, потом сознание медленно уходит
	if fib >= arr_consc_from and fib < 75 and alive then
		local cap = Clamp(1 - fib / 100 * arr_consc_mul, 0, 1)
		if org.consciousness > cap then org.consciousness = Approach(org.consciousness, cap, timeValue / arr_consc_time) end
		if org.isPly and not org.otrub and CurTime() >= (org.remArrhythmiaSaid or 0) then
			org.remArrhythmiaSaid = CurTime() + math.Rand(50, 80)
			local lines = fib < 50 and {"My heart... it's skipping beats.", "Something's wrong with my heart.", "My chest... it's fluttering."}
				or {"My heart is racing... I can't breathe.", "It's pounding out of my chest!", "Something is horribly wrong."}
			if org.owner.Notify then org.owner:Notify(lines[math.random(#lines)], true, "arrhythmia", 0, nil, Color(255, 170, 170)) end
		end
	end

	-- фибрилляция желудочков: сердце почти не качает
	if fib >= 75 and alive then
		local cap = Clamp(org.bloodPressure / 55, 0, 1)
		if org.consciousness > cap then org.consciousness = Approach(org.consciousness, cap, timeValue / fibrillation_consc_time) end
		org.o2[1] = max(org.o2[1] - timeValue * 1.8 * Remap(fib, 75, 100, 0.5, 1), 0)
	end
	-- пульс ниже 20 - сразу остановка сердца (SCAV)
	if alive and hr < fib_hr_arrest and org.heartbeat > 0 and (org.consciousness or 1) >= 0 then
		org.heartstop = true
	end
	if org.hypertension > 0.35 then org.heartStrain = Clamp((org.heartStrain or 0) + timeValue * org.hypertension / 360, 0, 1) end
	if ischemia > 0.35 then org.heartStrain = Clamp((org.heartStrain or 0) + timeValue * ischemia / 260, 0, 1) end
	if ischemia > 0.45 and org.isPly and not org.otrub and (org.lastCardiacPain or 0) < CurTime() then
		org.lastCardiacPain = CurTime() + math.Rand(14, 24)
		org.painadd = org.painadd + math.Rand(4, 9) * ischemia
		org.shock = math.max(org.shock, 10 + ischemia * 22)
	end
	if org.hypotension > 0.2 then
		local cap = Clamp(Remap(org.bloodPressure, 20, 65, 0, 1), 0, 1)
		if org.consciousness > cap then org.consciousness = Approach(org.consciousness, cap, timeValue / hypotension_consc_time) end
	end

	if org.heartstop then
		org.heartbeat = 0
		local arrestFallSpeed = defibGrace and 4 or 35
		org.bloodPressure = Approach(org.bloodPressure or 0, arrestPressure, timeValue * arrestFallSpeed)
		org.pulse = Approach(org.pulse or 0, arrestPressure, timeValue * arrestFallSpeed)
		org.fibrillation = false
		org.arrhythmia = 0
		org.fib, org.fibForced = 0, false
	end

	org.fear = math.Approach(org.fear, (org.otrub and 0 or (org.fearadd > 0 and 1 or -1)), org.otrub and timeValue * 0.5 or (org.fearadd > 0 and (org.fear < 0 and timeValue * 5 * org.fearadd or timeValue / 5 * org.fearadd) or (org.fear <= 0 and timeValue / 240 or timeValue / 50)))
	-- less time to start fearing, more time to become calm again
	-- if no fear, in 3 minutes become slightly talkative, so would say random phrases to calm themselves in a current situation
	local gainfear = hg.organism.should_gain_fear(org)
	org.fearadd = math.Approach(org.fearadd, 0, gainfear and timeValue or timeValue / 4.9) -- 15 seconds to stop fearing something and start to calm down
	org.fearadd = math.Approach(org.fearadd, 1, gainfear and timeValue / 5 or 0)
	
	if org.pulse < 10 or org.brain >= 0.6 then org.heartstop = true end
	if org.temperature < 28 or org.temperature > 42 then org.heartstop = true end
	if org.heartstop then
		org.fibrillation = false
		org.arrhythmia = 0
		org.fib, org.fibForced = 0, false
	end

	if org.temperature < 34 or org.temperature > 38 or org.blood < 4000 or org.pain > 20 then
		org.fear = math.max(org.fear, 0)
	end

	-- temperature
	local needed_temp = math.min(math.max(37 * (org.pulse / 45), 35), 36.7)
	local changeRate = timeValue / 60
	-- нагрузка греет, вода охлаждает (sv_bodyheat.lua)
	if hg.organism.BodyHeat then
		local heatOffset, heatRate = hg.organism.BodyHeat(owner, org, timeValue)
		needed_temp = needed_temp + heatOffset
		changeRate = changeRate * heatRate
	end
	changeRate = changeRate * (org.temperature < needed_temp and math.Clamp(org.heatbuff / 60, 1, 2) or 1)
	-- сосуды: расширенные отдают тепло (остываем быстрее, жар от нагрузки меньше), суженные держат тепло
	local vessels = org.vessels or 0
	needed_temp = needed_temp - math.max(vessels, 0) * 0.3
	if org.temperature > needed_temp then changeRate = changeRate * (1 + vessels * 0.6) end
	if math.abs(org.tempchanging) < changeRate then
		org.temperature = math.Approach(org.temperature, needed_temp, changeRate)
	else
		org.needed_temp = needed_temp
	end
	
	if not org.heartstop then
		org.last_heartbeat = CurTime()
	end

	if org.heartstop then
		org.heartstoptime = org.heartstoptime or CurTime()
		if org.isPly then
			//org.owner:Notify("I'm feeling dizzy...", true, "heartstop", 10)
		end
	else
		if org.isPly then
			//org.owner:ResetNotification("heartstop")
		end
		org.heartstoptime = nil
	end

	if org.alive and org.heartstoptime and org.heartstoptime + 30 < CurTime() and (org.lastsoundtime or 0) < CurTime() and org.otrub then
		org.owner:EmitSound("breathing/agonalbreathing_"..math.random(13)..".wav", 60)
		--org.owner:EmitSound("breathing/agonalbreathing_"..math.random(13)..".wav", 50)
		
		org.lastsoundtime = CurTime() + math.random(25,35)
	end

	SyncFibOut(org)
end

--if org.heartstop then org.needotrub = true end --не совсем...
util.AddNetworkString("pulse")
function hg.organism.Pulse(owner, org, timeValue)
	local stamina = org.stamina
	if org.o2[1] > 1 and org.alive and org.heart < 1 and org.brain < 0.6 then
		--org.brain = max(org.brain - timeValue / 30, 0) --regen
	end--brain damage is usually permanent

	if owner:IsPlayer() and owner:Alive() then
		net.Start("pulse")
		net.Send(owner)
	end
end
