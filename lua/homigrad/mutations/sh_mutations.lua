-- Мутации для экспериментов и имплант управления для людей. Ставятся на станции мутаций (ent_mutation_station),
-- сбрасываются со смертью.
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

M.MaxSlots = 3

M.List = {
	{id = "painresist", name = "Pain Endurance", desc = "Dulled nerve endings: you feel 40% less pain."},
	{id = "clotting", name = "Clotting", desc = "Your yellow blood thickens: you bleed half as fast."},
	{id = "infect", name = "Infection", desc = "Hold a person lying on the ground to slowly turn them into an experiment."},
	{id = "brute", name = "Brute Strength", desc = "Your hits and melee attacks deal twice the damage."},
	{id = "leaper", name = "Leaper", desc = "Reinforced tendons: you jump 50% higher."},
	{id = "tireless", name = "Tireless", desc = "Your stamina drains half as fast."},
	{id = "regen", name = "Bone Knitting", desc = "Broken bones and damaged organs slowly mend on their own."},
	{id = "senses", name = "Heightened Senses", desc = "You sense living people nearby, even through walls."},
}

-- имплант для людей: управление экспериментами через меню на Q
M.Implant = {id = "control", name = "Control Implant", desc = "A chip in your skull. Controls experiments from the Q menu: pain, paralysis, vomiting, heart, suicide, death."}

M.ByID = {}
for _, mutation in ipairs(M.List) do M.ByID[mutation.id] = mutation end

function M.Get(ply)
	local owned = {}
	if not IsValid(ply) then return owned end

	for id in string.gmatch(ply:GetNWString("hg_mutations", ""), "[^,]+") do owned[id] = true end
	return owned
end

function M.Has(ply, id)
	return M.Get(ply)[id] == true
end

function M.CanUse(ply)
	return IsValid(ply) and ply:Alive() and ply.PlayerClassName == "experiment"
end

function M.HasImplant(ply)
	return IsValid(ply) and ply:Alive() and ply:GetNWBool("hg_control_implant", false)
end

function M.IsExperiment(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:Alive() and ply.PlayerClassName == "experiment"
end

-- команды импланта: кулдаун в секундах
M.ControlRange = 2500
M.Commands = {
	shock = {name = "Pain Shock", cooldown = 6},
	paralyze = {name = "Paralyze", cooldown = 20},
	terminate = {name = "Terminate", cooldown = 90},
	locate = {name = "Locate All", cooldown = 30},
	vomit = {name = "Induce Vomiting", cooldown = 15},
	heartstop = {name = "Stop Heart", cooldown = 120},
	suicide = {name = "Force Suicide", cooldown = 120},
}

-- порядок в подменю цели
M.TargetCommands = {"shock", "paralyze", "vomit", "heartstop", "suicide", "terminate"}
