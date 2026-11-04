-- Никотин (сигареты - weapon_hg_cigarettes). org.nicotine - уровень в крови (одна сигарета ~1), выводится за пару минут.
-- Что делает: сужает сосуды (sv_vessels.lua: руки холоднее, раны кровят чуть меньше, давление выше), немного учащает
-- пульс, успокаивает (страх меньше) - особенно того, кого ломает (sv_addiction.lua); у некурящего от затяжки кашель,
-- от нескольких подряд кружится голова и мутит. Дым - угарный газ (org.CO в лёгких, sv_lungs.lua) понемногу.
local N = {
	eliminate = 0.008,  -- в секунду
	calm = 0.06,        -- снятие страха в секунду на единицу никотина
	dizzy = 2.2,        -- выше - голова кружится (у некурящих)
}
hg.organism.NicotineConfig = N

function hg.organism.Nicotine(owner, org, timeValue)
	local nic = org.nicotine or 0
	if nic <= 0 then
		if org.nicotineSent and org.nicotineSent ~= 0 and IsValid(owner) then
			org.nicotineSent = 0
			owner:SetNW2Float("rem_nicotine", 0)
		end
		return
	end
	nic = math.max(nic - timeValue * N.eliminate, 0)
	org.nicotine = nic

	if org.alive ~= false then
		if org.fear and org.fear > -1 then org.fear = math.max(org.fear - timeValue * N.calm * math.min(nic, 2), -1) end
		-- "перекурил": у некурящих кружится голова и подташнивает
		local dep = hg.Addiction and hg.Addiction.Get and hg.Addiction.Get(owner, "nicotine") or 0
		local over = nic - N.dizzy * (1 + dep * 2)
		if over > 0 then
			org.wantToVomit = (org.wantToVomit or 0) + timeValue * over * 0.01
			org.consciousness = math.min(org.consciousness or 1, 1 - math.min(over * 0.15, 0.4))
		end
	end

	if IsValid(owner) and owner:IsPlayer() then
		local r = math.Round(nic, 2)
		if math.abs(r - (org.nicotineSent or 0)) >= 0.03 or (r == 0 and org.nicotineSent ~= 0) then
			org.nicotineSent = r
			owner:SetNW2Float("rem_nicotine", r)
		end
	end
end
