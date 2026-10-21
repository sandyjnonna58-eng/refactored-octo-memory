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
