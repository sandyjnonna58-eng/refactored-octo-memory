-- Ярость (как в Fading Vitality). org.rage 0..1 копится, когда тебе угрожают:
--   на тебя смотрят с оружием в руках (ближнее - медленно), в тебя целятся из огнестрела (быстрее),
--   тебе показали фак (жест "fuck you", hg_hand_gesture), тебе сказали в чат "умри"/"сдохни"/"die".
-- Сам ты должен это видеть: угроза у тебя за спиной не злит.
-- Пока тебя не ударили, ярость не поднимается выше 2-й стадии. Удар от игрока - большой рывок вверх, открывает 3-ю стадию
-- и на hitWindow секунд всё копится вдвое быстрее.
-- Стадии: 1 "Blinding anger", 2 "Furious", 3 "Undeterrable rage". Чем выше - тем меньше страх и боль, больше адреналина;
-- со 2-й трясутся руки (cl_rage.lua). Без угроз ярость медленно спадает.
-- Клиенту - NW2 "rem_rage" (0..1) и "rem_rage_stage" (0..3): музыка, значок в осмотре, экран.
local R = {
	stage1 = 0.2, stage2 = 0.5, stage3 = 0.8,
	capNoHit = 0.79,     -- без удара - не выше 2-й стадии
	hitWindow = 30,      -- секунд после удара: открыта 3-я стадия, рост x2
	hitGain = 0.22,      -- за удар (с уроном не меньше hitMinDamage)
	hitMinDamage = 3,
	aimGain = 0.035,     -- в секунду, пока в тебя целятся из огнестрела (до 2-й стадии ~15 с)
	lookGain = 0.015,    -- в секунду, пока на тебя смотрят с ближним оружием
	gestureGain = 0.12,  -- за фак
	wordGain = 0.15,     -- за "умри"
	gunRange = 2500, meleeRange = 600, wordRange = 900,
	aimDot = 0.97,       -- насколько точно ствол направлен на тебя
	lookDot = 0.9,
	noticeDot = 0.25,    -- ты сам смотришь в его сторону (видишь угрозу)
	calmDelay = 8,       -- через сколько секунд без угроз начинает спадать
	decay = 0.012,       -- в секунду
	-- что даёт (на стадию 1/2/3)
	painRelief = {0.1, 0.2, 0.35},
	adrenaline = {0, 0.4, 1},
	fearDrop = 0.15,     -- снятие страха в секунду на стадию
}
hg.organism.RageConfig = R

-- слова-угрозы: русские - частью слова ("умрите" тоже), английские - только целым словом;
-- string.lower в GMod не трогает кириллицу, поэтому варианты с заглавными перечислены
local wordsRu = {"умри", "Умри", "УМРИ", "сдохни", "Сдохни", "СДОХНИ"}
local wordsEn = {die = true, kys = true}
local stagePhrases = {
	"Who the hell does he think he is...",
	"I'm going to kill him.",
	"NOTHING. ELSE. MATTERS. BUT. THIS.",
}

if file.Exists("sound/rem_rage_private/anger.mp3", "GAME") then
	resource.AddSingleFile("sound/rem_rage_private/anger.mp3") -- музыка ярости (приватный пак, не в репозитории)
end

local function StageOf(rage)
	if rage >= R.stage3 then return 3 end
	if rage >= R.stage2 then return 2 end
	if rage >= R.stage1 then return 1 end
	return 0
end

local function PlayerOf(ent)
	if not IsValid(ent) then return end
	if ent:IsPlayer() then return ent end
	local ply = hg.RagdollOwner and hg.RagdollOwner(ent) or ent:GetNWEntity("ply")
	if IsValid(ply) and ply:IsPlayer() then return ply end
end

-- добавить ярость игроку (учитывает потолок без удара и x2 после удара)
function hg.organism.AddRage(ply, amount)
	local org = IsValid(ply) and ply.organism
	if not org or not ply:Alive() or org.otrub or amount <= 0 then return end
	local hit = (org.rageHitUntil or 0) > CurTime()
	if hit then amount = amount * 2 end
	local cap = hit and 1 or math.max(R.capNoHit, org.rage or 0)
	org.rage = math.min((org.rage or 0) + amount, cap)
	org.rageLastThreat = CurTime()
end

-- ты видишь его? (он перед тобой и между вами нет стены)
local function Sees(victim, other)
	local dir = other:EyePos() - victim:EyePos()
	local dist = dir:Length()
	if dist < 1 then return true, 0 end
	dir:Mul(1 / dist)
	if victim:GetAimVector():Dot(dir) < R.noticeDot then return false, dist end
	local tr = util.TraceLine({start = victim:EyePos(), endpos = other:EyePos(), filter = {victim, other}, mask = MASK_VISIBLE})
	return not tr.Hit, dist
end

-- он направил на тебя оружие (смотрит в твою сторону)
local function Threat(victim, other)
	local wep = other:GetActiveWeapon()
	if not IsValid(wep) or wep:GetClass() == "weapon_hands_sh" then return 0 end
	local gun = ishgweapon and ishgweapon(wep)
	if not gun and not wep.ismelee then return 0 end -- бутылки, аптечки, камера не в счёт
	local to = victim:EyePos() - other:EyePos()
	local dist = to:Length()
	if dist > (gun and R.gunRange or R.meleeRange) then return 0 end
	to:Mul(1 / math.max(dist, 1))
	if other:GetAimVector():Dot(to) < (gun and R.aimDot or R.lookDot) then return 0 end
	return gun and R.aimGain or R.lookGain
end

function hg.organism.Rage(owner, org, timeValue)
	local ply = PlayerOf(owner)
	if not ply then return end
	local rage = org.rage or 0

	if not ply:Alive() or org.otrub or org.alive == false then
		rage = 0
	else
		-- угрозы вокруг
		local gain = 0
		for _, other in player.Iterator() do
			if other ~= ply and other:Alive() and not IsValid(other.FakeRagdoll) then
				local g = Threat(ply, other)
				if g > 0 and Sees(ply, other) then gain = math.max(gain, g) end
			end
		end
		if gain > 0 then hg.organism.AddRage(ply, gain * timeValue) end
		rage = org.rage or 0

		-- спадает, когда угроз нет
		if CurTime() - (org.rageLastThreat or 0) > R.calmDelay and (org.rageHitUntil or 0) < CurTime() then
			rage = math.max(rage - timeValue * R.decay, 0)
		end
	end
	org.rage = rage

	local stage = StageOf(rage)
	if stage > 0 and org.alive ~= false then
		org.ragePainRelief = R.painRelief[stage]
		if org.fear and org.fear > -1 then org.fear = math.max(org.fear - timeValue * R.fearDrop * stage, -1) end
		if R.adrenaline[stage] > 0 and org.adrenaline then org.adrenaline = math.max(org.adrenaline, R.adrenaline[stage]) end
	else
		org.ragePainRelief = 0
	end

	-- мысль при переходе на стадию выше
	local old = org.rageStage or 0
	if stage > old and org.isPly and ply.Notify then ply:Notify(stagePhrases[stage], true, "rage", 0) end
	org.rageStage = stage

	local r = math.Round(rage, 2)
	if r ~= org.rageSent then
		org.rageSent = r
		ply:SetNW2Float("rem_rage", r)
		ply:SetNW2Int("rem_rage_stage", stage)
	end
end

-- удар от другого игрока: рывок ярости, 3-я стадия открыта, рост x2
hook.Add("HomigradDamage", "rem_rage_hit", function(ply, dmgInfo)
	if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
	local org = ply.organism
	if not org then return end
	local attacker = PlayerOf(dmgInfo:GetAttacker())
	if not attacker or attacker == ply or dmgInfo:GetDamage() < R.hitMinDamage then return end
	org.rageHitUntil = CurTime() + R.hitWindow
	hg.organism.AddRage(ply, R.hitGain)
end)

-- "умри" в чат: злятся те, на кого он смотрит (или кто совсем рядом)
hook.Add("PlayerSay", "rem_rage_words", function(speaker, text)
	if not IsValid(speaker) or not speaker:Alive() then return end
	local hit = false
	for word in string.gmatch(text, "[^%s%p]+") do
		if wordsEn[string.lower(word)] then hit = true break end
		for _, w in ipairs(wordsRu) do
			if string.find(word, w, 1, true) then hit = true break end
		end
		if hit then break end
	end
	if not hit then return end
	for _, ply in player.Iterator() do
		if ply ~= speaker and ply:Alive() then
			local to = ply:EyePos() - speaker:EyePos()
			local dist = to:Length()
			if dist < R.wordRange and (dist < 150 or speaker:GetAimVector():Dot(to:GetNormalized()) > 0.85) then
				hg.organism.AddRage(ply, R.wordGain)
			end
		end
	end
end)

-- фак: злятся те, кому показали (видят его и он смотрит на них)
local function OnGesture(ply, anim)
	if anim ~= "fuckyou" or not IsValid(ply) then return end
	for _, other in player.Iterator() do
		if other ~= ply and other:Alive() then
			local to = other:EyePos() - ply:EyePos()
			if to:Length() < R.meleeRange * 1.5 and ply:GetAimVector():Dot(to:GetNormalized()) > 0.8 and Sees(other, ply) then
				hg.organism.AddRage(other, R.gestureGain)
			end
		end
	end
end

-- жесты в sv_zmanip.lua: оборачиваем hg.RunZManipAnim, когда всё загрузилось
local function WrapGestures()
	if not hg.RunZManipAnim or hg.RemRageWrapped then return end
	hg.RemRageWrapped = true
	local orig = hg.RunZManipAnim
	hg.RunZManipAnim = function(ply, anim, ...)
		OnGesture(ply, anim)
		return orig(ply, anim, ...)
	end
end
hook.Add("InitPostEntity", "rem_rage_gestures", WrapGestures)
timer.Simple(0, WrapGestures)

-- после смерти/возрождения - с нуля
local function Reset(ply)
	local org = ply.organism
	if org then org.rage, org.rageStage, org.rageHitUntil, org.ragePainRelief, org.rageSent = 0, 0, 0, 0, 0 end
	ply:SetNW2Float("rem_rage", 0)
	ply:SetNW2Int("rem_rage_stage", 0)
end
hook.Add("PlayerSpawn", "rem_rage_reset", Reset)
hook.Add("PlayerDeath", "rem_rage_reset", Reset)
