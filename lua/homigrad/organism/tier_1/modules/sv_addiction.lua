-- Привыкание и ломка (алкоголь - sv_alcohol.lua, никотин - sv_nicotine.lua).
-- Зависимость (0..1) хранится на игроке, а не в организме: после смерти и возрождения она остаётся (пока игрок на сервере),
-- без употребления медленно проходит (полностью - примерно за 40 минут).
--   растёт, пока вещество в крови: алкоголь - ~2 бутылки водки до сильной зависимости, никотин - ~5-6 сигарет;
--   толерантность: при зависимости алкоголь действует слабее (до -40%), сигарета не вызывает кашля и головокружения;
--   ломка (с зависимости 0.25, когда вещества в крови почти нет; нарастает за 2-3 минуты, снимается дозой за секунды):
--     никотин - тревога, раздражение, лёгкий тремор, "хочу курить";
--     алкоголь - тревога, сильный тремор, головная боль, тошнота и рвота, при тяжёлой зависимости - судороги
--                (белая горячка).
-- На клиенте: NW2 "rem_dep_<вид>" и "rem_wd_<вид>" - тремор (cl_addiction.lua) и значки в осмотре.
hg.Addiction = hg.Addiction or {}
local AD = hg.Addiction

AD.Kinds = {
	alcohol = {
		level = function(org) return org.alcohol or 0 end,
		grow = 0.0004,      -- зависимость в секунду на промилле
		clean = 0.2,        -- ниже этого - "трезвый", начинается ломка
		decay = 1 / 2400,   -- проходит без употребления
		develop = 180,      -- секунд до полной ломки
	},
	nicotine = {
		level = function(org) return org.nicotine or 0 end,
		grow = 0.0012,
		clean = 0.15,
		decay = 1 / 2400,
		develop = 150,
	},
}

local craving = {
	nicotine = {"I need a smoke...", "Where are my cigarettes...", "Just one cigarette...", "My hands won't stop fidgeting..."},
	alcohol = {"I need a drink...", "My hands are shaking... need a drink...", "Just one shot and I'll be fine...", "My head is killing me..."},
}

function AD.Get(ply, kind)
	local d = IsValid(ply) and ply.rem_addict and ply.rem_addict[kind]
	return d and d.dep or 0, d and d.wd or 0
end

local function Sync(owner, kind, d)
	local dep, wd = math.Round(d.dep, 2), math.Round(d.wd, 2)
	if dep ~= d.sentDep then d.sentDep = dep owner:SetNW2Float("rem_dep_" .. kind, dep) end
	if wd ~= d.sentWd then d.sentWd = wd owner:SetNW2Float("rem_wd_" .. kind, wd) end
end

local function Withdrawal(owner, org, kind, d, timeValue)
	local wd = d.wd
	if wd < 0.05 or org.alive == false then return end

	-- тревога и раздражение у обоих
	if wd > 0.25 then org.fearadd = math.max(org.fearadd or 0, wd * (kind == "alcohol" and 0.8 or 0.4)) end

	if kind == "alcohol" then
		org.painadd = (org.painadd or 0) + timeValue * wd * 0.4 -- голова раскалывается
		if org.depression then org.depression = math.min(org.depression + timeValue * wd * 0.002, 1) end -- и тоска
		-- тошнит и рвёт (обычная рвота, sv_vomit.lua)
		if hg.organism.AddNausea then
			hg.organism.AddNausea(owner, org, timeValue * math.max(wd - 0.4, 0) * 0.006 * math.Rand(0.5, 1.5))
		end
		-- белая горячка: судороги при тяжёлой зависимости
		if wd > 0.75 and d.dep > 0.6 and hg.organism.AddSeizure then
			hg.organism.AddSeizure(org, timeValue * 0.002 * wd)
		end
	end

	-- свои эффекты ломки у вида (наркотики - sv_drugs.lua)
	local k = AD.Kinds[kind]
	if k and k.effects then k.effects(owner, org, d, wd, timeValue) end

	local phrases = craving[kind] or (k and k.craving)
	if phrases and org.isPly and not org.otrub and wd > 0.3 and (d.notify or 0) < CurTime() then
		d.notify = CurTime() + math.Rand(50, 90) * (1.3 - wd)
		owner:Notify(table.Random(phrases), true, "addiction_" .. kind, 0)
	end
end

function hg.organism.Addiction(owner, org, timeValue)
	if not IsValid(owner) or not owner:IsPlayer() then return end
	owner.rem_addict = owner.rem_addict or {}
	for kind, k in pairs(AD.Kinds) do
		local d = owner.rem_addict[kind]
		if not d then
			d = {dep = 0, wd = 0}
			owner.rem_addict[kind] = d
		end
		local lvl = k.level(org)
		if lvl > 0.02 then
			d.dep = math.min(1, d.dep + timeValue * k.grow * lvl)
		else
			d.dep = math.max(0, d.dep - timeValue * k.decay)
		end

		if d.dep > 0.25 and lvl < k.clean and org.alive ~= false then
			d.wd = math.Approach(d.wd, d.dep, timeValue / k.develop)
		else
			d.wd = math.Approach(d.wd, 0, timeValue / 8)
		end

		Withdrawal(owner, org, kind, d, timeValue)
		Sync(owner, kind, d)
	end
end

-- после возрождения ломка начинается заново (зависимость остаётся)
hook.Add("PlayerSpawn", "rem_addiction_spawn", function(ply)
	if not ply.rem_addict then return end
	for kind, d in pairs(ply.rem_addict) do
		d.wd = 0
		d.vomit = 0
		Sync(ply, kind, d)
	end
end)
