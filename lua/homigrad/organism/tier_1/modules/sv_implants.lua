-- Импланты (ставятся предметами weapon_implant_*; на себя - ЛКМ, лежащему - ПКМ). После смерти их нет (ClearImplants).
--   heart    - искусственное сердце: не останавливается и не сбивается с ритма (нет аритмии, фибрилляции, остановки
--              от холода, кровопотери и т.п.), ровно качает ~80 ударов; останавливается только если его разбить
--              (повреждение сердца 100%) или при смерти мозга;
--   lungs    - синтетические лёгкие: не спадаются (нет пневмоторакса), сами чинятся, быстрее насыщают кислородом,
--              быстро выводят угарный газ;
--   nanites  - кровяные наноботы: кровотечение вдвое слабее, обычные раны понемногу затягиваются, кровь восстанавливается;
--   painblock - болевой блокатор: боль вдвое меньше;
--   adrenal  - адреналиновый имплант: когда совсем плохо (мало крови, сильная боль, мало здоровья), сам впрыскивает
--              адреналин (не чаще раза в 2.5 минуты).
-- Клиенту - NW2 "rem_implant_<id>" (значки в осмотре).
-- Хранятся на самом человеке (ply.rem_implants), а не в организме: пока человек лежит рэгдоллом, владелец организма -
-- рэгдолл, и раньше имплант записывался на него (значка не было, а после смерти он оставался).
hg.organism.ImplantList = {"heart", "lungs", "nanites", "painblock", "adrenal"}

-- человек за этим телом: игрок / NPC; для рэгдолла - его хозяин
local function Person(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() or ent:IsNPC() then return ent end
	if ent:IsRagdoll() then
		local p = hg.RagdollOwner and hg.RagdollOwner(ent)
		if not IsValid(p) then p = ent:GetNWEntity("ply") end
		if IsValid(p) then return p end
	end
	return ent
end
hg.organism.ImplantPerson = Person

function hg.organism.HasImplant(ent, id)
	local p = Person(ent)
	return IsValid(p) and p.rem_implants and p.rem_implants[id] or false
end

function hg.organism.InstallImplant(owner, org, id)
	local person = Person(owner)
	if not IsValid(person) then return false end
	person.rem_implants = person.rem_implants or {}
	if person.rem_implants[id] then return false end
	person.rem_implants[id] = true
	if id == "heart" then
		org.heart = 0
		org.heartstop = false
		org.fibrillation = false
		org.arrhythmia = 0
	elseif id == "lungs" then
		org.pneumothorax = 0
	end
	person:SetNW2Bool("rem_implant_" .. id, true)
	return true
end

local function Approach(a, b, d) return math.Approach(a or b, b, d) end

function hg.organism.Implants(owner, org, timeValue)
	local person = Person(owner)
	local imp = IsValid(person) and person.rem_implants or nil
	org.implantBleedMul = imp and imp.nanites and 0.5 or 1
	org.implantPainMul = imp and imp.painblock and 0.5 or 1
	if not imp or org.alive == false then return end

	if imp.heart and (org.brain or 0) < 0.6 and (org.heart or 0) < 1 then
		org.heartstop = false
		org.heartstoptime = nil
		org.fibrillation = false
		org.arrhythmia = 0
		org.heartStrain = 0
		org.myocardialOxygen = math.max(org.myocardialOxygen or 1, 0.9)
		org.heartbeat = Approach(org.heartbeat, 80, timeValue * 20)
		org.pulse = math.max(org.pulse or 0, 40 * math.Clamp((org.blood or 5000) / 5000, 0.2, 1))
	end

	if imp.lungs then
		org.pneumothorax = 0
		if org.lungsL then org.lungsL = math.max(org.lungsL - timeValue / 60, 0) end
		if org.lungsR then org.lungsR = math.max(org.lungsR - timeValue / 60, 0) end
		if org.CO then org.CO = math.max(org.CO - timeValue * 2, 0) end
		if org.o2 and org.o2[1] then org.o2[1] = math.min(org.o2[1] + timeValue * 0.4, org.o2.range or 30) end
	end

	if imp.nanites then
		local changed = false
		for i = #(org.wounds or {}), 1, -1 do
			local w = org.wounds[i]
			w[1] = w[1] - timeValue * 0.08
			if w[1] <= 0 then table.remove(org.wounds, i) end
			changed = true
		end
		if changed and (org.implantWoundSync or 0) < CurTime() then
			org.implantWoundSync = CurTime() + 1
			owner:SetNetVar("wounds", org.wounds)
		end
		if (org.blood or 5000) < 5000 then org.blood = math.min(org.blood + timeValue * 4, 5000) end
	end

	if imp.adrenal and (org.implantAdrenalNext or 0) < CurTime() then
		local bad = (org.blood or 5000) < 3500 or (org.pain or 0) > 90 or (person:IsPlayer() and person:Health() < 30)
		if bad then
			org.implantAdrenalNext = CurTime() + 150
			org.adrenalineAdd = (org.adrenalineAdd or 0) + 1.5
			if org.isPly and not org.otrub and person.Notify then person:Notify("Adrenal implant engaged.", true, "implant", 0) end
		end
	end
end

-- умер - имплантов больше нет (организм при возрождении не всегда создаётся заново, поэтому чистим сами:
-- и при смерти, и при возрождении, и на тик позже - если организм пересобирается после хука)
function hg.organism.ClearImplants(ply)
	if not IsValid(ply) then return end
	ply.rem_implants = nil
	local org = ply.organism
	if org then
		org.implants = nil
		org.implantBleedMul = 1
		org.implantPainMul = 1
		org.implantAdrenalNext = nil
	end
	for _, id in ipairs(hg.organism.ImplantList) do ply:SetNW2Bool("rem_implant_" .. id, false) end
end

hook.Add("PlayerDeath", "rem_implants_reset", hg.organism.ClearImplants)
hook.Add("PlayerSilentDeath", "rem_implants_reset", hg.organism.ClearImplants)
hook.Add("PlayerSpawn", "rem_implants_reset", function(ply)
	hg.organism.ClearImplants(ply)
	timer.Simple(0, function() hg.organism.ClearImplants(ply) end)
end)
