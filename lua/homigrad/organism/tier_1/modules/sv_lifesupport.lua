-- Аппараты жизнеобеспечения: стационарный (ent_life_support) и переносной (weapon_hg_lifesupport_portable).
-- Пока подключён, лёгкие и сердце работают за пациента; у переносного всё слабее.
hg.LifeSupport = hg.LifeSupport or {}
local LS = hg.LifeSupport

-- o2 - до какой доли от нормы держится кислород; остальное - минимум пульса, давления и выброса сердца
LS.FullParams = {o2 = 1, pulse = 65, heartbeat = 70, pressure = 85, output = 1}

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

	org.heartstop = false
	org.fibrillation = false
	org.arrhythmia = math.min(org.arrhythmia or 0, 1 - params.output)
	org.myocardialOxygen = math.max(org.myocardialOxygen or 0, params.output)
	org.pulse = math.max(org.pulse or 0, params.pulse)
	org.heartbeat = math.max(org.heartbeat or 0, params.heartbeat)
	org.bloodPressure = math.max(org.bloodPressure or 0, params.pressure)
	org.cardiacOutput = math.max(org.cardiacOutput or 0, params.output)
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
	if IsValid(tr.Entity) and tr.Entity:GetClass() == "ent_life_support" then return end
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
