-- Мутации для экспериментов. Ставятся на станции мутаций (ent_mutation_station), сбрасываются со смертью.
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

M.MaxSlots = 2

M.List = {
	{id = "painresist", name = "Pain Endurance", desc = "Dulled nerve endings: you feel 40% less pain."},
	{id = "infect", name = "Infection", desc = "Hold a person lying on the ground to slowly turn them into an experiment."},
	{id = "clotting", name = "Clotting", desc = "Your yellow blood thickens: you bleed half as fast."},
}

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

function M.Count(ply)
	return table.Count(M.Get(ply))
end

function M.CanUse(ply)
	return IsValid(ply) and ply:Alive() and ply.PlayerClassName == "experiment"
end
