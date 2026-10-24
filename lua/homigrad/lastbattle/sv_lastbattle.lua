-- Последний бой: музыка + таймер длиной в музыку.
-- Бывает только у отдельного игрока: может включиться сам, когда у него пошёл таймер смерти
-- (шанс 10% + 1% за каждую минуту жизни, максимум один раз за жизнь),
-- или командой. После смерти сразу снимается.
-- Пока идёт бой: нельзя потерять сознание, мозг всегда здоров, нет эпилепсии, кислород держится на 60%,
-- нет боли, депрессия не растёт, всё остальное не лечится.
hg.LastBattle = hg.LastBattle or {}
local LB = hg.LastBattle

util.AddNetworkString("rem_lastbattle_state")
util.AddNetworkString("rem_lastbattle_length")

-- первый найденный файл из списка и будет музыкой последнего боя
LB.MusicFiles = {
	"sound/rem_laststand.mp3",
	"sound/rem_lastbattle.mp3",
	"sound/rem_lastbattle.ogg",
	"sound/rem_lastbattle.wav",
}

local lastbattle_duration = ConVarExists("zb_lastbattle_duration") and GetConVar("zb_lastbattle_duration") or CreateConVar("zb_lastbattle_duration", 0, FCVAR_ARCHIVE, "Last battle duration in seconds (0 = length of the music)", 0, 3600)
local lastbattle_auto = ConVarExists("zb_lastbattle_auto") and GetConVar("zb_lastbattle_auto") or CreateConVar("zb_lastbattle_auto", 1, FCVAR_ARCHIVE, "Start a personal last battle when a player gets the death timer", 0, 1)
local lastbattle_chance = ConVarExists("zb_lastbattle_chance") and GetConVar("zb_lastbattle_chance") or CreateConVar("zb_lastbattle_chance", 10, FCVAR_ARCHIVE, "Starting chance (%) of the last battle on the death timer", 0, 100)
local lastbattle_chance_add = ConVarExists("zb_lastbattle_chance_add") and GetConVar("zb_lastbattle_chance_add") or CreateConVar("zb_lastbattle_chance_add", 1, FCVAR_ARCHIVE, "Chance (%) added for every minute the player is alive", 0, 100)

local consciousness_min = 0.45
local o2_hold = 0.6
local length_wait_time = 5
local update_interval = 0.2

-- урон, который может только расти
local damageKeys = {
	"liver", "heart", "heartStrain", "arrhythmia", "stomach", "intestines",
	"eyeL", "eyeR", "lleg", "rleg", "larm", "rarm",
	"chest", "pelvis", "spine1", "spine2", "spine3", "skull", "jaw", "trachea",
}
local lungKeys = {"lungsL", "lungsR"}
local flagKeys = {
	"llegdislocation", "rlegdislocation", "larmdislocation", "rarmdislocation", "jawdislocation",
	"llegamputated", "rlegamputated", "larmamputated", "rarmamputated",
}

local function FindMusic()
	for _, path in ipairs(LB.MusicFiles) do
		if file.Exists(path, "GAME") then return path end
	end
end

local function WavDuration(path)
	local f = file.Open(path, "rb", "GAME")
	if not f then return end

	local duration
	if f:Read(4) == "RIFF" then
		f:Skip(4)
		if f:Read(4) == "WAVE" then
			local byteRate
			while f:Tell() + 8 <= f:Size() do
				local id = f:Read(4)
				local size = f:ReadULong()
				local nextChunk = f:Tell() + size + size % 2
				if id == "fmt " then
					f:Skip(8)
					byteRate = f:ReadULong()
				elseif id == "data" and byteRate and byteRate > 0 then
					duration = size / byteRate
					break
				end
				f:Seek(nextChunk)
			end
		end
	end

	f:Close()
	return duration
end

-- 0, если длина музыки пока неизвестна (mp3/ogg: её пришлёт клиент)
local function GetDuration(path)
	local duration = lastbattle_duration:GetFloat()
	if duration > 0 then return duration end

	if LB.MusicLength and LB.MusicLength.path == path then return LB.MusicLength.length end

	if path and string.EndsWith(path, ".wav") then
		local length = WavDuration(path)
		if length and length > 0 then
			LB.MusicLength = {path = path, length = length}
			return length
		end
	end

	return 0
end

local function NewSession()
	local path = FindMusic()
	local duration = GetDuration(path)
	if not path and duration <= 0 then return end

	local session = {path = path, startTime = CurTime()}
	if duration > 0 then session.endTime = session.startTime + duration end

	return session
end

function LB.GetSession(ply)
	return IsValid(ply) and ply.LastBattle or nil
end

function LB.IsActiveFor(ply)
	return LB.GetSession(ply) ~= nil
end

local function SendState(ply)
	local session = LB.GetSession(ply)

	net.Start("rem_lastbattle_state")
		net.WriteBool(session ~= nil)
		if session then
			net.WriteString(session.path or "")
			net.WriteFloat(session.startTime)
			net.WriteFloat(session.endTime or 0)
		end
	net.Send(ply)
end

local function ClearFloor(ply)
	if IsValid(ply) and ply.organism then ply.organism.lastBattleFloor = nil end
end

function LB.StartPersonal(ply)
	if not IsValid(ply) or LB.IsActiveFor(ply) then return false end

	local session = NewSession()
	if not session then return false end

	ply.LastBattle = session
	ClearFloor(ply)
	SendState(ply)

	hook.Run("HG_LastBattleStart", ply)
	return true
end

function LB.StopPersonal(ply)
	if not IsValid(ply) or not ply.LastBattle then return end

	ply.LastBattle = nil
	ClearFloor(ply)
	SendState(ply)

	hook.Run("HG_LastBattleEnd", ply)
end

local function SetSessionLength(length)
	for _, ply in player.Iterator() do
		local session = ply.LastBattle
		if session and not session.endTime then
			session.endTime = session.startTime + length
			SendState(ply)
		end
	end
end

net.Receive("rem_lastbattle_length", function(len, ply)
	local session = LB.GetSession(ply)
	if not session or session.endTime or not session.path then return end

	local length = net.ReadFloat()
	if length ~= length or length < 1 or length > 3600 then return end

	LB.MusicLength = {path = session.path, length = length}
	SetSessionLength(length)
end)

-- конец по таймеру и запасной вариант, если клиент не прислал длину
local function SessionExpired(session)
	if session.endTime then return CurTime() >= session.endTime end
	if CurTime() < session.startTime + length_wait_time then return false end

	local fallback = session.path and SoundDuration(string.sub(session.path, 7)) or 0
	if fallback and fallback > 1 then
		LB.MusicLength = {path = session.path, length = fallback}
		SetSessionLength(fallback)
		return false
	end

	return true
end

local nextUpdate = 0
hook.Add("Think", "rem_lastbattle", function()
	if CurTime() < nextUpdate then return end
	nextUpdate = CurTime() + update_interval

	for _, ply in player.Iterator() do
		if ply.LastBattle and (not ply:Alive() or SessionExpired(ply.LastBattle)) then LB.StopPersonal(ply) end
	end
end)

hook.Add("PlayerDeath", "rem_lastbattle", function(ply)
	LB.StopPersonal(ply)
end)

hook.Add("PlayerSilentDeath", "rem_lastbattle", function(ply)
	LB.StopPersonal(ply)
end)

hook.Add("ZB_PreRoundStart", "rem_lastbattle", function()
	for _, ply in player.Iterator() do LB.StopPersonal(ply) end
end)

hook.Add("Org Clear", "rem_lastbattle", function(org)
	org.lastBattleFloor = nil
	org.lastBattleUsed = nil
	org.lastBattleRolled = nil
	org.lastBattleSpawn = CurTime()
	if IsValid(org.owner) and org.owner:IsPlayer() then LB.StopPersonal(org.owner) end
end)

local function ForceBrain(org)
	org.brain = 0
	org.brainFrontal = 0
	org.brainParietal = 0
	org.brainTemporal = 0
	org.brainOccipital = 0
	org.brainHemorrhage = 0
	org.brainBleedRate = 0
	org.lastSeizureBrain = 0
	org.lastSeizureLobeDamage = 0
end

local function RemovePain(org)
	org.pain = 0
	org.painadd = 0
	org.avgpain = 0
	org.shock = 0
	org.shockScore = 0
	org.shockStage = 0
	org.painUnconscious = false
	org.nearpainlimit = false
end

local function StopSeizure(owner, org)
	org.seizure = 0
	if not org.seizureActive then return end

	if owner.fakecd and owner.fakecd == org.seizureEnd then owner.fakecd = CurTime() end
	org.seizureActive = false
	org.seizureStart = 0
	org.seizureEnd = 0
	org.nextSeizureSpasm = 0
	owner.fullsend = true
end

-- после попадания мозг сразу возвращается в норму, чтобы пульс не успел отреагировать
hook.Add("HomigradDamage", "rem_lastbattle", function(ply, dmgInfo, hitgroup, ent)
	if not IsValid(ply) or not ply:IsPlayer() or not LB.IsActiveFor(ply) then return end

	local org = ply.organism
	if org then ForceBrain(org) end
end)

local function ApplyFloor(owner, org)
	local floor = org.lastBattleFloor
	if not floor then
		floor = {lungs = {}}
		org.lastBattleFloor = floor
	end

	for _, key in ipairs(damageKeys) do
		local value = org[key]
		if isnumber(value) then
			floor[key] = math.max(floor[key] or value, value)
			org[key] = floor[key]
		end
	end

	for _, key in ipairs(lungKeys) do
		local lung = org[key]
		if istable(lung) then
			local lungFloor = floor.lungs[key] or {}
			floor.lungs[key] = lungFloor
			for i = 1, 2 do
				local value = lung[i] or 0
				lungFloor[i] = math.max(lungFloor[i] or value, value)
				lung[i] = lungFloor[i]
			end
		end
	end

	for _, key in ipairs(flagKeys) do
		if org[key] then floor[key] = true end
		if floor[key] then org[key] = true end
	end

	if isnumber(org.blood) then
		floor.blood = math.min(floor.blood or org.blood, org.blood)
		org.blood = floor.blood
	end

	-- депрессия может только уменьшаться
	org.depressionadd = 0
	if isnumber(org.depression) then
		floor.depression = math.min(floor.depression or org.depression, org.depression)
		org.depression = floor.depression
	end

	local health = owner:Health()
	floor.health = math.min(floor.health or health, health)
	if health > floor.health then owner:SetHealth(floor.health) end
end

-- 10% на старте и +1% за каждую минуту жизни
function LB.GetChance(org)
	org.lastBattleSpawn = org.lastBattleSpawn or CurTime()
	local minutes = math.floor((CurTime() - org.lastBattleSpawn) / 60)

	-- перки Last Breath / Unlucky
	local owner = org.owner
	local perk = IsValid(owner) and owner.SkillLastStandAdd or 0

	return math.Clamp(lastbattle_chance:GetFloat() + minutes * lastbattle_chance_add:GetFloat() + perk, 0, 100)
end

-- шанс бросается один раз на каждый таймер смерти
local function RollLastBattle(org)
	if not org.deathStateEnd or org.deathStateKilled then
		org.lastBattleRolled = nil
		return false
	end

	if org.lastBattleRolled or org.lastBattleUsed or not lastbattle_auto:GetBool() then return false end
	org.lastBattleRolled = true

	-- этот таймер уже стал последними моментами (lastmoments/sv_lastmoments.lua)
	if IsValid(org.owner) and org.owner:IsPlayer() and org.owner:GetNWFloat("rem_lastmoments_until", 0) > CurTime() then return false end

	return math.Rand(0, 100) < LB.GetChance(org)
end

-- вызывается из "Org Think" Main перед тем, как применяется otrub; true - бой идёт для этого игрока
function LB.OrganismThink(owner, org)
	if not owner:Alive() then return false end

	if not LB.IsActiveFor(owner) then
		org.lastBattleSpawn = org.lastBattleSpawn or CurTime()
		if not RollLastBattle(org) then return false end

		org.lastBattleUsed = true
		if not LB.StartPersonal(owner) then return false end
	end

	org.needotrub = false
	org.consciousness = math.max(org.consciousness or 1, consciousness_min)
	ForceBrain(org)
	RemovePain(org)
	StopSeizure(owner, org)

	if istable(org.o2) then org.o2[1] = (org.o2.range or 30) * o2_hold end

	ApplyFloor(owner, org)
	return true
end

local function FindTarget(ply, name)
	if not name then return IsValid(ply) and ply or nil end

	name = string.lower(name)
	for _, target in player.Iterator() do
		if string.find(string.lower(target:Nick()), name, 1, true) then return target end
	end
end

local function RunCommand(ply, args)
	local stop = args[1] == "stop"
	if stop then table.remove(args, 1) end

	local function reply(msg)
		if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
	end

	local target = FindTarget(ply, args[1])
	if not IsValid(target) then reply(args[1] and "Player not found: " .. args[1] or "Usage: lastbattle [stop] <player>") return end

	if stop or (not args[1] and target.LastBattle) then
		if not target.LastBattle then reply(target:Nick() .. " has no last battle.") return end
		LB.StopPersonal(target)
		reply("Last battle stopped for " .. target:Nick() .. ".")
		return
	end

	if not target:Alive() then reply(target:Nick() .. " is dead.") return end
	if target.LastBattle then reply(target:Nick() .. " already has a last battle.") return end

	if target.organism then target.organism.lastBattleUsed = true end
	if LB.StartPersonal(target) then
		reply("Last battle started for " .. target:Nick() .. "!")
	else
		reply("Music for the last battle not found (" .. table.concat(LB.MusicFiles, ", ") .. ")")
	end
end

COMMANDS = COMMANDS or {}
COMMANDS.lastbattle = {RunCommand, 1, "[stop] player"}

concommand.Add("zb_lastbattle", function(ply, cmd, args)
	if IsValid(ply) and not ply:IsAdmin() then ply:ChatPrint("You don't have access") return end
	RunCommand(ply, args)
end)
