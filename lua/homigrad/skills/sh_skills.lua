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
}

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
