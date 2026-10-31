-- Тепло тела (используется в sv_pulse.lua, там температура тянется к "нужной"):
-- * нагрузка (бег, спринт, удары по другим) копится в org.exertion 0..1 и поднимает нужную температуру,
--   до +1.8 °C при полной (36.7 -> 38.5); в покое нагрузка медленно спадает;
-- * в воде нужная температура ниже и тело остывает быстрее, чем глубже - тем сильнее.
local EXERTION_SPRINT = 0.06 -- в секунду спринта
local EXERTION_JOG = 0.025   -- в секунду бега
local EXERTION_HIT = 0.06    -- за удар по кому-то
local EXERTION_DECAY = 0.015 -- в секунду покоя
local EXERTION_HEAT = 1.8    -- °C сверху при полной нагрузке

-- по уровню воды (1 - по колено, 2 - по пояс, 3 - с головой): на сколько ниже нужная температура и во сколько раз быстрее
local WATER_COOL = {0.8, 1.8, 3.2}
local WATER_RATE = {1.5, 2.5, 4}

-- возвращает добавку к нужной температуре и множитель скорости её изменения
function hg.organism.BodyHeat(owner, org, timeValue)
	local exertion = org.exertion or 0
	local moving = false

	if IsValid(owner) and owner:IsPlayer() and owner:Alive() and not IsValid(owner.FakeRagdoll) then
		local speed = owner:GetVelocity():Length2D()
		if speed > 60 and (owner:OnGround() or owner:WaterLevel() >= 2) then
			if owner:KeyDown(IN_SPEED) and speed > 180 then
				exertion = exertion + timeValue * EXERTION_SPRINT
				moving = true
			elseif speed > 100 then
				exertion = exertion + timeValue * EXERTION_JOG
				moving = true
			end
		end
	end

	local char = IsValid(owner) and owner:IsPlayer() and hg.GetCurrentCharacter and hg.GetCurrentCharacter(owner) or owner
	local water = IsValid(char) and math.Clamp(char:WaterLevel(), 0, 3) or 0

	-- в воде нагрузка остывает втрое быстрее
	if not moving then exertion = exertion - timeValue * EXERTION_DECAY * (water > 0 and 3 or 1) end
	exertion = math.Clamp(exertion, 0, 1)
	org.exertion = exertion

	local offset, rate = exertion * EXERTION_HEAT, 1
	if water > 0 then
		offset = offset * (water >= 2 and 0 or 0.5) - WATER_COOL[water]
		rate = WATER_RATE[water]
	end
	return offset, rate
end

-- удары ближнего боя греют того, кто бьёт
hook.Add("EntityTakeDamage", "rem_bodyheat_hits", function(target, dmginfo)
	local attacker = dmginfo:GetAttacker()
	if not IsValid(attacker) or not attacker:IsPlayer() or attacker == target then return end
	if bit.band(dmginfo:GetDamageType(), DMG_CLUB + DMG_SLASH) == 0 then return end
	local org = attacker.organism
	if not org then return end
	org.exertion = math.min((org.exertion or 0) + EXERTION_HIT, 1)
end)
