-- Паника. org.panic 0..1 копится ОЧЕНЬ медленно и только когда ты при смерти: мало крови, не хватает кислорода,
-- невыносимая боль, уплывает сознание, встало сердце (Danger); чем хуже - тем быстрее. Стало лучше - спадает.
-- Ярость (sv_rage.lua) панику гасит.
-- С P.on: чёрные края экрана "плывут", своя музыка, частое дыхание, прицел гуляет (cl_panic.lua), мысли вслух;
--   внезапно появился человек перед тобой - палец сам жмёт на спуск (с шансом), тело само дёргается на шаг в сторону.
-- С P.heavy (слепая паника): видишь угрозу (на тебя смотрят с оружием / только что ударили) - сам срываешься и бежишь
--   прочь пару секунд. Управление этим - sh_panic.lua (StartCommand), сервер только решает и пишет в NW2.
-- Клиенту - NW2 "rem_panic" (0..1).
local P = {
	gain = 0.006,      -- в секунду в самом тяжёлом состоянии: до начала паники ~1 мин, до слепой ~2 мин
	decay = 0.02,      -- в секунду, когда опасности для жизни нет
	-- "при смерти": с какого значения начинается и на каком - худшее
	blood = {3900, 2400},     -- мл (норма 5000)
	o2 = {14, 5},             -- норма 30
	pain = {100, 150},        -- org.pain (100% на экране = 120)
	consciousness = {0.6, 0.3},
	on = 0.35,         -- отсюда эффекты и поведение
	heavy = 0.7,       -- отсюда сам убегает
	appearRange = 750, -- "внезапно появился": стал виден ближе этого
	appearDot = 0.55,  -- и перед тобой
	appearMemory = 4,  -- кого видел меньше этого назад - уже не внезапно
	fireChance = 0.75, -- шанс выстрела при внезапном появлении (умножается на панику)
	fireCooldown = 2.5,
	walkEvery = {2.5, 6}, -- непроизвольный шаг раз в столько секунд (при панике 1; меньше паника - реже)
	fleeCooldown = 6,
	fleeChance = 0.5,  -- за проверку (раз в P.tick), когда есть угроза
	threatRange = 1400,
	tick = 0.25,
	sayEvery = {7, 14},
}
hg.organism.PanicConfig = P

-- серверная настройка (Serverside gameplay -> "Panic mechanic"): 0 - паники нет совсем
local rem_panic_enabled = ConVarExists("rem_panic_enabled") and GetConVar("rem_panic_enabled") or CreateConVar("rem_panic_enabled", 1, FCVAR_REPLICATED + FCVAR_ARCHIVE, "Toggle the panic mechanic", 0, 1)

resource.AddSingleFile("sound/rem_panic/panic.mp3") -- музыка паники (cl_panic.lua)

local phrases = {
	"I need to get out of here.",
	"Breathe. Breathe. BREATHE.",
	"Oh god oh god oh god...",
	"They're going to kill me.",
	"Where do I go?! Where do I go?!",
	"Not like this. Not like this.",
	"I can't stop shaking.",
	"My heart... it's going to burst.",
	"Everything is closing in.",
	"Who's there?! WHO'S THERE?!",
	"I don't want to die here.",
	"Move. MOVE. Why can't I move right?",
}
local fleePhrases = {"GET AWAY FROM ME!", "Run. RUN!", "NO NO NO NO", "I'm out, I'm OUT!"}
local firePhrases = {"SHIT!", "I didn't mean to--", "Was that-- did I--", "AAH!"}
local startPhrase = "Something is wrong. Something is very wrong."

local function PlayerOf(ent)
	if not IsValid(ent) then return end
	if ent:IsPlayer() then return ent end
	local ply = hg.RagdollOwner and hg.RagdollOwner(ent) or ent:GetNWEntity("ply")
	if IsValid(ply) and ply:IsPlayer() then return ply end
end

local function Say(ply, list)
	if ply.Notify then ply:Notify(list[math.random(#list)], true, "panic", 0) end
end

function hg.organism.AddPanic(ply, amount)
	local org = IsValid(ply) and ply.organism
	if not org or not ply:Alive() or org.otrub or amount <= 0 or not rem_panic_enabled:GetBool() then return end
	if (org.rageStage or 0) > 0 then return end -- в ярости не до паники
	org.panic = math.min((org.panic or 0) + amount, 1)
end

local function Remap01(v, from, to) return math.Clamp((v - from) / (to - from), 0, 1) end

-- насколько ты при смерти: 0 - жизни ничего не грозит, 1 - хуже некуда
local function Danger(org)
	if org.heartstop then return 1 end
	local d = Remap01(org.blood or 5000, P.blood[1], P.blood[2])
	d = math.max(d, Remap01(istable(org.o2) and org.o2[1] or 30, P.o2[1], P.o2[2]))
	d = math.max(d, Remap01(org.pain or 0, P.pain[1], P.pain[2]))
	d = math.max(d, Remap01(org.consciousness or 1, P.consciousness[1], P.consciousness[2]))
	return d
end
hg.organism.PanicDanger = Danger

function hg.organism.Panic(owner, org, timeValue)
	local ply = PlayerOf(owner)
	if not ply then return end
	local panic = org.panic or 0

	if not ply:Alive() or org.otrub or org.alive == false or not rem_panic_enabled:GetBool() then
		panic = 0
	elseif (org.rageStage or 0) > 0 then
		panic = math.max(panic - timeValue * P.decay * 4, 0)
	else
		local danger = Danger(org)
		if danger > 0 then
			panic = math.min(panic + timeValue * P.gain * (0.3 + 0.7 * danger), 1)
		else
			panic = math.max(panic - timeValue * P.decay, 0)
		end
		-- паника сама держит страх и подгоняет сердце
		if panic > P.on then
			org.fearadd = math.max(org.fearadd or 0, panic * 0.3)
			if org.adrenaline then org.adrenaline = math.max(org.adrenaline, panic * 0.6) end
		end
	end
	org.panic = panic

	if panic >= P.on and not org.panicSaid then
		org.panicSaid = true
		if org.isPly and ply.Notify then ply:Notify(startPhrase, true, "panic", 0) end
	elseif panic < P.on * 0.5 then
		org.panicSaid = nil
	end

	local r = math.Round(panic, 2)
	if r ~= org.panicSent then
		org.panicSent = r
		ply:SetNW2Float("rem_panic", r)
	end
end

-- удар от игрока: паника от него не растёт, только запоминаем, от кого бежать
hook.Add("HomigradDamage", "rem_panic_hit", function(ply, dmgInfo)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	local attacker = PlayerOf(dmgInfo:GetAttacker())
	if not attacker or attacker == ply or dmgInfo:GetDamage() < 3 then return end
	ply.remPanicAttacker, ply.remPanicAttackedAt = attacker, CurTime()
end)

-- ты видишь его? (перед тобой и без стены между)
local function Sees(ply, other, dot)
	local from, to = ply:EyePos(), other:EyePos()
	local dir = to - from
	local dist = dir:Length()
	if dist < 1 then return true, 0 end
	dir:Mul(1 / dist)
	if ply:GetAimVector():Dot(dir) < dot then return false, dist end
	local tr = util.TraceLine({start = from, endpos = to, filter = {ply, other, ply.FakeRagdoll, other.FakeRagdoll}, mask = MASK_VISIBLE})
	return not tr.Hit, dist
end

local function IsGun(wep)
	if not IsValid(wep) then return false end
	if ishgweapon and ishgweapon(wep) then return not wep.ismelee and not wep.ismelee2 end
	return wep.Primary ~= nil and (wep.Primary.ClipSize or -1) > 0
end

-- угроза: только что ударил, или смотрит на тебя с оружием в руках
local function Threat(ply)
	local now = CurTime()
	if IsValid(ply.remPanicAttacker) and now - (ply.remPanicAttackedAt or 0) < 8 then return ply.remPanicAttacker end
	for _, other in player.Iterator() do
		if other ~= ply and other:Alive() and IsGun(other:GetActiveWeapon()) then
			local ok, dist = Sees(ply, other, 0.2)
			if ok and dist < P.threatRange then
				local toMe = (ply:EyePos() - other:EyePos()):GetNormalized()
				if other:GetAimVector():Dot(toMe) > 0.9 then return other end
			end
		end
	end
end

local function Rand(t) return math.Rand(t[1], t[2]) end

-- поведение раз в P.tick
timer.Create("rem_panic_behaviour", P.tick, 0, function()
	if not rem_panic_enabled:GetBool() then return end
	local now = CurTime()
	for _, ply in player.Iterator() do
		local org = ply.organism
		local panic = org and org.panic or 0
		if not ply:Alive() or panic < P.on or org.otrub or IsValid(ply.FakeRagdoll) then
			ply.remPanicSeen = nil
			continue
		end
		local k = (panic - P.on) / (1 - P.on) -- 0..1 от начала паники

		-- мысли вслух
		if now >= (ply.remPanicSay or 0) then
			if ply.remPanicSay then Say(ply, phrases) end
			ply.remPanicSay = now + Rand(P.sayEvery) * (1.4 - k * 0.6)
		end

		-- кто внезапно появился перед тобой
		local seen = ply.remPanicSeen or {}
		ply.remPanicSeen = seen
		local appeared
		for _, other in player.Iterator() do
			if other ~= ply and other:Alive() then
				local ok, dist = Sees(ply, other, P.appearDot)
				if ok and dist < P.appearRange then
					if now - (seen[other] or -100) > P.appearMemory then appeared = appeared or other end
					seen[other] = now
				end
			end
		end
		if appeared and now >= (ply.remPanicFireCD or 0) and IsGun(ply:GetActiveWeapon()) and math.random() < P.fireChance * panic then
			ply.remPanicFireCD = now + P.fireCooldown
			ply:SetNW2Float("rem_panic_fire", now + math.Rand(0.12, 0.35))
			ply:SetNW2Vector("rem_panic_aim", appeared:WorldSpaceCenter())
			Say(ply, firePhrases)
		end

		-- непроизвольный шаг
		if now >= (ply.remPanicWalkNext or 0) then
			if ply.remPanicWalkNext and ply:OnGround() then
				local side = math.random() < 0.5 and -1 or 1
				ply:SetNW2Vector("rem_panic_walk", Vector(math.Rand(-0.6, 0.6), side, 0):GetNormalized())
				ply:SetNW2Float("rem_panic_walk_until", now + math.Rand(0.25, 0.7))
			end
			ply.remPanicWalkNext = now + Rand(P.walkEvery) / (0.4 + k)
		end

		-- слепая паника: бежит прочь от угрозы
		if panic >= P.heavy and now >= (ply.remPanicFleeCD or 0) and math.random() < P.fleeChance * P.tick * 4 then
			local threat = Threat(ply)
			if threat then
				local dur = math.Rand(1.5, 3)
				ply.remPanicFleeCD = now + dur + P.fleeCooldown
				ply:SetNW2Vector("rem_panic_flee_from", threat:GetPos())
				ply:SetNW2Float("rem_panic_flee_until", now + dur)
				Say(ply, fleePhrases)
			end
		end
	end
end)

-- проверка: rem_panic_set [0..1] [игрок] - выставить панику (админ; без игрока - себе)
concommand.Add("rem_panic_set", function(ply, _, args)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local value = math.Clamp(tonumber(args[1] or "") or 1, 0, 1)
	local target = ply
	if args[2] then
		for _, p in player.Iterator() do
			if string.find(string.lower(p:Nick()), string.lower(args[2]), 1, true) then target = p break end
		end
	end
	if not IsValid(target) or not target.organism then return end
	target.organism.panic = value -- без опасности для жизни потом медленно спадёт сама
	print("[rem_panic] " .. target:Nick() .. " = " .. value)
end)

-- после смерти/возрождения - с нуля
local function Reset(ply)
	local org = ply.organism
	if org then org.panic, org.panicSent, org.panicSaid = 0, 0, nil end
	ply:SetNW2Float("rem_panic", 0)
	ply:SetNW2Float("rem_panic_fire", 0)
	ply:SetNW2Float("rem_panic_walk_until", 0)
	ply:SetNW2Float("rem_panic_flee_until", 0)
	ply.remPanicSeen, ply.remPanicSay, ply.remPanicWalkNext, ply.remPanicAttacker = nil, nil, nil, nil
end
hook.Add("PlayerSpawn", "rem_panic_reset", Reset)
hook.Add("PlayerDeath", "rem_panic_reset", Reset)
