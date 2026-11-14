-- Сотрясение (из MELEECITY): копится от ударов по черепу и взрывов (0..10), спадает на 1 в секунду.
-- Пока оно есть - понемногу уходит сознание; выше 2.5 человек падает и его дезориентирует.
-- Эффекты у игрока (звон shellshock, глухой звук, засвет) - в cl_concussion.lua.
hg.organism.module.concussion = {}
local module = hg.organism.module.concussion

local concussion_max = 10
local consciousness_drain = 0.032
local fake_threshold = 2.5

module[1] = function(org)
	org.concussion = 0
	org.remKOEnd = nil
end

module[2] = function(owner, org, timeValue)
	if (org.concussion or 0) <= 0 then return end

	org.concussion = math.max(org.concussion - timeValue, 0)

	if org.consciousness then
		org.consciousness = math.max(org.consciousness - org.concussion * consciousness_drain * timeValue, 0)
	end

	if org.concussion > fake_threshold then
		org.needfake = true
		org.disorientation = math.max(org.disorientation or 0, 2)
	end

	-- нокаут от заряженного удара в голову (ниже): пока не прошёл - без сознания
	if org.remKOEnd then
		if org.remKOEnd > CurTime() and org.alive ~= false then
			org.needotrub = true
			org.needfake = true
		else
			org.remKOEnd = nil
		end
	end
end

function hg.organism.AddConcussion(org, amount)
	if not org or amount <= 0 then return end
	org.concussion = math.min((org.concussion or 0) + amount, concussion_max)
end

for i = 1, 3 do resource.AddSingleFile("sound/shellshock/" .. i .. ".mp3") end

-- Сотрясение от заряженного удара кулаком в голову (weapon_hands_sh - удар после паузы, weapon_hg_coolhands - E + ЛКМ
-- с замахом): оружие ставит метку self.remStrongHitT перед TakeDamageInfo. С шансом: звук удара rem_concussion/1-4,
-- сотрясение выше порога падения (звон, глухой звук), оглушение org.stun - лежит 2.5..5 с, иногда нокаут 4..10 с.
-- Выкл. - rem_punch_concussion 0, шанс - rem_punch_concussion_chance (множитель).
local cvOn = CreateConVar("rem_punch_concussion", "1", FCVAR_ARCHIVE, "concussion from charged punch to the head", 0, 1)
local cvChance = CreateConVar("rem_punch_concussion_chance", "1", FCVAR_ARCHIVE, "multiplier of concussion chance from charged punch", 0, 10)

local FISTS = {weapon_hands_sh = true, weapon_hg_coolhands = true}
local BASE_CHANCE = 0.6     -- обычный заряженный удар в голову
local KNUCKLES_MUL = 1.35   -- кастет
local REPEAT_ADD = 0.2      -- уже есть сотрясение - легче
local KO_CHANCE = 0.25      -- нокаут (без сознания)
local KO_CHANCE_REPEAT = 0.55 -- нокаут, если сотрясение уже было сильным

for i = 1, 4 do resource.AddSingleFile("sound/rem_concussion/concussion" .. i .. ".mp3") end
util.AddNetworkString("rem_concussion_snd")

local function HeadPos(ent)
	local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
	if not bone then return end
	if ent:IsRagdoll() then
		local phys = ent:GetPhysicsObjectNum(ent:TranslateBoneToPhysBone(bone))
		if IsValid(phys) then return phys:GetPos() end
	end
	return ent:GetBonePosition(bone)
end

local function IsHeadHit(ent, hitgroup, pos)
	if hitgroup == HITGROUP_HEAD then return true end
	if not IsValid(ent) or not pos or pos == vector_origin then return false end
	local head = HeadPos(ent)
	return head and head:DistToSqr(pos) < 12 * 12 or false
end

-- forceKO: true - нокаут наверняка, false - без нокаута, nil - по шансу (для тестовых команд, sh_remtests.lua)
function hg.organism.PunchConcussion(ply, org, pos, strong, forceKO)
	local now = CurTime()
	hg.organism.AddConcussion(org, math.Rand(3.5, 5.5) * (strong and 1.3 or 1))
	org.stun = math.max(org.stun or 0, now + math.Rand(2.5, 5))
	org.disorientation = math.max(org.disorientation or 0, 3)

	local koChance = (org.concussion or 0) >= 7 and KO_CHANCE_REPEAT or KO_CHANCE
	local wasOut = org.otrub
	local ko = math.random() < koChance * (strong and 1.5 or 1)
	if forceKO ~= nil then ko = forceKO end
	if wasOut and forceKO ~= false then ko = true end -- уже без сознания: удар продлевает нокаут
	if ko then
		org.remKOEnd = math.max(org.remKOEnd or 0, now + math.Rand(3, 8))
		-- сознание почти в ноль: экран отключки Z-City (темнота, зерно, виньетка) строится от org.consciousness,
		-- без этого нокаут был без визуала; потом оно само восстанавливается (~0.05/с, порог пробуждения 0.3)
		org.consciousness = math.min(org.consciousness or 1, math.Rand(0, 0.1))
	end

	local n = math.random(4)
	sound.Play("rem_concussion/concussion" .. n .. ".mp3", pos or ply:EyePos(), 80, math.random(95, 105), 1)
	-- без сознания Z-City глушит игроку все звуки мира (soundfade) - самому пострадавшему звук отдельно, через BASS
	if ko or wasOut then
		net.Start("rem_concussion_snd")
		net.WriteUInt(n, 3)
		net.Send(ply)
	end

	if not ko and not wasOut and ply.Thought then
		local msgs = {"My head... everything is spinning.", "Everything is ringing.", "I can't stand up.", "Where am I?"}
		ply:Thought(msgs[math.random(#msgs)], 2, "thought_punch_concussion", 0, Color(200, 220, 255))
	end
end

hook.Add("HomigradDamage", "rem_punch_concussion", function(ply, dmg, hitgroup, ent)
	if not cvOn:GetBool() or not dmg:IsDamageType(DMG_CLUB) then return end
	if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	local org = ply.organism
	if not org then return end -- без сознания - тоже (продлевает нокаут, звук слышно)

	local wep, att = dmg:GetInflictor(), dmg:GetAttacker()
	if not IsValid(wep) or not FISTS[wep:GetClass()] or not IsValid(att) or not att:IsPlayer() then return end
	local t = wep.remStrongHitT
	if not t or CurTime() - t > 0.3 then return end
	if ply.remPunchConcT == t then return end -- один бросок на удар
	ply.remPunchConcT = t

	local pos = dmg:GetDamagePosition()
	local body = IsValid(ent) and ent or (IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or ply)
	if not IsHeadHit(body, hitgroup, pos) then return end

	local inv = att:GetNetVar("Inventory", {})
	local knuckles = inv and inv["Weapons"] and inv["Weapons"]["hg_brassknuckles"]
	local strong = att:IsBerserk() or (att.organism and att.organism.superfighter)
	local chance = BASE_CHANCE * (knuckles and KNUCKLES_MUL or 1) + ((org.concussion or 0) > 0 and REPEAT_ADD or 0)
	chance = strong and 1 or chance * cvChance:GetFloat()
	if math.random() >= chance then return end

	hg.organism.PunchConcussion(ply, org, pos ~= vector_origin and pos or nil, strong)
end)
