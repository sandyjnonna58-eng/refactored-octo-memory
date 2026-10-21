-- Аппарат жизнеобеспечения (ent_life_support): пока подключён, лёгкие и сердце работают за пациента
hg.LifeSupport = hg.LifeSupport or {}

local min_pulse = 65
local min_heartbeat = 70
local min_pressure = 85

-- вызывается из "Org Think" Main перед тем, как применяется otrub
function hg.LifeSupport.OrganismThink(owner, org)
	if not IsValid(owner.LifeSupportMachine) or not owner:Alive() then return end

	if istable(org.o2) then org.o2[1] = org.o2.range or 30 end
	org.CO = 0
	org.lungsfunction = true

	org.heartstop = false
	org.fibrillation = false
	org.arrhythmia = 0
	org.myocardialOxygen = 1
	org.pulse = math.max(org.pulse or 0, min_pulse)
	org.heartbeat = math.max(org.heartbeat or 0, min_heartbeat)
	org.bloodPressure = math.max(org.bloodPressure or 0, min_pressure)
	org.cardiacOutput = math.max(org.cardiacOutput or 0, 1)
end
