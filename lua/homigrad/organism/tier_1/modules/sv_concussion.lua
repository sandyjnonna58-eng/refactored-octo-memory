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
end

function hg.organism.AddConcussion(org, amount)
	if not org or amount <= 0 then return end
	org.concussion = math.min((org.concussion or 0) + amount, concussion_max)
end

for i = 1, 3 do resource.AddSingleFile("sound/shellshock/" .. i .. ".mp3") end
