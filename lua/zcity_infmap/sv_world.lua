-- Эффекты, звуки, декали и содержимое точки на сервере.
--
-- Сервер шлёт клиентам эффекты и звуки с координатами, а клиент рисует всё
-- относительно своего чанка. Плюс координаты дальше ±16384 движок обрезает.
-- Поэтому для каждого чанка, где есть игроки, координаты переводятся отдельно
-- и отправляются только этим игрокам. Пока все игроки и эффект в чанке 0,
-- всё идёт как обычно, без изменений.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero
local InBounds = ZCInf.InBounds
local ZERO = ZCInf.ZERO

local function isNullVec(v)
	return v[1] == 0 and v[2] == 0 and v[3] == 0
end

-- игроки, сгруппированные по чанкам: { {chunk = Vector, plys = {...}}, ... }
local function groupByChunk(list)
	local groups, byKey = {}, {}
	for i = 1, #list do
		local ply = list[i]
		if IsValid(ply) then
			local c = ply.CHUNK_OFFSET or ZERO
			local key = InfMap.ezcoord(c)
			local g = byKey[key]
			if g == nil then
				g = {chunk = c, plys = {}}
				byKey[key] = g
				groups[#groups + 1] = g
			end
			g.plys[#g.plys + 1] = ply
		end
	end
	return groups
end

-- нужно ли вообще что-то делать с этой точкой
local function needsFix(pos)
	return ZCInf.AnyOffChunk() or not InfMap.in_chunk(pos)
end

--[[-------------------------------------------------------------------------
	util.Effect
---------------------------------------------------------------------------]]
local GetPredictionPlayer = GetPredictionPlayer

local function effectRecipients(rf)
	if type(rf) == "CRecipientFilter" then return rf:GetPlayers() end
	local list = player.GetAll()
	-- как у движка: игрок, у которого эффект уже предсказан на клиенте, его не получает
	if rf ~= true and GetPredictionPlayer then
		local pred = GetPredictionPlayer()
		if IsValid(pred) then
			for i = #list, 1, -1 do
				if list[i] == pred then table.remove(list, i) end
			end
		end
	end
	return list
end

ZCInf.Detour(util, "Effect", function(orig)
	return function(name, data, allowOverride, rf)
		local origin = data:GetOrigin()
		local ent = data:GetEntity()
		-- эффект привязан к сущности, а origin не задан: позицию берём у сущности, origin не трогаем
		local keepOrigin = isNullVec(origin) and IsValid(ent)
		local refPos = keepOrigin and ent:GetPos() or origin

		if not needsFix(refPos) then return orig(name, data, allowOverride, rf) end

		local start = data:GetStart()
		local hasStart = not isNullVec(start)

		for _, g in ipairs(groupByChunk(effectRecipients(rf))) do
			if InBounds(ZCInf.ToLocal(refPos, g.chunk)) then
				if not keepOrigin then data:SetOrigin(ZCInf.ToLocal(origin, g.chunk)) end
				if hasStart then data:SetStart(ZCInf.ToLocal(start, g.chunk)) end
				local f = RecipientFilter()
				f:AddPlayers(g.plys)
				orig(name, data, allowOverride, f)
			end
		end

		data:SetOrigin(origin)
		data:SetStart(start)
	end
end)
ZCInf.Mark("util.Effect")

--[[-------------------------------------------------------------------------
	sound.Play и EmitSound(позиция) без сущности.
	Шлём клиентам их координаты, а проигрывает клиент сам.
---------------------------------------------------------------------------]]
util.AddNetworkString("zcinf_sound")

local HEAR_DIST = 12000 -- дальше этого звук точно не слышно

local function sendSound(list, kind, snd, pos, level, pitch, volume, dsp, channel, flags)
	for _, g in ipairs(groupByChunk(list)) do
		local rel = ZCInf.ToLocal(pos, g.chunk)
		if InBounds(rel) then
			local plys = {}
			for _, ply in ipairs(g.plys) do
				if ply:GetPos():DistToSqr(pos) < HEAR_DIST * HEAR_DIST then plys[#plys + 1] = ply end
			end
			if #plys > 0 then
				net.Start("zcinf_sound", true)
				net.WriteUInt(kind, 2)
				net.WriteString(snd)
				net.WriteFloat(rel[1])
				net.WriteFloat(rel[2])
				net.WriteFloat(rel[3])
				net.WriteUInt(math.Clamp(math.floor(level or 75), 0, 511), 9)
				net.WriteUInt(math.Clamp(math.floor(pitch or 100), 0, 255), 8)
				net.WriteFloat(volume or 1)
				net.WriteUInt(math.Clamp(math.floor(dsp or 0), 0, 255), 8)
				net.WriteInt(channel or CHAN_AUTO, 8)
				net.WriteUInt(math.Clamp(math.floor(flags or 0), 0, 1023), 10)
				net.Send(plys)
			end
		end
	end
end

ZCInf.Detour(sound, "Play", function(orig)
	return function(snd, pos, level, pitch, volume, dsp)
		if not isvector(pos) or not isstring(snd) or not needsFix(pos) then
			return orig(snd, pos, level, pitch, volume, dsp)
		end
		sendSound(player.GetAll(), 1, snd, pos, level, pitch, volume, dsp)
	end
end)

ZCInf.Detour(_G, "EmitSound", function(orig)
	return function(snd, pos, entity, channel, volume, level, flags, pitch, dsp, filter)
		local worldSound = entity == nil or entity == 0 or entity == -1
			or (isentity(entity) and (not IsValid(entity) or entity:IsWorld()))
		local list = player.GetAll()
		if type(filter) == "CRecipientFilter" then list = filter:GetPlayers() end
		if (filter ~= nil and type(filter) ~= "CRecipientFilter") or not worldSound or not isvector(pos) or not isstring(snd) or not needsFix(pos) then
			if isvector(pos) and isentity(entity) and IsValid(entity) and entity.CHUNK_OFFSET ~= nil then
				-- звук на сущности: позиция в координатах её чанка
				pos = ZCInf.ToLocal(pos, entity.CHUNK_OFFSET)
			end
			return orig(snd, pos, entity, channel, volume, level, flags, pitch, dsp, filter)
		end
		sendSound(list, 2, snd, pos, level, pitch, volume, dsp, channel, flags)
	end
end)
ZCInf.Mark("sound.Play/EmitSound")

--[[-------------------------------------------------------------------------
	util.Decal и util.PointContents: движку нужны локальные координаты.
---------------------------------------------------------------------------]]
ZCInf.Detour(util, "Decal", function(orig)
	return function(name, s, e, filter)
		local ls, c = InfMap.localize_vector(s)
		if IsZero(c) then return orig(name, s, e, filter) end
		return orig(name, ls, e - c * ZCInf.ChunkSpan(), filter)
	end
end)

ZCInf.Detour(util, "PointContents", function(orig)
	return function(pos)
		return orig((InfMap.localize_vector(pos)))
	end
end)
ZCInf.Mark("util.Decal/PointContents")
