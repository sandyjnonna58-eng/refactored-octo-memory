local urge_threshold = 0.35
local urge_roll_time_min = 3
local urge_roll_time_max = 7
local urge_chance_min = 0.35
local urge_chance_max = 0.9
local urge_duration = 4
local urge_presses_needed = 12
local urge_initial_delay = 8
local urge_adrenaline_threshold = 1.5
local urge_adrenaline_delay = 3
-- сколько держится поза после проигранного позыва: курок игрок жмёт сам
local urge_hold_time = 10

util.AddNetworkString("rem_urges_press")
util.AddNetworkString("rem_urges_end")

local function findSuicideWeapon(ply)
	local melee

	for _, wep in ipairs(ply:GetWeapons()) do
		if not IsValid(wep) or not wep.CanSuicide then continue end

		if wep.ismelee2 or wep.Base == "weapon_melee" then return wep end
		if ishgweapon(wep) and not melee then melee = wep end
	end

	return melee
end

local function hasSuicideWeapon(ply)
	return IsValid(findSuicideWeapon(ply))
end

local function autoEquipSuicideWeapon(ply)
	local wep = ply.GetActiveWeapon and ply:GetActiveWeapon()
	if IsValid(wep) and wep.CanSuicide then return true end

	local found = findSuicideWeapon(ply)
	if not IsValid(found) then return false end

	ply:SelectWeapon(found:GetClass())
	if ply.SetActiveWeapon then ply:SetActiveWeapon(found) end

	return true
end

local function endHold(ply)
	if not IsValid(ply) then return end

	timer.Remove("rem_urges_hold_" .. ply:EntIndex())
	if ply:GetNWFloat("rem_suicide_hold", 0) == 0 then return end

	ply:SetNWFloat("rem_suicide_hold", 0)
	ply.suiciding = false
end

-- позыв не побороли: оружие остаётся у головы, выстрелить или ударить игрок должен сам
local function startHold(ply)
	if not hasSuicideWeapon(ply) then return end

	autoEquipSuicideWeapon(ply)
	ply.suiciding = true
	ply:SetNWFloat("rem_suicide_hold", CurTime() + urge_hold_time)

	timer.Create("rem_urges_hold_" .. ply:EntIndex(), urge_hold_time, 1, function()
		endHold(ply)
	end)
end

local function endUrge(ply, cancel)
	if not IsValid(ply) or not ply:IsPlayer() then return end

	local resisted = (ply.remUrgePresses or 0) >= urge_presses_needed
	local manual = ply.remUrgeManual

	ply.remUrgeEnd = nil
	ply.remUrgeManual = nil
	ply.remUrgePresses = 0
	ply:SetNWFloat("rem_urges_end", 0)
	ply.suiciding = false

	if not manual then
		ply.remUrgeCooldown = CurTime() + math.Rand(15, 25)
	end

	net.Start("rem_urges_end")
	net.Send(ply)

	local org = ply.organism
	if org then
		org.depression = math.max((org.depression or 0) - 0.2, 0)

		if not manual then
			org.selfharmNextRoll = math.max(org.selfharmNextRoll or 0, ply.remUrgeCooldown)
		end
	end

	if not cancel and not resisted and ply:Alive() then
		startHold(ply)
	end
end

local function startUrge(ply, manual)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	local org = ply.organism
	if not org or not org.alive or org.heartstop or org.otrub then return end
	if not hasSuicideWeapon(ply) then return end
	if (org.adrenaline or 0) >= urge_adrenaline_threshold then return end
	if ply.remUrgeEnd then return end
	if not manual and (ply.remUrgeCooldown or 0) > CurTime() then return end

	if ply.selfharming then
		hg.organism.EndSelfHarm(ply)
	end

	autoEquipSuicideWeapon(ply)

	ply.suiciding = true
	ply.remUrgeManual = manual or nil
	ply.remUrgePresses = 0
	ply.remUrgeEnd = CurTime() + urge_duration
	ply:SetNWFloat("rem_urges_end", ply.remUrgeEnd)

	timer.Create("rem_urges_end_" .. ply:EntIndex(), urge_duration, 1, function()
		if not IsValid(ply) or not ply.remUrgeEnd then return end

		endUrge(ply)
	end)
end

hg.StartSuicideUrge = startUrge

timer.Create("rem_suicideurges_roll", 1, 0, function()
	local now = CurTime()

	for _, ply in ipairs(player.GetAll()) do
		local org = ply.organism
		if not org or not org.alive or org.heartstop or org.otrub then continue end
		if hg.organism.IsMentalDisabled and hg.organism.IsMentalDisabled() then continue end
		if ply.remUrgeEnd then
			if (org.adrenaline or 0) >= urge_adrenaline_threshold then
				endUrge(ply, true)
				ply.remUrgeNextRoll = now + urge_adrenaline_delay
			end

			continue
		end
		if (ply.remUrgeCooldown or 0) > now then continue end
		if ply.suiciding or ply.selfharming then continue end
		if (org.adrenaline or 0) >= urge_adrenaline_threshold then
			ply.remUrgeNextRoll = now + urge_adrenaline_delay
			continue
		end

		local dep = org.depression or 0
		if dep <= urge_threshold then continue end
		if not hasSuicideWeapon(ply) then continue end

		ply.remUrgeNextRoll = ply.remUrgeNextRoll or now + math.Rand(urge_initial_delay * 0.5, urge_initial_delay)
		if ply.remUrgeNextRoll > now then continue end

		ply.remUrgeNextRoll = now + math.Rand(urge_roll_time_min, urge_roll_time_max)

		local frac = math.Clamp((dep - urge_threshold) / (1 - urge_threshold), 0, 1)

		if math.Rand(0, 1) <= Lerp(frac, urge_chance_min, urge_chance_max) then
			startUrge(ply)
		end
	end
end)

net.Receive("rem_urges_press", function(_, ply)
	if not IsValid(ply) then return end
	if not ply.remUrgeEnd or ply.remUrgeEnd < CurTime() then return end

	ply.remUrgePresses = (ply.remUrgePresses or 0) + 1
end)

hook.Add("PlayerDeath", "REM_UrgesCleanup", function(ply)
	ply.remUrgeManual = nil
	endHold(ply)

	if not ply.remUrgeEnd then return end

	timer.Remove("rem_urges_end_" .. ply:EntIndex())

	ply.remUrgeEnd = nil
	ply.remUrgePresses = 0
	ply:SetNWFloat("rem_urges_end", 0)
	ply.suiciding = false
end)

hook.Add("PlayerDisconnected", "REM_UrgesCleanup", function(ply)
	timer.Remove("rem_urges_hold_" .. ply:EntIndex())
	if not ply.remUrgeEnd then return end

	timer.Remove("rem_urges_end_" .. ply:EntIndex())

	ply.remUrgeEnd = nil
end)

-- пока держится поза, оружие не убрать
hook.Add("PlayerSwitchWeapon", "REM_SuicideHold", function(ply, oldWep, newWep)
	if ply:GetNWFloat("rem_suicide_hold", 0) > CurTime() and ply.suiciding then return true end
end)
