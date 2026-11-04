-- Сосуды: сужение и расширение (тонус сосудов). org.vessels от -1 (сильно сужены) до +1 (сильно расширены).
-- Что сужает: холод (тело остывает), кровопотеря (организм сжимает сосуды, чтобы держать давление), шок, страх,
--   адреналин и особенно норадреналин, сильная боль, никотин.
-- Что расширяет: жара / перегрев, нагрузка (бег, удары - sv_bodyheat.lua), обезболивающие (опиаты), алкоголь.
-- Если крови совсем мало, сосуды "сдаются" и расширяются (декомпенсированный шок) - давление падает.
-- Что меняется:
--   сужены  - раны кровят слабее, тепло уходит медленнее, давление выше, кожа бледнеет, пальцы немеют;
--   расширены - раны кровят сильнее, тело быстрее отдаёт тепло (остывает), давление ниже - при малой крови кружится голова.
-- Использование: sv_organism.lua (вызов перед кровью), sv_blood.lua (кровотечение), sv_pulse.lua (давление, температура),
-- клиент - cl_vessels.lua (бледность / покраснение по NW2 "rem_vessels").
local Clamp, Approach = math.Clamp, math.Approach

local V = {
	coldStart = 36.2, coldFull = 33.2,   -- °C: ниже - сужение, до -1 при coldFull
	heatStart = 37.2, heatFull = 38.7,   -- °C: выше - расширение, до +1 при heatFull
	exertion = 0.35,                     -- расширение от полной нагрузки
	bloodStart = 4500, bloodFull = 3200, -- мл: кровопотеря сужает (до -0.8)
	bloodFail = 2500,                    -- мл: ниже - сосуды "сдаются" и расширяются
	analgesia = 0.35,                    -- расширение от обезболивающих
	adrenaline = 0.12,                   -- сужение на единицу адреналина (до 3)
	noradrenaline = 0.45,                -- сужение на единицу норадреналина (до 2)
	pain = 0.15,                         -- сужение от боли 100%
	fear = 0.1,
	shock = 0.25,                        -- сужение при шоке 40+
	speedIn = 0.25,                      -- скорость сужения (в секунду)
	speedOut = 0.12,                     -- скорость расширения (в секунду)
}
hg.organism.VesselsConfig = V

local function Target(owner, org)
	local t = 0
	local temp = org.temperature or 36.7
	if temp < V.coldStart then
		t = t - Clamp((V.coldStart - temp) / (V.coldStart - V.coldFull), 0, 1)
	elseif temp > V.heatStart then
		t = t + Clamp((temp - V.heatStart) / (V.heatFull - V.heatStart), 0, 1)
	end

	t = t + (org.exertion or 0) * V.exertion
	t = t + Clamp((org.analgesia or 0) / 1.5, 0, 1) * V.analgesia
	t = t + math.min((org.alcoholEff or org.alcohol or 0) * 0.25, 0.6) -- алкоголь расширяет (sv_alcohol.lua)
	t = t - math.min((org.nicotine or 0) * 0.25, 0.45) -- никотин сужает (sv_nicotine.lua)
	t = t - math.min(org.adrenaline or 0, 3) * V.adrenaline
	t = t - math.min(org.noradrenaline or 0, 2) * V.noradrenaline
	t = t - Clamp((org.pain or 0) / 120, 0, 1.5) * V.pain
	t = t - math.max(org.fear or 0, 0) * V.fear
	t = t - Clamp((org.shock or 0) / 40, 0, 1) * V.shock

	local blood = org.blood or 5000
	if blood < V.bloodFail then
		-- декомпенсация: чем меньше крови, тем сильнее сосуды расширяются, что бы ни было
		return Clamp(math.Remap(blood, V.bloodFail, 1500, 0.1, 0.8), 0.1, 0.8)
	elseif blood < V.bloodStart then
		t = t - Clamp((V.bloodStart - blood) / (V.bloodStart - V.bloodFull), 0, 1) * 0.8
	end

	return Clamp(t, -1, 1)
end

local notifyCold = {
	"My fingers are going numb from the cold...",
	"I'm so cold my hands are white...",
	"Can't feel my fingertips...",
}
local notifyHot = {
	"My face is burning up...",
	"I'm flushed, my skin is on fire...",
	"So hot... my veins are bulging...",
}
local notifyDizzy = {
	"I feel lightheaded...",
	"Everything is spinning...",
	"I'm about to pass out...",
}

function hg.organism.Vessels(owner, org, timeValue)
	local v = org.vessels or 0
	if org.alive == false or org.heartstop then
		v = Approach(v, 0.6, timeValue * V.speedOut) -- без кровотока тонус уходит
	else
		local target = Target(owner, org)
		v = Approach(v, target, timeValue * (target < v and V.speedIn or V.speedOut))
	end
	org.vessels = v

	-- множители для крови: обычные раны сильно зависят от тонуса, артерии - слабее
	org.vesselBleedMul = 1 + 0.6 * v
	org.vesselArteryMul = 1 + 0.3 * v

	if IsValid(owner) and owner:IsPlayer() then
		local rounded = math.Round(v, 2)
		if math.abs(rounded - (org.vesselsSent or 0)) >= 0.02 then
			org.vesselsSent = rounded
			owner:SetNW2Float("rem_vessels", rounded)
		end

		if org.isPly and not org.otrub and owner:Alive() and (org.vesselNotify or 0) < CurTime() then
			if v < -0.7 and (org.temperature or 36.7) < 35.5 then
				owner:Notify(table.Random(notifyCold), true, "vessels", 0)
				org.vesselNotify = CurTime() + math.Rand(40, 70)
			elseif v > 0.5 and (org.blood or 5000) < 4000 and (org.bloodPressure or 90) < 70 then
				owner:Notify(table.Random(notifyDizzy), true, "vessels", 0)
				org.vesselNotify = CurTime() + math.Rand(30, 50)
			elseif v > 0.75 and (org.temperature or 36.7) > 38 then
				owner:Notify(table.Random(notifyHot), true, "vessels", 0)
				org.vesselNotify = CurTime() + math.Rand(40, 70)
			end
		end
	end
end
