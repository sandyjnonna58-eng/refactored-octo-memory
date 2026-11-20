-- Аппараты жизнеобеспечения: стационарный (ent_life_support) и переносной (weapon_hg_lifesupport_portable).
-- Пока подключён, аппарат дышит за пациента и КАЧАЕТ КРОВЬ вместо сердца (по просьбе - как auto-pump в SCAV): сердце он
-- не запускает - остановившееся так и стоит (на мониторе прямая, плитка остановки), а давление, кровоток и кислород держит
-- аппарат; таймер смерти от остановки сердца не идёт (LS.IsPumping в sv_organism.lua). Завести сердце - как обычно:
-- дефибриллятор, эпинефрин, СЛР. Бьющемуся сердцу помогает (давление/выброс не ниже своих). Качать нечего без крови:
-- давление и выброс тем меньше, чем меньше крови (полностью при 80% объёма). У переносного всё слабее.
hg.LifeSupport = hg.LifeSupport or {}
local LS = hg.LifeSupport

-- o2 - до какой доли от нормы держится кислород; остальное - минимум кровотока (org.pulse), давления и выброса,
-- которые даёт насос аппарата (heartbeat - больше не используется: частоту сердца аппарат не задаёт)
-- blood - сколько крови аппарат понемногу закачивает, мл в секунду (до 5000; у переносного своё - в его SWEP)
LS.FullParams = {o2 = 1, pulse = 65, heartbeat = 70, pressure = 85, output = 1, blood = 4}
local pump_blood_full = 0.8 -- при такой доле объёма крови насос качает в полную силу

-- аппарат качал кровь в этот тик (sv_organism.lua: остановка сердца не запускает таймер смерти)
function LS.IsPumping(org)
	return org and (org.remPumpUntil or 0) > CurTime()
end

-- переносной: раз в секунду тратит 1% батареи и отключается, если пациента утащили дальше трубки
local portable_drain_interval = 1
local portable_tube_length = 130

function LS.Connect(machine, ply)
	if IsValid(ply.LifeSupportMachine) and ply.LifeSupportMachine ~= machine then LS.Disconnect(ply.LifeSupportMachine) end

	machine:SetPatient(ply)
	ply.LifeSupportMachine = machine
	machine:EmitSound("items/medshot4.wav", 65)
	ply:Notify("Something pumps air into your lungs.", 0, "lifesupport_on", 3, nil, Color(150, 220, 255))
end

function LS.Disconnect(machine)
	if not IsValid(machine) then return end

	local ply = machine:GetPatient()
	if IsValid(ply) and ply.LifeSupportMachine == machine then ply.LifeSupportMachine = nil end

	machine:SetPatient(NULL)
	machine:EmitSound("buttons/button10.wav", 65)
end

-- вызывается из "Org Think" Main перед тем, как применяется otrub
function LS.OrganismThink(owner, org)
	local machine = owner.LifeSupportMachine
	if not IsValid(machine) or not owner:Alive() then return end

	local params = machine.LifeSupportParams or LS.FullParams

	if istable(org.o2) then
		local range = org.o2.range or 30
		org.o2[1] = math.max(org.o2[1] or 0, range * params.o2)
	end
	org.CO = 0
	org.lungsfunction = true

	-- понемногу закачивает кровь (по просьбе), до нормы 5000; при кровотечении часть сразу уходит
	if isnumber(org.blood) and org.blood < 5000 then
		org.blood = math.min(org.blood + (params.blood or 2) * (org.timeValue or 0), 5000)
	end

	-- насос вместо сердца: сердце (heartstop, ритм, частота) не трогаем, держим кровоток
	local volume = math.Clamp(((org.blood or 5000) - 900) / 4100 / pump_blood_full, 0, 1)
	org.remPumpUntil = CurTime() + 0.5
	org.pulse = math.max(org.pulse or 0, params.pulse * volume)
	org.bloodPressure = math.max(org.bloodPressure or 0, params.pressure * volume)
	org.cardiacOutput = math.max(org.cardiacOutput or 0, params.output * volume)
	org.myocardialOxygen = math.max(org.myocardialOxygen or 0, params.output * volume) -- сердечная мышца тоже снабжается
	if org.heartstop then
		org.heartstoptime = CurTime() -- без агонального дыхания (sv_pulse.lua - через 30 с остановки)
		org.systolic = math.Round(org.bloodPressure * 1.24)
		org.diastolic = math.Round(org.bloodPressure * 0.88)
	end
end

local function PatientPos(ply)
	local char = hg.GetCurrentCharacter(ply)
	return IsValid(char) and char:WorldSpaceCenter() or ply:WorldSpaceCenter()
end

-- переносные аппараты работают, даже когда убраны в инвентарь: батарея, длина трубки, владелец
timer.Create("rem_lifesupport_portable", portable_drain_interval, 0, function()
	for _, ply in player.Iterator() do
		local machine = ply.LifeSupportMachine
		if not IsValid(machine) or not machine.IsPortableLifeSupport then continue end

		local owner = machine:GetOwner()
		if not IsValid(owner) or not owner:Alive() or not ply:Alive() then
			LS.Disconnect(machine)
		elseif machine:Clip1() <= 0 then
			LS.Disconnect(machine)
			owner:Notify("The life support battery is dead.", 0, "lifesupport_battery", 3, nil, Color(255, 120, 120))
		elseif ply ~= owner and PatientPos(ply):Distance(PatientPos(owner)) > portable_tube_length then
			LS.Disconnect(machine)
		else
			machine:SetClip1(machine:Clip1() - 1)
			machine:EmitSound("buttons/blip1.wav", 45, 140)
		end
	end
end)

-- Alt+E: подключить ближайшего к себе человека (не себя) к ближайшему свободному стационарному аппарату
local quick_machine_range = 200
local colNotify = Color(150, 220, 255)

-- второе значение: есть ли рядом хоть один аппарат (пусть и занятый)
local function NearestFreeMachine(ply)
	local best, bestDist, any
	for _, machine in ipairs(ents.FindByClass("ent_life_support")) do
		local dist = machine:WorldSpaceCenter():Distance(ply:WorldSpaceCenter())
		if dist <= quick_machine_range then
			any = true
			if not IsValid(machine:GetPatient()) and (not bestDist or dist < bestDist) then best, bestDist = machine, dist end
		end
	end
	return best, any
end

local function NearestPatient(ply, machine)
	local best, bestDist
	local from = PatientPos(ply)

	for _, other in player.Iterator() do
		-- трубка должна дотянуться, иначе аппарат сразу отключится
		if other ~= ply and other:Alive() and not IsValid(other.LifeSupportMachine)
			and PatientPos(other):Distance(machine:WorldSpaceCenter()) <= machine.TubeLength * 0.9 then
			local dist = PatientPos(other):Distance(from)
			if not bestDist or dist < bestDist then best, bestDist = other, dist end
		end
	end
	return best
end

hook.Add("KeyPress", "rem_lifesupport_quick", function(ply, key)
	if key ~= IN_USE or not ply:KeyDown(IN_WALK) or not ply:Alive() then return end
	if ply.organism and ply.organism.otrub then return end

	-- смотрит прямо на аппарат - сработает обычное E; у Draco на Alt+E своё действие
	local tr = ply:GetEyeTrace()
	-- на радио Alt+E открывает его меню
	if IsValid(tr.Entity) and (tr.Entity:GetClass() == "ent_life_support" or tr.Entity.IsRemRadio) then return end
	local wep = ply:GetActiveWeapon()
	if IsValid(wep) and wep:GetClass() == "weapon_draco" then return end

	local machine, anyNearby = NearestFreeMachine(ply)
	if not machine then
		-- аппаратов рядом нет совсем - молчим, чтобы не мешать другим действиям на Alt+E
		if anyNearby then ply:Notify("Every life support machine nearby is busy.", 0, "lifesupport_quick", 2, nil, colNotify) end
		return
	end

	local patient = NearestPatient(ply, machine)
	if not patient then
		ply:Notify("Nobody close enough to connect.", 0, "lifesupport_quick", 2, nil, colNotify)
		return
	end

	LS.Connect(machine, patient)
	ply:Notify("You connected " .. patient:Nick() .. " to life support.", 0, "lifesupport_quick", 3, nil, colNotify)
end)
