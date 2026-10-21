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

-- перки покупаются один раз за несколько очков навыка
SK.Perks = {
	{id = "pickpocket", name = "Pickpocket", cost = 10, desc = "Crouch behind someone and hold E to steal an item from their pockets."},
	{id = "lastbreath", name = "Last Breath", cost = 8, desc = "+15% chance of a last stand when you are dying."},
	{id = "secondwind", name = "Second Wind", cost = 7, desc = "When you are out of breath, your stamina comes back once every 90 seconds."},
	{id = "silentsteps", name = "Silent Steps", cost = 6, desc = "Your footsteps are silent unless you run."},
}

SK.PerkByID = {}
for _, perk in ipairs(SK.Perks) do SK.PerkByID[perk.id] = perk end

function SK.HasPerk(ply, id)
	return IsValid(ply) and ply:GetNWBool("perk_" .. id, false)
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
