-- Пули.
--
-- У InfMap есть хук EntityFireBullets, который переводит bullet.Src в локальные
-- координаты и возвращает true. С Z-City это ломается:
--   * Z-City стреляет Lua-пулями (FireLuaBullets / FireCSSBullets) и сам вызывает
--     hook.Run("EntityFireBullets") - хук InfMap портит Src, и пуля игрока из чанка
--     (1,0,0) вылетает из той же точки, но в чанке 0;
--   * return true останавливает остальные хуки: физические пули, пули NPC Z-City
--     и т.д. не срабатывают, если игрок не в чанке 0.
--
-- Вместо этого:
--   * хук InfMap снимаем;
--   * Lua-пули работают в мировых координатах как есть (трассы InfMap уже мировые);
--   * для пуль движка (Entity:FireBullets и выстрелы NPC) все хуки видят мировые
--     координаты, а в локальные Src переводится уже после всех хуков.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero
local ZERO = ZCInf.ZERO

local CallInChunk = ZCInf.CallInChunk or function(_, fn, ...) return fn(...) end

local EntityMT = FindMetaTable("Entity")
local PlayerMT = FindMetaTable("Player")

hook.Remove("EntityFireBullets", "infmap_bulletdetour")

local luaDepth = 0      -- внутри FireLuaBullets / FireCSSBullets (всё в мировых координатах)
local engineFromLua = 0 -- внутри Entity:FireBullets, вызванного из Lua (Src мировой)

local function guarded(counter, fn, ...)
	local res
	if counter == "lua" then
		luaDepth = luaDepth + 1
		res = {pcall(fn, ...)}
		luaDepth = luaDepth - 1
	else
		engineFromLua = engineFromLua + 1
		res = {pcall(fn, ...)}
		engineFromLua = engineFromLua - 1
	end
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2, table.maxn(res))
end

ZCInf.Detour(EntityMT, "FireBullets", function(orig)
	return function(self, bullet, suppress)
		return guarded("engine", orig, self, bullet, suppress)
	end
end)

-- функции Lua-пуль объявляет Z-City (lua/homigrad/sh_luabullets.lua), он грузится позже
local function wrapLuaBullets()
	local ok = true
	if EntityMT.FireLuaBullets then
		ZCInf.Detour(EntityMT, "FireLuaBullets", function(orig)
			return function(self, ...) return guarded("lua", orig, self, ...) end
		end)
	else
		ok = false
	end
	if PlayerMT.FireCSSBullets then
		ZCInf.Detour(PlayerMT, "FireCSSBullets", function(orig)
			return function(self, ...) return guarded("lua", orig, self, ...) end
		end)
	end
	return ok
end

hook.Add("Initialize", "ZCInf_LuaBullets", function()
	if not wrapLuaBullets() then
		ZCInf.Print("FireLuaBullets не найден - Lua-пули Z-City не обёрнуты")
	end
end)

local function toWorldTrace(tr, c)
	if type(tr) ~= "table" then return end
	if isvector(tr.HitPos) then tr.HitPos = ZCInf.ToWorld(tr.HitPos, c) end
	if isvector(tr.StartPos) then tr.StartPos = ZCInf.ToWorld(tr.StartPos, c) end
end

local processing = setmetatable({}, {__mode = "k"})
local wraps = ZCInf.HookWraps

wraps.EntityFireBullets = function(call, name, gm, ent, data, ...)
	if luaDepth > 0 or type(data) ~= "table" or not isvector(data.Src) or processing[data] or not IsValid(ent) then
		return call(name, gm, ent, data, ...)
	end

	local c = ent.CHUNK_OFFSET or ZERO
	local fromLua = engineFromLua > 0

	-- выстрел NPC и т.п. изнутри движка: Src локальный, хукам отдаём мировой
	if not fromLua then
		if IsZero(c) then return call(name, gm, ent, data, ...) end
		data.Src = ZCInf.ToWorld(data.Src, c)
	end

	processing[data] = true
	local res = {pcall(call, name, gm, ent, data, ...)}
	processing[data] = nil
	if not res[1] then error(res[2], 0) end

	local r1 = res[2]
	if r1 == false then return false end

	if fromLua and IsZero(c) then
		-- всё в чанке 0: координаты совпадают, ничего не меняем
		local lp, d = InfMap.localize_vector(data.Src)
		if IsZero(d) then return unpack(res, 2, table.maxn(res)) end
		c = d
	end

	-- обратно в координаты движка (чанк стрелка)
	local lp = ZCInf.ToLocal(data.Src, c)
	if not ZCInf.InBounds(lp) then
		local d
		lp, d = InfMap.localize_vector(data.Src)
		c = d
	end
	data.Src = lp

	-- в Callback движок отдаёт локальную трассу - переводим в мировую
	local cb = data.Callback
	if isfunction(cb) and not IsZero(c) then
		local chunk = c
		data.Callback = function(att, tr, dmg)
			toWorldTrace(tr, chunk)
			return CallInChunk(chunk, cb, att, tr, dmg)
		end
	end

	return true
end

local converted = setmetatable({}, {__mode = "k"})

wraps.PostEntityFireBullets = function(call, name, gm, ent, data, ...)
	if luaDepth == 0 and type(data) == "table" and not converted[data] and IsValid(ent) then
		local c = ent.CHUNK_OFFSET
		if not IsZero(c) then
			converted[data] = true
			if isvector(data.Src) then data.Src = ZCInf.ToWorld(data.Src, c) end
			toWorldTrace(data.Trace, c)
		end
	end
	return call(name, gm, ent, data, ...)
end

ZCInf.Mark("bullets")
