-- Жёсткие наркотики (предметы weapon_rem_heroin / weapon_rem_meth / weapon_rem_lsd). Уровни в крови - org.heroin,
-- org.meth, org.lsd (доза ~1), выводятся за несколько минут. Тик - из sv_organism.lua (после никотина).
--   героин: боль почти не чувствуется (analgesia), страх и тоска уходят, клонит в сон; передоз (> 1.8) - дыхание
--           угнетено, кислород падает (гипоксия, сердце по SCAV, смерть). Налоксон (org.naloxone) выводит быстро.
--           Подташнивает. Привыкание сильное, ломка - боль, тошнота и рвота, тревога, тремор.
--   мет:    сил много (выносливость), пульс выше (org.remHRAdd -> sv_pulse.lua), паранойя (страх); передоз (> 2.5) -
--           сердце (фибрилляция), жар. Привыкание, ломка - тоска, вялость.
--   кислота: трип (экран - cl_drugs.lua), странные мысли; передоз (> 2) - бэд-трип: паника (sv_panic.lua) и страх.
--           Привыкания нет.
-- «Веселье» (эйфория 0..1) - NW2 "rem_high" (плитка euphoria в осмотре); уровни - NW2 "rem_heroin" / "rem_meth" / "rem_lsd".
hg.Drugs = hg.Drugs or {}
local D = hg.Drugs

D.Config = {
	heroin = {eliminate = 0.0055, overdose = 1.8},
	meth = {eliminate = 0.004, overdose = 2.5},
	lsd = {eliminate = 0.0033, overdose = 2.0},
}
local C = D.Config

local thoughts = {
	heroin = {"Everything's... warm...", "Nothing hurts anymore...", "Just a little nap...", "I feel so good...", "Why was I worried..."},
	heroin_od = {"Can't... breathe...", "So heavy... so tired...", "Just... close my eyes..."},
	meth = {"I can do ANYTHING!", "Gotta move, gotta move!", "Who's watching me?", "They're following me...", "My heart's pounding... it's fine..."},
	meth_od = {"My chest... it's burning...", "Heart's gonna explode...", "TOO FAST, TOO FAST..."},
	lsd = {"The walls are breathing...", "I can hear colours...", "Everything is connected...", "My hands look so weird...", "Whoa... the floor is melting..."},
	lsd_od = {"Make it stop! MAKE IT STOP!", "I'm not real... nothing is real...", "THEY'RE IN MY HEAD!"},
}

-- привыкание (sv_addiction.lua): героин и мет; ломка - свои эффекты (effects) и мысли (craving).
-- Регистрируем при загрузке и, если sv_addiction загрузился позже, - на первом тике
local function RegisterKinds()
	if not (hg.Addiction and hg.Addiction.Kinds) or hg.Addiction.Kinds.heroin then return end
	hg.Addiction.Kinds.heroin = {
		level = function(org) return org.heroin or 0 end,
		grow = 0.0035, clean = 0.12, decay = 1 / 3600, develop = 120,
		craving = {"I need a fix...", "Just one more shot...", "Everything hurts... I need it...", "Where's my stash..."},
		effects = function(owner, org, d, wd, timeValue)
			org.painadd = (org.painadd or 0) + timeValue * wd * 0.8 -- кости ломит
			if hg.organism.AddNausea then hg.organism.AddNausea(owner, org, timeValue * math.max(wd - 0.3, 0) * 0.012 * math.Rand(0.5, 1.5)) end
			org.fearadd = math.max(org.fearadd or 0, wd * 0.7)
		end,
	}
	hg.Addiction.Kinds.meth = {
		level = function(org) return org.meth or 0 end,
		grow = 0.0028, clean = 0.12, decay = 1 / 3000, develop = 150,
		craving = {"I need a hit...", "So tired... need a bump...", "Can't think straight without it...", "Everything is grey..."},
		effects = function(owner, org, d, wd, timeValue)
			if org.depression then org.depression = math.min(org.depression + timeValue * wd * 0.004, 1) end
			if org.stamina and org.stamina[1] then org.stamina[1] = math.max(org.stamina[1] - timeValue * wd * 4, 0) end
		end,
	}
end
RegisterKinds()

local function Think(owner, org, kind, key)
	if not org.isPly or org.otrub or (org["drugThought_" .. key] or 0) > CurTime() then return end
	org["drugThought_" .. key] = CurTime() + math.Rand(18, 35)
	if owner.Notify then owner:Notify(table.Random(thoughts[kind]), true, "rem_drug_" .. key, 0) end
end

local function Send(owner, org, key, value)
	local r = math.Round(value, 2)
	if math.abs(r - (org["drugSent_" .. key] or 0)) >= 0.03 or (r == 0 and (org["drugSent_" .. key] or 0) ~= 0) then
		org["drugSent_" .. key] = r
		owner:SetNW2Float(key, r)
	end
end

function hg.organism.Drugs(owner, org, timeValue)
	RegisterKinds()
	local heroin, meth, lsd = org.heroin or 0, org.meth or 0, org.lsd or 0
	org.remHRAdd = 0
	if heroin <= 0 and meth <= 0 and lsd <= 0 then
		if org.drugSent_rem_high and org.drugSent_rem_high ~= 0 and IsValid(owner) and owner:IsPlayer() then
			for _, key in ipairs({"rem_high", "rem_heroin", "rem_meth", "rem_lsd"}) do Send(owner, org, key, 0) end
		end
		return
	end
	local alive = org.alive ~= false

	-- выведение (налоксон гонит героин)
	heroin = math.max(heroin - timeValue * C.heroin.eliminate * (1 + (org.naloxone or 0) * 20), 0)
	meth = math.max(meth - timeValue * C.meth.eliminate, 0)
	lsd = math.max(lsd - timeValue * C.lsd.eliminate, 0)
	org.heroin, org.meth, org.lsd = heroin, meth, lsd

	if alive then
		-- героин
		if heroin > 0 then
			org.analgesia = math.max(org.analgesia or 0, math.min(heroin * 0.7, 1))
			if org.fear then org.fear = math.max(org.fear - timeValue * heroin * 0.08, -1) end
			org.consciousness = math.min(org.consciousness or 1, 1 - math.Clamp((heroin - 1.2) * 0.3, 0, 0.6))
			if hg.organism.AddNausea and heroin > 0.6 then hg.organism.AddNausea(owner, org, timeValue * heroin * 0.0015 * math.Rand(0, 2)) end
			org.remHRAdd = org.remHRAdd - heroin * 10
			local od = heroin - C.heroin.overdose
			if od > 0 and istable(org.o2) and org.o2[1] then
				-- дыхание угнетено: кислород уходит (гипоксия -> сердце, мозг)
				org.o2[1] = math.max(org.o2[1] - timeValue * math.min(od * 3.5, 7), 0)
				Think(owner, org, "heroin_od", "heroin")
			elseif heroin > 0.4 then
				Think(owner, org, "heroin", "heroin")
			end
		end
		-- мет
		if meth > 0 then
			if org.stamina and org.stamina[1] and org.stamina.max then
				org.stamina[1] = math.min(org.stamina[1] + timeValue * meth * 6, org.stamina.max)
			end
			org.remHRAdd = org.remHRAdd + meth * 30
			if meth > 1 then org.fearadd = math.max(org.fearadd or 0, (meth - 1) * 0.35) end -- паранойя
			local od = meth - C.meth.overdose
			if od > 0 then
				if hg.organism.AddCardiacStress then hg.organism.AddCardiacStress(org, timeValue * od * 0.02) end
				if org.temperature then org.temperature = math.min(org.temperature + timeValue * od * 0.02, 42) end
				Think(owner, org, "meth_od", "meth")
			elseif meth > 0.4 then
				Think(owner, org, "meth", "meth")
			end
		end
		-- кислота
		if lsd > 0 then
			local od = lsd - C.lsd.overdose
			if od > 0 then
				org.panic = math.min((org.panic or 0) + timeValue * od * 0.03, 1) -- бэд-трип
				org.fearadd = math.max(org.fearadd or 0, od * 0.6)
				Think(owner, org, "lsd_od", "lsd")
			elseif lsd > 0.3 then
				Think(owner, org, "lsd", "lsd")
			end
		end
	end

	-- «Веселье»: тоска и страх уходят (кроме паранойи от мета и бэд-трипа)
	local high = math.Clamp(heroin * 0.55 + meth * 0.45 + lsd * 0.5, 0, 1)
	if alive and high > 0 then
		if org.depression then org.depression = math.max(org.depression - timeValue * high * 0.004, 0) end
	end

	if IsValid(owner) and owner:IsPlayer() then
		Send(owner, org, "rem_high", high)
		Send(owner, org, "rem_heroin", heroin)
		Send(owner, org, "rem_meth", meth)
		Send(owner, org, "rem_lsd", lsd)
	end
end

-- принять дозу (предметы): kind - "heroin" / "meth" / "lsd"
function D.Dose(ent, kind, amount)
	local org = IsValid(ent) and ent.organism
	if not org then return false end
	org[kind] = math.min((org[kind] or 0) + amount, 6)
	return true
end

-- тест (админ): rem_drug_set <heroin|meth|lsd> <уровень>
concommand.Add("rem_drug_set", function(ply, _, args)
	if IsValid(ply) and not ply:IsAdmin() then return end
	if not IsValid(ply) or not ply.organism then return end
	local kind = args[1]
	if not C[kind] then return end
	ply.organism[kind] = math.Clamp(tonumber(args[2]) or 1, 0, 6)
end)
