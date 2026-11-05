hg.Skills = hg.Skills or {}
local SK = hg.Skills

util.AddNetworkString("rem_skills_open")
util.AddNetworkString("rem_skills_upgrade")
util.AddNetworkString("rem_skills_perk")
util.AddNetworkString("rem_skills_reset")
util.AddNetworkString("rem_skills_levelup")

local save_dir = "zcity_skills"

-- иконки навыков, перков и радиального меню (Tabler Icons, MIT), иконки состояний sef_icons (из MELEECITY)
for _, dir in ipairs({"materials/rem_skills/", "materials/radialmenu_rem/", "materials/rem_misc/", "materials/sef_icons/", "materials/rem_menu/", "materials/rem_affl/", "materials/rem_drinks_private/", "materials/rem_affl_private/"}) do
	for _, name in ipairs(file.Find(dir .. "*.png", "GAME")) do
		resource.AddSingleFile(dir .. name)
	end
end

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

	local mul = SK.PerkMul

	ply.SkillMeleeMul = (1 + SK.Bonus(ply, "strength")) * mul(ply, "melee")
	ply.SkillStaminaMul = (1 - SK.Bonus(ply, "endurance")) * mul(ply, "stamina")
	ply:SetNWFloat("SkillJumpMul", (1 + SK.Bonus(ply, "agility")) * mul(ply, "jump"))
	ply:SetNWFloat("SkillRecoilMul", (1 - SK.Bonus(ply, "marksman")) * mul(ply, "recoil"))
	ply:SetNWFloat("SkillSpeedMul", (1 + SK.Bonus(ply, "runner")) * mul(ply, "speed"))
	ply:SetNWFloat("SkillWeightMul", mul(ply, "weight"))
	ply.SkillReloadMul = (1 - SK.Bonus(ply, "quickhands")) * mul(ply, "reload")
	ply.SkillMedicMul = (1 + SK.Bonus(ply, "medic")) * mul(ply, "medic")
	ply.SkillXPMul = mul(ply, "xp")
	ply.SkillLastStandAdd = SK.PerkLastStand(ply)

	local org = ply.organism
	if org then
		-- боль: (1 - resist) = (1 - toughness) * множитель перков, Sensitive даёт отрицательный resist
		org.skillPainResist = 1 - (1 - SK.Bonus(ply, "toughness")) * mul(ply, "pain")
		org.skillBleedMul = (1 - SK.Bonus(ply, "vitality")) * mul(ply, "bleed")
		org.perkOxygenMul = mul(ply, "oxygen")
		org.perkHungerMul = mul(ply, "hunger")
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
	data.xp = data.xp + math.max(math.Round(amount * (ply.SkillXPMul or 1)), 1)

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

local colPerk = Color(230, 190, 0)
local colBadPerk = Color(255, 120, 120)

-- хороший перк - купить; плохой - взять (+очки) или снять (remove, -очки)
net.Receive("rem_skills_perk", function(len, ply)
	local perk = SK.PerkByID[net.ReadString()]
	local remove = net.ReadBool()
	if not perk then return end

	local data = Data(ply)
	local owned = data.perks[perk.id] == true

	if remove then
		if not perk.bad or not owned or data.points < perk.gain then return end

		data.points = data.points - perk.gain
		data.perks[perk.id] = nil
		Sync(ply)
		Save(ply)
		ply:Notify("You got rid of " .. perk.name .. ".", 0, "skills_perk", 3, nil, colPerk)
		return
	end

	if owned or (perk.conflicts and data.perks[perk.conflicts]) then return end

	if perk.bad then
		if SK.CountBadPerks(ply) >= SK.MaxBadPerks then return end
		data.points = data.points + perk.gain
	else
		if data.points < perk.cost then return end
		data.points = data.points - perk.cost
	end

	data.perks[perk.id] = true
	Sync(ply)
	Save(ply)
	ply:Notify((perk.bad and "New flaw: " or "New perk: ") .. perk.name .. ".", 0, "skills_perk", 3, nil, perk.bad and colBadPerk or colPerk)
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
-- сброс: снимаются все навыки и перки (плохие тоже), очков становится столько, сколько уровней
local reset_cooldown = 3

function SK.Reset(ply)
	local data = Data(ply)
	data.skills = {}
	data.perks = {}
	data.points = data.level

	Sync(ply)
	Save(ply)
	ply:Notify("Skills and perks reset. You have " .. data.points .. " skill points.", 0, "skills_reset", 3, nil, colPerk)
end

net.Receive("rem_skills_reset", function(len, ply)
	if (ply.skillResetNext or 0) > CurTime() then return end
	ply.skillResetNext = CurTime() + reset_cooldown

	SK.Reset(ply)
end)

COMMANDS.resetskills = {function(ply)
	if (ply.skillResetNext or 0) > CurTime() then return end
	ply.skillResetNext = CurTime() + reset_cooldown

	SK.Reset(ply)
end, 0}

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

-- выдача уровней и очков навыков (админ, суперадмин, хост локального сервера или консоль сервера):
--   чат: !givelevel <сколько> [игрок|*], !givepoints <сколько> [игрок|*], !setlevel <уровень> [игрок|*]
--   (можно отрицательное - забрать), консоль: rem_givelevel / rem_givepoints / rem_setlevel <сколько> [игрок|*],
--   вкладка Admin в меню навыков. Уровень даёт и очко навыка (как при обычной прокачке).
util.AddNetworkString("rem_skills_admin")

local function CanManage(ply)
	if not IsValid(ply) then return true end -- консоль сервера
	if game.SinglePlayer() or ply:IsListenServerHost() then return true end
	return COMMAND_GETACCES and COMMAND_GETACCES(ply) >= 1 or ply:IsAdmin()
end

function SK.AddLevels(ply, n)
	local data = Data(ply)
	n = math.max(n, -data.level)
	data.level = data.level + n
	data.points = math.max(data.points + n, 0)
	if n < 0 then data.xp = 0 end
	Sync(ply)
	Save(ply)
	if n > 0 then
		net.Start("rem_skills_levelup")
			net.WriteUInt(data.level, 16)
		net.Send(ply)
	end
end

function SK.AddPoints(ply, n)
	local data = Data(ply)
	data.points = math.max(data.points + n, 0)
	Sync(ply)
	Save(ply)
end

function SK.SetLevel(ply, level)
	SK.AddLevels(ply, math.max(math.floor(level), 0) - Data(ply).level)
end

local function Targets(caller, name)
	if not name or name == "" or name == "^" then return {caller} end
	if name == "*" then return player.GetAll() end
	local found = {}
	for _, other in ipairs(player.GetAll()) do
		if other:SteamID() == name or other:SteamID64() == name or string.find(string.lower(other:Nick()), string.lower(name), 1, true) then
			found[#found + 1] = other
		end
	end
	return found
end

local actions = {
	level = {SK.AddLevels, "level(s)"},
	points = {SK.AddPoints, "skill point(s)"},
	setlevel = {SK.SetLevel, "set level"},
}

local function Run(caller, kind, amount, name, reply)
	amount = tonumber(amount)
	if not amount then reply("Usage: <amount> [player|*]") return end
	amount = math.Round(amount)
	local targets = Targets(caller, name)
	if #targets == 0 or not IsValid(targets[1]) then reply("Player not found.") return end
	for _, t in ipairs(targets) do
		actions[kind][1](t, amount)
		if t ~= caller and IsValid(t) then
			t:ChatPrint((IsValid(caller) and caller:Nick() or "Server") .. ": " .. actions[kind][2] .. " " .. (amount > 0 and kind ~= "setlevel" and "+" or "") .. amount)
		end
	end
	reply(string.format("%s %s%d for %d player(s).", actions[kind][2], (amount > 0 and kind ~= "setlevel") and "+" or "", amount, #targets))
end

for cmd, kind in pairs({givelevel = "level", givepoints = "points", setlevel = "setlevel"}) do
	COMMANDS[cmd] = {function(ply, args)
		Run(ply, kind, args[1], args[2], function(msg) ply:ChatPrint(msg) end)
	end, 1, "amount; player or * for everyone (default - you)"}

	concommand.Add("rem_" .. cmd, function(ply, _, args)
		if not CanManage(ply) then return end
		Run(IsValid(ply) and ply or nil, kind, args[1], args[2], function(msg)
			if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
		end)
	end)
end

net.Receive("rem_skills_admin", function(_, ply)
	if not CanManage(ply) then return end
	local target, kind, amount = net.ReadEntity(), net.ReadString(), net.ReadInt(16)
	if not IsValid(target) or not target:IsPlayer() or not actions[kind] then return end
	actions[kind][1](target, amount)
	if target ~= ply then target:ChatPrint(ply:Nick() .. ": " .. actions[kind][2] .. " " .. (amount > 0 and "+" or "") .. amount) end
end)
