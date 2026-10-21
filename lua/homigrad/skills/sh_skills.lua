-- Прокачка: опыт (за убийства, раунды и т.п.) даёт уровни, за уровень - очко навыка.
-- Навыки по 5 рангов, от "слабый" до "сильный". Хранится на сервере в data/zcity_skills/.
hg.Skills = hg.Skills or {}
local SK = hg.Skills

SK.MaxRank = 5

-- per - бонус за ранг
SK.List = {
	{id = "strength", name = "Strength", desc = "+10% melee and fist damage per rank.", per = 0.10},
	{id = "endurance", name = "Endurance", desc = "-8% stamina drain per rank.", per = 0.08},
	{id = "toughness", name = "Toughness", desc = "-6% pain per rank.", per = 0.06},
	{id = "agility", name = "Agility", desc = "+6% jump height per rank.", per = 0.06},
	{id = "marksman", name = "Marksman", desc = "-8% weapon recoil per rank.", per = 0.08},
	{id = "runner", name = "Runner", desc = "+3% movement speed per rank.", per = 0.03},
	{id = "vitality", name = "Vitality", desc = "-8% blood loss per rank.", per = 0.08},
	{id = "quickhands", name = "Quick Hands", desc = "-6% reload time per rank.", per = 0.06},
	{id = "medic", name = "Medic", desc = "+15% faster bandaging and treating yourself per rank.", per = 0.15},
}

-- перки: хорошие покупаются за очки, плохие дают очки (снять плохой - вернуть очки).
-- mods - множители (melee, stamina, jump, recoil, speed, reload, medic, pain, bleed, xp, weight, oxygen, hunger),
-- laststand - прибавка к шансу последнего боя в %, conflicts - с каким перком нельзя вместе
SK.MaxBadPerks = 3

SK.Perks = {
	{id = "pickpocket", name = "Pickpocket", cost = 10, desc = "Crouch behind someone and hold E to steal an item from their pockets."},
	{id = "fastlearner", name = "Fast Learner", cost = 8, desc = "+25% XP.", mods = {xp = 1.25}, conflicts = "slowlearner"},
	{id = "lastbreath", name = "Last Breath", cost = 8, desc = "+15% chance of a last stand when you are dying.", laststand = 15, conflicts = "unlucky"},
	{id = "secondwind", name = "Second Wind", cost = 7, desc = "When you are out of breath, your stamina comes back once every 90 seconds."},
	{id = "thickblood", name = "Thick Blood", cost = 7, desc = "-25% blood loss.", mods = {bleed = 0.75}, conflicts = "hemophiliac"},
	{id = "silentsteps", name = "Silent Steps", cost = 6, desc = "Your footsteps are silent unless you run."},
	{id = "packmule", name = "Pack Mule", cost = 6, desc = "Your gear weighs 40% less.", mods = {weight = 0.6}},
	{id = "ironlungs", name = "Iron Lungs", cost = 6, desc = "Your body uses 35% less oxygen.", mods = {oxygen = 0.65}, conflicts = "asthmatic"},
	{id = "steadyhands", name = "Steady Hands", cost = 6, desc = "-15% weapon recoil.", mods = {recoil = 0.85}, conflicts = "shakyhands"},
	{id = "brawler", name = "Brawler", cost = 5, desc = "+20% melee and fist damage.", mods = {melee = 1.2}, conflicts = "weakling"},
	{id = "lightfeet", name = "Light Feet", cost = 4, desc = "+15% jump height.", mods = {jump = 1.15}},
	{id = "ironstomach", name = "Iron Stomach", cost = 3, desc = "You get hungry 40% slower.", mods = {hunger = 0.6}, conflicts = "glutton"},

	{id = "hemophiliac", name = "Hemophiliac", bad = true, gain = 6, desc = "+50% blood loss.", mods = {bleed = 1.5}, conflicts = "thickblood"},
	{id = "asthmatic", name = "Asthmatic", bad = true, gain = 5, desc = "+40% stamina drain, +25% oxygen use.", mods = {stamina = 1.4, oxygen = 1.25}, conflicts = "ironlungs"},
	{id = "sensitive", name = "Sensitive", bad = true, gain = 4, desc = "+25% pain.", mods = {pain = 1.25}},
	{id = "slowlearner", name = "Slow Learner", bad = true, gain = 4, desc = "-25% XP.", mods = {xp = 0.75}, conflicts = "fastlearner"},
	{id = "weakling", name = "Weakling", bad = true, gain = 4, desc = "-25% melee and fist damage.", mods = {melee = 0.75}, conflicts = "brawler"},
	{id = "shakyhands", name = "Shaky Hands", bad = true, gain = 4, desc = "+25% weapon recoil.", mods = {recoil = 1.25}, conflicts = "steadyhands"},
	{id = "sluggish", name = "Sluggish", bad = true, gain = 4, desc = "-8% movement speed.", mods = {speed = 0.92}},
	{id = "butterfingers", name = "Butterfingers", bad = true, gain = 3, desc = "Reloading takes 25% longer, treating yourself 20% longer.", mods = {reload = 1.25, medic = 0.8}},
	{id = "unlucky", name = "Unlucky", bad = true, gain = 3, desc = "-10% chance of a last stand.", laststand = -10, conflicts = "lastbreath"},
	{id = "glutton", name = "Glutton", bad = true, gain = 2, desc = "You get hungry 50% faster.", mods = {hunger = 1.5}, conflicts = "ironstomach"},
}

SK.PerkByID = {}
for _, perk in ipairs(SK.Perks) do SK.PerkByID[perk.id] = perk end

function SK.HasPerk(ply, id)
	return IsValid(ply) and ply:GetNWBool("perk_" .. id, false)
end

function SK.CountBadPerks(ply)
	local count = 0
	for _, perk in ipairs(SK.Perks) do
		if perk.bad and SK.HasPerk(ply, perk.id) then count = count + 1 end
	end
	return count
end

-- произведение множителей всех перков игрока по ключу
function SK.PerkMul(ply, key)
	local mul = 1
	for _, perk in ipairs(SK.Perks) do
		if perk.mods and perk.mods[key] and SK.HasPerk(ply, perk.id) then mul = mul * perk.mods[key] end
	end
	return mul
end

function SK.PerkLastStand(ply)
	local add = 0
	for _, perk in ipairs(SK.Perks) do
		if perk.laststand and SK.HasPerk(ply, perk.id) then add = add + perk.laststand end
	end
	return add
end

SK.RankNames = {[0] = "Untrained", "Weak", "Average", "Good", "Strong", "Very strong"}

SK.ByID = {}
for _, skill in ipairs(SK.List) do SK.ByID[skill.id] = skill end

-- сколько опыта нужно, чтобы перейти с уровня level на следующий
function SK.XPForLevel(level)
	return 100 + level * 50
end

function SK.GetRank(ply, id)
	return IsValid(ply) and ply:GetNWInt("skill_" .. id, 0) or 0
end

function SK.Bonus(ply, id)
	return SK.GetRank(ply, id) * SK.ByID[id].per
end

-- Pickpocket: вор стоит за спиной, если жертва смотрит от него
SK.PickpocketBehindDot = -0.3

function SK.IsBehind(thief, target)
	local toThief = thief:GetPos() - target:GetPos()
	toThief.z = 0
	if toThief:LengthSqr() < 1 then return false end
	toThief:Normalize()

	local forward = target:GetAimVector()
	forward.z = 0
	forward:Normalize()

	return forward:Dot(toThief) < SK.PickpocketBehindDot
end
