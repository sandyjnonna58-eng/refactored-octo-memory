-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_mutations.lua
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

util.AddNetworkString("rem_mutation_menu")
util.AddNetworkString("rem_mutation_install")

local station_use_dist = 120
local install_pain = 25
local install_cooldown = 2

local pain_resist = 0.4
local clotting_bleed_mul = 0.5

-- заражение: сколько секунд держать лежащего, и как быстро проходит, если отпустить
local infect_time = 25
local infect_decay_time = 120
local infect_interval = 0.5

local infectStages = {
	{0.3, "Something is crawling under your skin."},
	{0.7, "Your blood... it's turning yellow."},
}

local applyEffect = {
	painresist = function(ply, org) org.painResist = pain_resist end,
	clotting = function(ply, org) org.bleedingmul = clotting_bleed_mul end,
}

local function SetMutations(ply, owned)
	local ids = {}
	for _, mutation in ipairs(M.List) do
		if owned[mutation.id] then ids[#ids + 1] = mutation.id end
	end

	ply:SetNWString("hg_mutations", table.concat(ids, ","))
end

function M.Clear(ply)
	if not IsValid(ply) then return end

	ply:SetNWString("hg_mutations", "")

	local org = ply.organism
	if org then
		org.painResist = nil
		org.bleedingmul = 1
	end
end

function M.OpenMenu(ply, station)
	if not M.CanUse(ply) then
		ply:Notify("The station doesn't react to you.", 0, "mutation_station", 2)
		return
	end

	net.Start("rem_mutation_menu")
		net.WriteEntity(station)
	net.Send(ply)
end

net.Receive("rem_mutation_install", function(len, ply)
	local station = net.ReadEntity()
	local id = net.ReadString()
	local mutation = M.ByID[id]

	if not mutation or not M.CanUse(ply) then return end
	if not IsValid(station) or station:GetClass() ~= "ent_mutation_station" then return end
	if ply:EyePos():Distance(station:WorldSpaceCenter()) > station_use_dist then return end
	if (ply.mutationNextInstall or 0) > CurTime() then return end

	local owned = M.Get(ply)
	if owned[id] or table.Count(owned) >= M.MaxSlots then return end

	local org = ply.organism
	if not org then return end

	ply.mutationNextInstall = CurTime() + install_cooldown
	owned[id] = true
	SetMutations(ply, owned)
	if applyEffect[id] then applyEffect[id](ply, org) end

	org.painadd = org.painadd + install_pain
	station:EmitSound("ambient/energy/zap7.wav", 70)
	ply:Notify("Something inside you has changed: " .. mutation.name .. ".", 0, "mutation_installed", 3, nil, Color(230, 190, 0))
end)

hook.Add("Org Clear", "rem_mutations", function(org)
	org.experimentInfection = 0
	org.painResist = nil

	if IsValid(org.owner) and org.owner:IsPlayer() then org.owner:SetNWString("hg_mutations", "") end
end)

-- кого сейчас держит заражающий эксперимент: лежащий (в рэгдолле) живой человек
local function GetHeldVictim(ply)
	for _, key in ipairs({"carryent", "carryent2"}) do
		local ent = ply:GetNetVar(key)
		if IsValid(ent) and ent:IsRagdoll() then
			local victim = hg.RagdollOwner(ent)
			if IsValid(victim) and victim ~= ply and victim:Alive() and victim.PlayerClassName ~= "experiment" then return victim end
		end
	end
end

local function Infect(victim, infector, amount)
	local org = victim.organism
	if not org then return end

	local old = org.experimentInfection or 0
	org.experimentInfection = math.min(old + amount, 1)
	victim.mutationInfectedAt = CurTime()

	for i, stage in ipairs(infectStages) do
		if old < stage[1] and org.experimentInfection >= stage[1] then
			victim:Notify(stage[2], 0, "experiment_infection_" .. i, 3, nil, Color(230, 190, 0))
		end
	end

	if org.experimentInfection >= 1 then
		org.experimentInfection = 0
		victim:SetPlayerClass("experiment")
		victim:Notify("You are one of them now.", 0, "experiment_infection_done", 4, nil, Color(230, 190, 0))
		infector:Notify(victim:Nick() .. " is one of us now.", 0, "experiment_infector_done", 3, nil, Color(230, 190, 0))
	end
end

timer.Create("rem_mutation_infection", infect_interval, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		local org = ply.organism
		if not org then continue end

		if M.CanUse(ply) and not org.otrub and M.Has(ply, "infect") then
			local victim = GetHeldVictim(ply)
			if victim then Infect(victim, ply, infect_interval / infect_time) end
		end

		if (org.experimentInfection or 0) > 0 and (ply.mutationInfectedAt or 0) + 1 < now then
			org.experimentInfection = math.max(org.experimentInfection - infect_interval / infect_decay_time, 0)
		end
	end
end)
