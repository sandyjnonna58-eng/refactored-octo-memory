-- Давление и пульс с монитора осмотра действуют на игрока (уровни - sh_cardio.lua, картинка - cl_cardio.lua).
-- Зовётся из "Org Think" Main (sv_organism.lua) сразу после пульса (sv_pulse.lua).
--   низкое давление (сист. < 100, полностью к 65): медленнее ходишь (до -25%, NW2 rem_cardio_move -> sh_inertia.lua),
--     выносливость восстанавливается медленнее; ниже 75 на бегу ноги могут подкоситься - падаешь (раз в 25 с);
--   высокое (> 165, полностью к 215): болит голова (боль до 25), с 195 дольше 5 с - кровь из носа 20..40 с (немного
--     крови теряешь, капли видят все - NW2 rem_nosebleed), с 205 - тошнит; инсульт от давления - sv_stroke.lua;
--   редкий пульс (< 55, полностью к 30): слабость - ещё до -20% к скорости.
-- Мысли - не чаще раза в 45..75 с. Выкл.: rem_cardio 0.
hg.Cardio = hg.Cardio or {}
local C = hg.Cardio

local cv = CreateConVar("rem_cardio", "1", FCVAR_ARCHIVE, "Blood pressure and heart rate affect the player (speed, stamina, headache, nosebleed, collapse)", 0, 1)

C.move_low = 0.25       -- до -25% скорости при низком давлении
C.move_brady = 0.2      -- и до -20% при редком пульсе
C.stamina_low = 4       -- выносливости в секунду меньше восстанавливается (у sv_stamina ~6..14 в секунду)
C.collapse_sys = 75     -- ниже - на бегу можно упасть
C.collapse_chance = 0.12 -- шанс в секунду x уровень низкого давления
C.collapse_cd = 25
C.headache_pain = 30    -- боль от давления не выше (120 = 100%)
C.headache_rate = 4     -- painadd в секунду x уровень
C.nose_sys, C.nose_hold = 195, 5
C.nose_blood = 2        -- мл в секунду
C.nausea_sys = 205
C.nausea_rate = 0.01    -- тошнота сама проходит 0.003/с (sv_vomit.lua)

local THOUGHTS = {
	low = {"I feel lightheaded...", "My head is spinning.", "Everything goes dark when I move.", "My legs feel like jelly..."},
	high = {"My head is pounding...", "I can feel my pulse in my temples.", "My head is about to burst."},
	brady = {"I feel so weak...", "My heart is so slow...", "I can barely keep going."},
	tachy = {"My heart is pounding.", "I can feel my heart hammering in my chest."},
	nose = {"My nose is bleeding...", "Blood... from my nose?"},
	collapse = {"My legs gave out...", "Everything went black for a second..."},
}

local function Say(owner, org, kind, force)
	local now = CurTime()
	if not force and now < (org.remCardioSaid or 0) then return end
	org.remCardioSaid = now + math.Rand(45, 75)
	if owner.Notify then owner:Notify(table.Random(THOUGHTS[kind]), true, "rem_cardio", 0, nil, Color(255, 190, 190)) end
end

local function SetNW(owner, org, move, nose)
	if org.remCardioMoveSent ~= move then
		org.remCardioMoveSent = move
		owner:SetNW2Float("rem_cardio_move", move)
	end
	if org.remNoseSent ~= nose then
		org.remNoseSent = nose
		owner:SetNW2Bool("rem_nosebleed", nose)
	end
end

local L = {}
function hg.organism.Cardio(owner, org, timeValue)
	if not org.isPly or not IsValid(owner) or not owner:IsPlayer() then return end
	local now = CurTime()

	-- тест rem_test_bp: подменить давление/пульс на время (пересчитываются sv_pulse.lua каждый тик - сами вернутся)
	local test = org.remBPTest
	if test then
		if now > test.untilT then
			org.remBPTest = nil
		else
			org.systolic = test.sys
			org.diastolic = math.Round(test.sys * 0.64)
			if test.hr then org.heartbeat = test.hr end
		end
	end

	if not cv:GetBool() or not org.alive or not owner:Alive() then SetNW(owner, org, 1, false) return end
	C.Levels(org, L)

	SetNW(owner, org, math.Round(math.Clamp(1 - C.move_low * L.low - C.move_brady * L.brady, 0.5, 1), 2), (org.remNoseEnd or 0) > now)

	-- кровь из носа: давление долго выше порога
	if (L.sys or 0) >= C.nose_sys then org.remHighT = (org.remHighT or 0) + timeValue else org.remHighT = 0 end
	if org.remHighT >= C.nose_hold and now > (org.remNoseNext or 0) then
		org.remNoseEnd = now + math.Rand(20, 40)
		org.remNoseNext = org.remNoseEnd + 60
		if not org.otrub then Say(owner, org, "nose", true) end
	end
	if (org.remNoseEnd or 0) > now then org.blood = math.max((org.blood or 5000) - timeValue * C.nose_blood, 0) end

	if org.otrub then return end

	-- низкое давление: выносливость восстанавливается медленнее (вычитаем часть прироста sv_stamina этого тика)
	local st = org.stamina
	if L.low > 0 and istable(st) and isnumber(st[1]) and st[1] < (st.max or 180) then
		st[1] = math.max(st[1] - timeValue * C.stamina_low * L.low, 0)
	end

	-- низкое давление на бегу: в глазах темнеет, ноги подкашиваются
	if (L.sys or 120) < C.collapse_sys and now > (org.remCardioCollapseT or 0) and not IsValid(owner.FakeRagdoll)
		and owner:OnGround() and owner:KeyDown(IN_SPEED) and owner:GetVelocity():Length2D() > 160
		and math.Rand(0, 1) < timeValue * C.collapse_chance * L.low then
		org.remCardioCollapseT = now + C.collapse_cd
		if hg.Fake then hg.Fake(owner) end
		Say(owner, org, "collapse", true)
	end

	-- высокое давление: голова раскалывается, при кризисе тошнит
	if L.high > 0 then
		if (org.pain or 0) < C.headache_pain * L.high then
			org.painadd = (org.painadd or 0) + timeValue * C.headache_rate * L.high
		end
		if L.sys >= C.nausea_sys and hg.organism.AddNausea then
			hg.organism.AddNausea(owner, org, timeValue * C.nausea_rate)
		end
	end

	if L.low >= 0.3 then Say(owner, org, "low")
	elseif L.high >= 0.3 then Say(owner, org, "high")
	elseif L.brady >= 0.4 then Say(owner, org, "brady")
	elseif L.tachy >= 0.6 then Say(owner, org, "tachy") end
end

local function Reset(ply)
	local org = ply.organism
	if org then org.remNoseEnd, org.remHighT, org.remBPTest = nil, 0, nil end
	ply:SetNW2Float("rem_cardio_move", 1)
	ply:SetNW2Bool("rem_nosebleed", false)
	if org then org.remCardioMoveSent, org.remNoseSent = 1, false end
end
hook.Add("PlayerSpawn", "rem_cardio", Reset)
hook.Add("PlayerDeath", "rem_cardio", Reset)
