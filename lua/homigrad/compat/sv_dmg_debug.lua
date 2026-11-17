-- Отладка урона (жалоба: с Artagdoll от огнестрела почти нет урона - в голову нужно 20-50 пуль вместо одной).
-- rem_debug_dmg 1 - в консоль сервера на каждое попадание пулей по игроку или его регдоллу:
--   какой хук EntityTakeDamage / ScalePlayerDamage изменил урон или заблокировал его (вернул true),
--   hitgroup из HomigradDamage, расстояние точки попадания до головы, и что стало с организмом (мозг, кровь, сознание).
-- Хуки оборачиваются только пока включено (и раз в 2 с - новые); выключил - обёртки снимаются.
local cv = CreateConVar("rem_debug_dmg", "0", FCVAR_ARCHIVE, "Print who changes or blocks bullet damage on players (server console)", 0, 1)

local wrapped = {} -- [событие][имя] = {orig, wrap}

local function IsBullet(dmg)
	return dmg and (dmg:IsBulletDamage() or dmg:IsDamageType(DMG_BULLET + DMG_BUCKSHOT))
end

local function Owner(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent end
	if ent:IsRagdoll() and hg and hg.RagdollOwner then
		local p = hg.RagdollOwner(ent)
		if IsValid(p) then return p end
	end
end

local function Who(ent)
	local p = Owner(ent)
	return ("%s%s"):format(IsValid(ent) and ent:GetClass() or "?", IsValid(p) and (" (" .. p:Nick() .. ")") or "")
end

local function Wrap(event, dmgArg)
	local tbl = hook.GetTable()[event]
	if not tbl then return end
	wrapped[event] = wrapped[event] or {}
	for name, fn in pairs(tbl) do
		local w = wrapped[event][name]
		if not (w and w.wrap == fn) and name ~= "rem_debug_dmg" then
			local orig = fn
			local wrap = function(...)
				local args = {...}
				local dmg = args[dmgArg]
				local ent = args[1]
				if not (cv:GetBool() and IsBullet(dmg) and Owner(ent)) then return orig(...) end
				local before = dmg:GetDamage()
				local r = {orig(...)}
				local after = dmg:GetDamage()
				if r[1] ~= nil then
					print(("[rem_dmg] %s: хук %s \"%s\" вернул %s (урон %.1f) - %s"):format(Who(ent), event, tostring(name),
						tostring(r[1]), after, r[1] == true and "УРОН ЗАБЛОКИРОВАН" or "дальше не идут остальные хуки"))
				elseif math.abs(after - before) > 0.01 then
					print(("[rem_dmg] %s: хук %s \"%s\" изменил урон %.1f -> %.1f"):format(Who(ent), event, tostring(name), before, after))
				end
				return unpack(r)
			end
			wrapped[event][name] = {orig = orig, wrap = wrap}
			hook.Add(event, name, wrap)
		end
	end
end

local function Unwrap()
	for event, list in pairs(wrapped) do
		local tbl = hook.GetTable()[event] or {}
		for name, w in pairs(list) do
			if tbl[name] == w.wrap then hook.Add(event, name, w.orig) end
		end
	end
	wrapped = {}
end

local function WrapAll()
	Wrap("EntityTakeDamage", 2)
	Wrap("ScalePlayerDamage", 3)
end

timer.Create("rem_debug_dmg", 2, 0, function()
	if cv:GetBool() then WrapAll() elseif next(wrapped) then Unwrap() end
end)
cvars.AddChangeCallback("rem_debug_dmg", function(_, _, new)
	if new == "1" then WrapAll() else Unwrap() end
end, "rem_debug_dmg")

-- состояние организма до урона (запоминаем в начале, печатаем после)
hook.Add("EntityTakeDamage", "rem_debug_dmg", function(ent, dmg)
	if not cv:GetBool() or not IsBullet(dmg) then return end
	local ply = Owner(ent)
	if not ply then return end
	local org = ply.organism
	ent.remDbgDmg = {t = CurTime(), dmg = dmg:GetDamage(), brain = org and org.brain or 0, blood = org and org.blood or 0,
		cons = org and org.consciousness or 0}
end)

hook.Add("HomigradDamage", "rem_debug_dmg", function(ply, dmg, hitgroup, ent)
	if not cv:GetBool() or not IsBullet(dmg) then return end
	local body = IsValid(ply) and ply:IsRagdoll() and ply or (IsValid(ply) and ply.FakeRagdoll) or ply
	local p = Owner(ply)
	local head = IsValid(body) and body:LookupBone("ValveBiped.Bip01_Head1")
	local hp = head and body:GetBonePosition(head)
	if IsValid(body) and body:IsRagdoll() and head then
		local phys = body:GetPhysicsObjectNum(body:TranslateBoneToPhysBone(head))
		if IsValid(phys) then hp = phys:GetPos() end
	end
	print(("[rem_dmg] HomigradDamage %s: урон %.1f, hitgroup %s, до головы %s, Artagdoll на теле: %s"):format(
		Who(ply), dmg:GetDamage(), tostring(hitgroup), hp and ("%.0f"):format(dmg:GetDamagePosition():Distance(hp)) or "?",
		tostring(IsValid(body) and (body.remArtag or body.remArtagAlive) and true or false)))
end)

hook.Add("PostEntityTakeDamage", "rem_debug_dmg", function(ent, dmg, took)
	if not cv:GetBool() or not IsBullet(dmg) then return end
	local ply = Owner(ent)
	if not ply then return end
	local b = ent.remDbgDmg
	ent.remDbgDmg = nil
	local amount, who = dmg:GetDamage(), Who(ent) -- dmg после хука уже недействителен
	timer.Simple(0.1, function()
		if not IsValid(ply) then return end
		local org = ply.organism or {}
		print(("[rem_dmg] %s: урон %.1f, прошёл: %s, мозг %.2f -> %.2f, кровь %.0f -> %.0f, сознание %.2f -> %.2f, жив: %s"):format(
			who, amount, tostring(took), b and b.brain or -1, org.brain or 0, b and b.blood or -1, org.blood or 0,
			b and b.cons or -1, org.consciousness or 0, tostring(ply:Alive())))
	end)
end)
