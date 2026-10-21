hg.Skills = hg.Skills or {}
local SK = hg.Skills

util.AddNetworkString("rem_skills_open")
util.AddNetworkString("rem_skills_upgrade")
util.AddNetworkString("rem_skills_perk")
util.AddNetworkString("rem_skills_levelup")

local save_dir = "zcity_skills"

-- опыт за события
local xp_player_kill = 60
local xp_npc_kill = 15

file.CreateDir(save_dir)

local function SavePath(ply)
	return save_dir .. "/" .. ply:SteamID64() .. ".json"
end

local function Data(ply)
	if ply.skillData then return ply.skillData end

	local raw = not ply:IsBot() and file.Read(SavePath(ply), "DATA")
	local data = raw and util.JSONToTable(raw) or {}
	data.xp = tonumber(data.xp) or 0
	data.level = tonumber(data.level) or 0
	data.points = tonumber(data.points) or 0
	data.skills = istable(data.skills) and data.skills or {}
	data.perks = istable(data.perks) and data.perks or {}

	ply.skillData = data
	return data
end

local function Save(ply)
	if ply:IsBot() or not ply.skillData then return end
	file.Write(SavePath(ply), util.TableToJSON(ply.skillData))
end

-- навыки, которые живут на организме, сбрасываются при возрождении - их ставим заново
function SK.Apply(ply)
	if not IsValid(ply) then return end

	ply.SkillMeleeMul = 1 + SK.Bonus(ply, "strength")
	ply.SkillStaminaMul = 1 - SK.Bonus(ply, "endurance")
	ply:SetNWFloat("SkillJumpMul", 1 + SK.Bonus(ply, "agility"))
	ply:SetNWFloat("SkillRecoilMul", 1 - SK.Bonus(ply, "marksman"))
	ply:SetNWFloat("SkillSpeedMul", 1 + SK.Bonus(ply, "runner"))
	ply.SkillReloadMul = 1 - SK.Bonus(ply, "quickhands")
	ply.SkillMedicMul = 1 + SK.Bonus(ply, "medic")

	if ply.organism then
		ply.organism.skillPainResist = SK.Bonus(ply, "toughness")
		ply.organism.skillBleedMul = 1 - SK.Bonus(ply, "vitality")
	end
end

local function Sync(ply)
	local data = Data(ply)
	ply:SetNWInt("skill_xp", data.xp)
	ply:SetNWInt("skill_level", data.level)
	ply:SetNWInt("skill_points", data.points)

	for _, skill in ipairs(SK.List) do
		ply:SetNWInt("skill_" .. skill.id, math.Clamp(tonumber(data.skills[skill.id]) or 0, 0, SK.MaxRank))
	end

	for _, perk in ipairs(SK.Perks) do
		ply:SetNWBool("perk_" .. perk.id, data.perks[perk.id] == true)
	end

	SK.Apply(ply)
end

function SK.GiveXP(ply, amount)
	if not IsValid(ply) or not ply:IsPlayer() or amount <= 0 then return end

	local data = Data(ply)
	data.xp = data.xp + amount

	local leveled = false
	while data.xp >= SK.XPForLevel(data.level) do
		data.xp = data.xp - SK.XPForLevel(data.level)
		data.level = data.level + 1
		data.points = data.points + 1
		leveled = true
	end

	Sync(ply)
	Save(ply)

	if leveled then
		net.Start("rem_skills_levelup")
			net.WriteUInt(data.level, 16)
		net.Send(ply)
	end
end

net.Receive("rem_skills_upgrade", function(len, ply)
	local id = net.ReadString()
	if not SK.ByID[id] then return end

	local data = Data(ply)
	local rank = tonumber(data.skills[id]) or 0
	if data.points <= 0 or rank >= SK.MaxRank then return end

	data.points = data.points - 1
	data.skills[id] = rank + 1

	Sync(ply)
	Save(ply)
end)

net.Receive("rem_skills_perk", function(len, ply)
	local perk = SK.PerkByID[net.ReadString()]
	if not perk then return end

	local data = Data(ply)
	if data.perks[perk.id] or data.points < perk.cost then return end

	data.points = data.points - perk.cost
	data.perks[perk.id] = true

	Sync(ply)
	Save(ply)
	ply:Notify("New perk: " .. perk.name .. ".", 0, "skills_perk", 3, nil, Color(230, 190, 0))
end)

hook.Add("PlayerInitialSpawn", "rem_skills", function(ply)
	timer.Simple(1, function()
		if IsValid(ply) then Sync(ply) end
	end)
end)

hook.Add("PlayerDisconnected", "rem_skills", Save)

hook.Add("Org Clear", "rem_skills", function(org)
	local owner = org.owner
	if not IsValid(owner) or not owner:IsPlayer() then return end

	timer.Simple(0, function()
		if IsValid(owner) then SK.Apply(owner) end
	end)
end)

-- опыт за убийства
hook.Add("PlayerDeath", "rem_skills", function(victim, inflictor, attacker)
	if IsValid(attacker) and attacker:IsPlayer() and attacker ~= victim then SK.GiveXP(attacker, xp_player_kill) end
end)

hook.Add("OnNPCKilled", "rem_skills", function(npc, attacker)
	if IsValid(attacker) and attacker:IsPlayer() then SK.GiveXP(attacker, xp_npc_kill) end
end)

-- весь опыт, который уже начисляет сборка (раунды, победы и т.д.), тоже идёт в прокачку
hook.Add("InitPostEntity", "rem_skills_exp", function()
	local meta = FindMetaTable("Player")
	if not meta.GiveExp or meta.skillGiveExpWrapped then return end

	local giveExp = meta.GiveExp
	meta.skillGiveExpWrapped = true
	function meta:GiveExp(amount, ...)
		if isnumber(amount) then SK.GiveXP(self, amount) end
		return giveExp(self, amount, ...)
	end
end)

COMMANDS = COMMANDS or {}
COMMANDS.skills = {function(ply)
	net.Start("rem_skills_open")
	net.Send(ply)
end, 0}

COMMANDS.givexp = {function(ply, args)
	local amount = tonumber(args[1])
	if not amount then ply:ChatPrint("Usage: !givexp <amount> [player]") return end

	local target = ply
	if args[2] then
		target = nil
		for _, other in player.Iterator() do
			if string.find(string.lower(other:Nick()), string.lower(args[2]), 1, true) then target = other break end
		end
	end

	if not IsValid(target) then ply:ChatPrint("Player not found.") return end
	SK.GiveXP(target, amount)
	ply:ChatPrint("Gave " .. amount .. " XP to " .. target:Nick())
end, 1, "amount; player"}
