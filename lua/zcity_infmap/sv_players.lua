-- Игроки: фейк (ragdoll), смерть, наблюдатели, спавн.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero
local ZERO = ZCInf.ZERO

--[[-------------------------------------------------------------------------
	Игрок в фейке.
	Ragdoll и игрок должны быть в одном чанке, иначе клиент рисует ragdoll и
	камеру со сдвигом в 20000 юнитов. Поэтому:
	  * InfMap не переносит сам игрока в фейке между чанками (его ведёт ragdoll);
	  * когда InfMap переносит ragdoll, в тот же момент переносится и его игрок.
---------------------------------------------------------------------------]]
local origStatus = InfMap.ZCInf_constrained_status or InfMap.constrained_status
InfMap.ZCInf_constrained_status = origStatus

function InfMap.constrained_status(ent)
	if ent:IsPlayer() and ent:Alive() and IsValid(ent.FakeRagdoll) then return false end
	return origStatus(ent)
end

local function ownerOf(rag)
	local ply = rag:GetNWEntity("ply")
	if not IsValid(ply) or not ply:IsPlayer() then return nil end
	if ply.FakeRagdoll == rag or ply.RagdollDeath == rag or ply:GetNWEntity("RagdollDeath") == rag then
		return ply
	end
	return nil
end

local function movePlayerToChunk(ply, chunk)
	if ply.CHUNK_OFFSET == chunk then return end
	local world = ply:GetPos() -- мировая позиция в старом чанке
	InfMap.prop_update_chunk(ply, chunk)
	ply:InfMap_SetPos(ZCInf.Clamp(ZCInf.ToLocal(world, chunk)))
end

hook.Add("PropUpdateChunk", "ZCInf_FakeSync", function(ent, chunk)
	if not IsValid(ent) or not ent:IsRagdoll() then return end
	local ply = ownerOf(ent)
	if ply == nil or ply:InVehicle() then return end
	movePlayerToChunk(ply, chunk)
end)
ZCInf.Mark("fake ragdoll chunk sync")

--[[-------------------------------------------------------------------------
	Наблюдатели.
	В режимах слежки движок ставит наблюдателя в сырые координаты цели, а чанк
	у наблюдателя остаётся старым. Свободный полёт мёртвого игрока InfMap не
	переносит между чанками вообще.
---------------------------------------------------------------------------]]
local cs1
timer.Create("ZCInf_Spectators", 0.1, 0, function()
	cs1 = InfMap.chunk_size + 1
	for _, ply in player.Iterator() do
		local mode = ply:GetObserverMode()
		if mode ~= OBS_MODE_NONE then
			local target = ply:GetObserverTarget()
			if mode ~= OBS_MODE_ROAMING and IsValid(target) and target.CHUNK_OFFSET ~= nil then
				if ply.CHUNK_OFFSET ~= target.CHUNK_OFFSET then
					InfMap.prop_update_chunk(ply, target.CHUNK_OFFSET)
				end
			elseif mode == OBS_MODE_ROAMING and ply.CHUNK_OFFSET ~= nil then
				local raw = ply:InfMap_GetPos()
				if not InfMap.in_chunk(raw, cs1) then
					local lp, delta = InfMap.localize_vector(raw)
					InfMap.prop_update_chunk(ply, ply.CHUNK_OFFSET + delta)
					ply:InfMap_SetPos(lp)
				end
			end
		end
	end
end)
ZCInf.Mark("spectators")

--[[-------------------------------------------------------------------------
	Спавн.
	InfMap в PlayerSpawn сбрасывает игрока в чанк 0. Но если какой-то хук
	Z-City уже успел поставить игрока на точку (SetPos), сброс уведёт его
	в чанк 0 с теми же локальными координатами. Плюс при OverrideSpawn
	(вставание из фейка) Z-City оставляет игрока на месте.
	Сбрасываем раньше - в PlayerSelectSpawn (движок ставит игрока на точку
	спавна из чанка 0 уже после него), а в PlayerSpawn - только если
	PlayerSelectSpawn не вызывался. При OverrideSpawn не сбрасываем вообще.
---------------------------------------------------------------------------]]
hook.Remove("PlayerSpawn", "infmap_plyreset")

hook.Add("PlayerSelectSpawn", "ZCInf_ChunkReset", function(ply)
	ply.ZCInf_SpawnReset = engine.TickCount()
	-- вставание из фейка (hg.FakeUp): Z-City делает Spawn(), оставляя игрока на месте
	if OverrideSpawn then return end
	if not IsZero(ply.CHUNK_OFFSET) or ply.CHUNK_OFFSET == nil then
		InfMap.prop_update_chunk(ply, Vector(0, 0, 0))
	end
end)

hook.Add("PlayerSpawn", "ZCInf_ChunkReset", function(ply)
	if OverrideSpawn then return end
	if ply.ZCInf_SpawnReset == engine.TickCount() then return end
	if ply.CHUNK_OFFSET == nil or not IsZero(ply.CHUNK_OFFSET) then
		InfMap.prop_update_chunk(ply, Vector(0, 0, 0))
	end
end)
ZCInf.Mark("spawn chunk reset")

--[[-------------------------------------------------------------------------
	Проверка: zc_infmap_status_sv
---------------------------------------------------------------------------]]
concommand.Add("zc_infmap_status_sv", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local out = {}
	local function line(s) out[#out + 1] = s end
	line("[Z-City/InfMap] версия " .. ZCInf.Version .. ", карта " .. game.GetMap() .. ", чанк " .. InfMap.chunk_size * 2)
	local parts = {}
	for k in pairs(ZCInf.Installed) do parts[#parts + 1] = k end
	table.sort(parts)
	line("  установлено: " .. table.concat(parts, ", "))
	line("  hook.Call обёрнут: " .. tostring(hook.Call == ZCInf.HookCallWrapper))
	for _, p in player.Iterator() do
		line(string.format("  %s: чанк %s%s", p:Nick(), p.CHUNK_OFFSET and InfMap.ezcoord(p.CHUNK_OFFSET) or "нет",
			IsValid(p.FakeRagdoll) and (", ragdoll в чанке " .. (p.FakeRagdoll.CHUNK_OFFSET and InfMap.ezcoord(p.FakeRagdoll.CHUNK_OFFSET) or "нет")) or ""))
	end
	local text = table.concat(out, "\n")
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text) else print(text) end
end)
