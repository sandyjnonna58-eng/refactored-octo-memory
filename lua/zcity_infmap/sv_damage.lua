-- Позиция урона (CTakeDamageInfo:Set/GetDamagePosition).
--
-- InfMap переводит GetDamagePosition в мировые координаты, прибавляя чанк инфликтора,
-- но SetDamagePosition не трогает. Z-City сам создаёт DamageInfo для каждой пули и
-- задаёт позицию в мировых координатах -> при чтении чанк прибавляется второй раз,
-- и попадание оказывается за 20000+ юнитов от тела: органы, кости, кровь и броня
-- не находят попадание. В нулевом чанке ошибки не видно.
--
-- Решение:
--   * SetDamagePosition запоминает мировую позицию и отдаёт движку локальную
--     (в чанке жертвы, если она известна);
--   * GetDamagePosition возвращает запомненную мировую позицию, а для урона от
--     движка - локальную позицию + чанк жертвы (её знаем по событию урона);
--   * TakeDamageInfo / DispatchTraceAttack / TakePhysicsDamage переводят позицию
--     и трассу в чанк жертвы перед передачей движку.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero
local InBounds = ZCInf.InBounds
local ZERO = ZCInf.ZERO

local EntityMT = FindMetaTable("Entity")
local DmgMT = FindMetaTable("CTakeDamageInfo")

local rawSet = DmgMT.ZCInf_SetDamagePosition or DmgMT.SetDamagePosition
local rawGet = DmgMT.InfMap_GetDamagePosition
local infGet = DmgMT.ZCInf_GetDamagePosition or DmgMT.GetDamagePosition -- версия InfMap (по инфликтору)

if not rawGet then
	ZCInf.Print("CTakeDamageInfo: InfMap_GetDamagePosition не найден, позиция урона не исправлена")
	return
end

-- мировая позиция, заданная из Lua: [dmginfo] = {pos = мировая, raw = что отдали движку}
local records = setmetatable({}, {__mode = "k"})

-- стек чанков "текущей жертвы" (урон обрабатывается синхронно, бывает вложенным)
local stack = {}
local function frame()
	return stack[#stack]
end

function ZCInf.CallInChunk(chunk, fn, ...)
	local d = #stack
	stack[d + 1] = chunk or ZERO
	local res = {pcall(fn, ...)}
	for i = #stack, d + 1, -1 do stack[i] = nil end
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2, table.maxn(res))
end
local CallInChunk = ZCInf.CallInChunk

-- на всякий случай: вне обработки урона стек всегда пуст
hook.Add("Think", "ZCInf_DamageStack", function()
	if stack[1] ~= nil then
		for i = #stack, 1, -1 do stack[i] = nil end
	end
end)

ZCInf.Detour(DmgMT, "SetDamagePosition", function(orig)
	return function(self, pos)
		local c = frame()
		local lp
		if c ~= nil then
			lp = ZCInf.ToLocal(pos, c)
			if not InBounds(lp) then lp = nil end
		end
		if lp == nil then lp = InfMap.localize_vector(pos) end
		orig(self, lp)
		records[self] = {pos = Vector(pos), raw = lp}
	end
end)

ZCInf.Detour(DmgMT, "GetDamagePosition", function()
	return function(self)
		local raw = rawGet(self)
		local r = records[self]
		if r ~= nil and r.raw == raw then return Vector(r.pos) end

		local c = frame()
		if c ~= nil then return ZCInf.ToWorld(raw, c) end

		-- вне события урона: как у InfMap, по чанку инфликтора, а если его нет - атакующего
		local inf = self:GetInflictor()
		if not IsValid(inf) or inf.CHUNK_OFFSET == nil then
			local att = self:GetAttacker()
			if IsValid(att) and att.CHUNK_OFFSET ~= nil then
				return ZCInf.ToWorld(raw, att.CHUNK_OFFSET)
			end
		end
		return infGet(self)
	end
end)

-- перевести запомненную мировую позицию в чанк жертвы
local function relocalize(dmg, c)
	local r = records[dmg]
	if r == nil or rawGet(dmg) ~= r.raw then return end
	local lp = ZCInf.ToLocal(r.pos, c)
	if not InBounds(lp) then return end
	rawSet(dmg, lp)
	r.raw = lp
end

local function chunkOf(ent)
	return (ent ~= nil and ent.CHUNK_OFFSET) or ZERO
end

for _, name in ipairs({"TakeDamageInfo", "TakePhysicsDamage"}) do
	ZCInf.Detour(EntityMT, name, function(orig)
		return function(self, dmg, ...)
			local c = chunkOf(self)
			if dmg ~= nil then relocalize(dmg, c) end
			return CallInChunk(c, orig, self, dmg, ...)
		end
	end)
end

local function localTrace(tr, c)
	if type(tr) ~= "table" or IsZero(c) then return tr end
	local t = {}
	for k, v in pairs(tr) do t[k] = v end
	if isvector(t.HitPos) then t.HitPos = ZCInf.ToLocal(t.HitPos, c) end
	if isvector(t.StartPos) then t.StartPos = ZCInf.ToLocal(t.StartPos, c) end
	return t
end

ZCInf.Detour(EntityMT, "DispatchTraceAttack", function(orig)
	return function(self, dmg, tr, dir)
		local c = chunkOf(self)
		if dmg ~= nil then relocalize(dmg, c) end
		return CallInChunk(c, orig, self, dmg, localTrace(tr, c), dir)
	end
end)

-- util.BlastDamageInfo InfMap не переводит (в отличие от util.BlastDamage)
ZCInf.Detour(util, "BlastDamageInfo", function(orig)
	return function(dmg, pos, radius)
		local lp, c = InfMap.localize_vector(pos)
		if IsZero(c) then return orig(dmg, pos, radius) end
		relocalize(dmg, c)
		return CallInChunk(c, orig, dmg, lp, radius)
	end
end)

--[[ События урона от движка: первый аргумент - жертва ]]
local wraps = ZCInf.HookWraps
local function victimWrap(call, name, gm, victim, ...)
	if victim == nil or victim.CHUNK_OFFSET == nil then
		return CallInChunk(ZERO, call, name, gm, victim, ...)
	end
	return CallInChunk(victim.CHUNK_OFFSET, call, name, gm, victim, ...)
end

for _, ev in ipairs({
	"EntityTakeDamage",
	"PostEntityTakeDamage",
	"ScalePlayerDamage",
	"ScaleNPCDamage",
	"PlayerTraceAttack",
	"DoPlayerDeath",
	"OnDamagedByExplosion",
}) do
	wraps[ev] = victimWrap
end

ZCInf.Mark("damage position")
