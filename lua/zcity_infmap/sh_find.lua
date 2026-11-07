-- ents.FindInSphere / ents.FindInBox.
--
-- InfMap заменяет их перебором ВСЕХ сущностей с вызовом WorldSpaceCenter у каждой.
-- Z-City вызывает поиск очень часто (каждый тик, на каждый выстрел, у каждого
-- игрока), и на сервере с кучей ragdoll'ов/пропов это заметно тормозит.
--
-- Если область поиска целиком лежит в одном чанке, ищем быстрым поиском движка
-- в сырых координатах этого чанка и отбрасываем сущности из других чанков.
-- Иначе (область на стыке чанков) - старый медленный поиск InfMap.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero

local engineSphere = InfMap.FindInSphere -- оригинал движка, InfMap его сохранил
local engineBox = InfMap.FindInBox

if not engineSphere or not engineBox then return end

-- оставить только сущности из чанка chunk.
-- Сущности без CHUNK_OFFSET (их InfMap не переносит между чанками) на сервере
-- считаются стоящими в чанке 0, а на клиенте - в чанке LocalPlayer'а
-- (это клиентские модели, руки, viewmodel и т.п.).
local SameChunk = ZCInf.SameChunk
local function chunkFilter(results, chunk, nilMatches)
	local out, n = {}, 0
	for i = 1, #results do
		local e = results[i]
		local c = e.CHUNK_OFFSET
		local ok
		if c == nil then
			ok = nilMatches or IsZero(chunk)
		else
			ok = SameChunk(c, chunk)
		end
		if ok then
			n = n + 1
			out[n] = e
		end
	end
	return out
end

if SERVER then
	ZCInf.Detour(ents, "FindInSphere", function(slow)
		return function(pos, radius)
			local lp, chunk = InfMap.localize_vector(pos)
			local lim = InfMap.chunk_size - radius
			if lim <= 0 or not InfMap.in_chunk(lp, lim) then return slow(pos, radius) end
			return chunkFilter(engineSphere(lp, radius), chunk)
		end
	end)

	ZCInf.Detour(ents, "FindInBox", function(slow)
		return function(mins, maxs)
			local lmin, chunk = InfMap.localize_vector(mins)
			local lmax = maxs - (mins - lmin)
			local cs = InfMap.chunk_size
			if not InfMap.in_chunk(lmin, cs) or not InfMap.in_chunk(lmax, cs) then return slow(mins, maxs) end
			return chunkFilter(engineBox(lmin, lmax), chunk)
		end
	end)
else
	-- на клиенте сырые координаты = координаты относительно чанка LocalPlayer'а
	ZCInf.Detour(ents, "FindInSphere", function(slow)
		return function(pos, radius)
			local chunk = ZCInf.LPChunk()
			if chunk == nil then return slow(pos, radius) end
			local lim = InfMap.chunk_size - radius
			if lim <= 0 or not InfMap.in_chunk(pos, lim) then return slow(pos, radius) end
			return chunkFilter(engineSphere(pos, radius), chunk, true)
		end
	end)

	ZCInf.Detour(ents, "FindInBox", function(slow)
		return function(mins, maxs)
			local chunk = ZCInf.LPChunk()
			local cs = InfMap.chunk_size
			if chunk == nil or not InfMap.in_chunk(mins, cs) or not InfMap.in_chunk(maxs, cs) then return slow(mins, maxs) end
			return chunkFilter(engineBox(mins, maxs), chunk, true)
		end
	end)
end

ZCInf.Mark("ents.FindInSphere/FindInBox")
