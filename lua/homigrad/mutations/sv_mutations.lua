-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_mutations.lua
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

util.AddNetworkString("rem_mutation_menu")
util.AddNetworkString("rem_mutation_install")
util.AddNetworkString("rem_control_command")
util.AddNetworkString("rem_control_locate")

local station_use_dist = 120
local install_pain = 25
local install_cooldown = 2

local pain_resist = 0.4
local clotting_bleed_mul = 0.5
local brute_melee_mul = 2
local leaper_jump_mul = 1.5
local tireless_stamina_mul = 0.5

-- Bone Knitting: за сколько секунд срастается полностью сломанная кость
local regen_time = 90
local regen_keys = {"lleg", "rleg", "larm", "rarm", "pelvis", "chest", "spine1", "spine2", "spine3", "skull", "jaw", "liver", "heart", "stomach", "intestines"}

-- заражение: сколько секунд держать лежащего, и как быстро проходит, если отпустить
local infect_time = 25
local infect_decay_time = 120
local tick_interval = 0.5

local infectStages = {
	{0.3, "Something is crawling under your skin."},
	{0.7, "Your blood... it's turning yellow."},
}

local vomit_times = 3
local vomit_interval = 1.6

local colMutation = Color(230, 190, 0)
local colControl = Color(255, 120, 120)

local applyEffect = {
	painresist = function(ply, org) org.painResist = pain_resist end,
	clotting = function(ply, org) org.bleedingmul = clotting_bleed_mul end,
	brute = function(ply) ply.MeleeDamageMul = brute_melee_mul end,
	leaper = function(ply) ply.JumpPowerMul = leaper_jump_mul end,
	tireless = function(ply) ply.StaminaExhaustMul = tireless_stamina_mul end,
}

local function SetMutations(ply, owned)
	local ids = {}
	for _, mutation in ipairs(M.List) do
		if owned[mutation.id] then ids[#ids + 1] = mutation.id end
	end

	ply:SetNWString("hg_mutations", table.concat(ids, ","))
end

function M.Clear(ply)
	-- без мутаций ничего не трогаем: множители могли поставить другие классы
	if not IsValid(ply) or ply:GetNWString("hg_mutations", "") == "" then return end

	ply:SetNWString("hg_mutations", "")
	ply.MeleeDamageMul = nil
	ply.JumpPowerMul = nil
	ply.StaminaExhaustMul = nil

	local org = ply.organism
	if org then
		org.painResist = nil
		org.bleedingmul = 1
	end
end

function M.ClearImplant(ply)
	if IsValid(ply) then ply:SetNWBool("hg_control_implant", false) end
end

-- эксперимент получает меню мутаций, человек - только имплант управления
function M.OpenMenu(ply, station)
	if not IsValid(ply) or not ply:Alive() then return end

	net.Start("rem_mutation_menu")
		net.WriteEntity(station)
		net.WriteBool(not M.CanUse(ply))
	net.Send(ply)
end

local function InstallFeedback(ply, station, org, name)
	org.painadd = org.painadd + install_pain
	station:EmitSound("ambient/energy/zap7.wav", 70)
	ply:Notify("Something inside you has changed: " .. name .. ".", 0, "mutation_installed", 3, nil, colMutation)
end

net.Receive("rem_mutation_install", function(len, ply)
	local station = net.ReadEntity()
	local id = net.ReadString()

	if not IsValid(ply) or not ply:Alive() then return end
	if not IsValid(station) or station:GetClass() ~= "ent_mutation_station" then return end
	if ply:EyePos():Distance(station:WorldSpaceCenter()) > station_use_dist then return end
	if (ply.mutationNextInstall or 0) > CurTime() then return end

	local org = ply.organism
	if not org then return end

	if id == M.Implant.id then
		if M.CanUse(ply) or M.HasImplant(ply) then return end

		ply.mutationNextInstall = CurTime() + install_cooldown
		ply:SetNWBool("hg_control_implant", true)
		InstallFeedback(ply, station, org, M.Implant.name)
		return
	end

	local mutation = M.ByID[id]
	if not mutation or not M.CanUse(ply) then return end

	local owned = M.Get(ply)
	if owned[id] or table.Count(owned) >= M.MaxSlots then return end

	ply.mutationNextInstall = CurTime() + install_cooldown
	owned[id] = true
	SetMutations(ply, owned)
	if applyEffect[id] then applyEffect[id](ply, org) end

	InstallFeedback(ply, station, org, mutation.name)
end)

hook.Add("Org Clear", "rem_mutations", function(org)
	org.experimentInfection = 0
	org.painResist = nil

	local owner = org.owner
	if IsValid(owner) and owner:IsPlayer() then
		M.Clear(owner)
		M.ClearImplant(owner)
	end
end)

hook.Add("PlayerDeath", "rem_mutations", function(ply)
	M.ClearImplant(ply)
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
			victim:Notify(stage[2], 0, "experiment_infection_" .. i, 3, nil, colMutation)
		end
	end

	if org.experimentInfection >= 1 then
		org.experimentInfection = 0
		M.ClearImplant(victim)
		victim:SetPlayerClass("experiment")
		victim:Notify("You are one of them now.", 0, "experiment_infection_done", 4, nil, colMutation)
		infector:Notify(victim:Nick() .. " is one of us now.", 0, "experiment_infector_done", 3, nil, colMutation)
	end
end

local function Regenerate(org, amount)
	for _, key in ipairs(regen_keys) do
		if isnumber(org[key]) and org[key] > 0 then org[key] = math.max(org[key] - amount, 0) end
	end

	for _, key in ipairs({"lungsL", "lungsR"}) do
		local lung = org[key]
		if istable(lung) and isnumber(lung[1]) then lung[1] = math.max(lung[1] - amount, 0) end
	end
end

timer.Create("rem_mutation_tick", tick_interval, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		local org = ply.organism
		if not org then continue end

		if M.CanUse(ply) and org.alive then
			local owned = M.Get(ply)

			if owned.infect and not org.otrub then
				local victim = GetHeldVictim(ply)
				if victim then Infect(victim, ply, tick_interval / infect_time) end
			end

			-- последний бой запрещает лечение
			local lastBattle = hg.LastBattle and hg.LastBattle.IsActiveFor and hg.LastBattle.IsActiveFor(ply)
			if owned.regen and not lastBattle then Regenerate(org, tick_interval / regen_time) end
		end

		if (org.experimentInfection or 0) > 0 and (ply.mutationInfectedAt or 0) + 1 < now then
			org.experimentInfection = math.max(org.experimentInfection - tick_interval / infect_decay_time, 0)
		end
	end
end)

-- имплант управления: команды из меню на Q
local runCommand = {
	shock = function(ply, target)
		local org = target.organism
		if org then org.painadd = org.painadd + 45 end
		hg.LightStunPlayer(target, 2)
		target:EmitSound("ambient/energy/spark" .. math.random(1, 6) .. ".wav", 70)
		target:Notify("A signal burns through your skull.", 0, "control_shock", 2, nil, colControl)
	end,
	paralyze = function(ply, target)
		hg.StunPlayer(target, 6)
		target:EmitSound("ambient/energy/zap" .. math.random(1, 3) .. ".wav", 70)
		target:Notify("Your body stops obeying you.", 0, "control_paralyze", 3, nil, colControl)
	end,
	terminate = function(ply, target)
		target:EmitSound("ambient/energy/zap9.wav", 80)
		target:Kill()
		ply:Notify(target:Nick() .. " has been terminated.", 0, "control_terminate", 3, nil, colControl)
	end,
	-- рвота несколько раз подряд
	vomit = function(ply, target)
		target:Notify("Your stomach turns inside out.", 0, "control_vomit", 3, nil, colControl)
		for i = 0, vomit_times - 1 do
			timer.Simple(i * vomit_interval, function()
				if IsValid(target) and target:Alive() then hg.organism.Vomit(target) end
			end)
		end
	end,
	-- сердце встаёт: без СЛР/дефибриллятора эксперимент умрёт
	heartstop = function(ply, target)
		local org = target.organism
		if not org then return false end

		org.heartstop = true
		target:EmitSound("ambient/energy/zap" .. math.random(1, 3) .. ".wav", 70)
		target:Notify("Your chest goes still.", 0, "control_heartstop", 3, nil, colControl)
		ply:Notify(target:Nick() .. "'s heart has stopped.", 0, "control_heartstop", 3, nil, colControl)
	end,
	-- сразу поза "оружие у горла/головы" без борьбы: 20 секунд, потом само
	suicide = function(ply, target)
		if not hg.ForceSuicide or not hg.ForceSuicide(target) then
			ply:Notify(target:Nick() .. " has nothing to kill itself with.", 0, "control_suicide", 3, nil, colControl)
			return false
		end

		target:Notify("Do it. Do it now.", 0, "control_suicide", 3, nil, colControl)
	end,
}

net.Receive("rem_control_command", function(len, ply)
	local cmd = net.ReadString()
	local target = net.ReadEntity()
	local command = M.Commands[cmd]

	if not command or not M.HasImplant(ply) or M.CanUse(ply) then return end

	ply.controlCooldowns = ply.controlCooldowns or {}
	local readyAt = ply.controlCooldowns[cmd] or 0
	if readyAt > CurTime() then
		ply:Notify("The implant is recharging (" .. math.ceil(readyAt - CurTime()) .. "s).", 0, "control_cooldown", 2, nil, colControl)
		return
	end

	if cmd == "locate" then
		local found = {}
		for _, target in player.Iterator() do
			if M.IsExperiment(target) then found[#found + 1] = target end
		end

		net.Start("rem_control_locate")
			net.WriteUInt(#found, 8)
			for _, target in ipairs(found) do
				net.WriteVector(hg.GetCurrentCharacter(target):WorldSpaceCenter())
				net.WriteString(target:Nick())
			end
		net.Send(ply)
	else
		if not M.IsExperiment(target) then return end
		if ply:GetPos():Distance(target:GetPos()) > M.ControlRange then return end

		-- false - команда не сработала, кулдаун не тратим
		if runCommand[cmd](ply, target) == false then return end
	end

	ply.controlCooldowns[cmd] = CurTime() + command.cooldown
end)
