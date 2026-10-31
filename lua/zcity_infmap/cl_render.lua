-- Клиент: отрисовка игроков и ragdoll'ов из других чанков.

local ZCInf = ZCInf

--[[-------------------------------------------------------------------------
	RenderOverride.
	InfMap рисует сущности из чужих чанков через свою обёртку RenderOverride
	(со сдвигом камеры). Z-City ставит свои RenderOverride игрокам и ragdoll'ам
	в любой момент (спавн, фейк, смерть) и затирает обёртку InfMap - тогда
	ragdoll/игрок из соседнего чанка рисуется "призраком" в нашем чанке.
	Следим за такими сущностями и заново оборачиваем новый RenderOverride.
---------------------------------------------------------------------------]]
--
-- Кроме того, обёртка InfMap вызывает старый RenderOverride без аргумента flags,
-- а hg.renderOverride Z-City делает bit.band(flags, STUDIO_RENDER) - ошибка каждый
-- кадр, и игрок/ragdoll из соседнего чанка не рисуется. Ставим свою обёртку,
-- которая передаёт flags (в остальном такая же, как у InfMap).
local tracked = setmetatable({}, {__mode = "k"})

local origUpdate = InfMap.ZCInf_prop_update_chunk or InfMap.prop_update_chunk
InfMap.ZCInf_prop_update_chunk = origUpdate

local cam_Start3D, cam_End3D, EyePos = cam.Start3D, cam.End3D, EyePos

-- Пока рисуется сущность из чанка C, камера сдвинута в координаты чанка C.
-- Код отрисовки Z-City (одежда, броня, оружие на ragdoll'е) берёт GetPos /
-- GetBonePosition и т.п., а InfMap отдаёт их относительно НАШЕГО чанка -
-- вещи уехали бы на величину сдвига. На время отрисовки сущности этого чанка
-- отдают сырые координаты, в которых и работает сдвинутая камера.
local EntityMT = FindMetaTable("Entity")
local renderChunk = nil

for _, name in ipairs({"GetPos", "LocalToWorld", "WorldSpaceCenter", "WorldSpaceAABB", "GetBonePosition"}) do
	local raw = EntityMT["InfMap_" .. name]
	if raw then
		ZCInf.Detour(EntityMT, name, function(orig)
			return function(self, ...)
				if renderChunk ~= nil and self.CHUNK_OFFSET == renderChunk then return raw(self, ...) end
				return orig(self, ...)
			end
		end)
	end
end

local function drawShifted(self, flags, chunk, visual_offset)
	local prev = renderChunk
	cam_Start3D(EyePos() - visual_offset)
	renderChunk = chunk
	local ok, err = pcall(self.OldRenderOverride, self, flags or STUDIO_RENDER)
	renderChunk = prev
	cam_End3D()
	if not ok then error(err, 0) end
end

function InfMap.prop_update_chunk(ent, chunk)
	origUpdate(ent, chunk)
	if not IsValid(ent) then return end

	local lp = LocalPlayer()
	if ent.ValidRenderOverride == nil or ent == lp or not IsValid(lp) or not lp.CHUNK_OFFSET or not chunk then
		tracked[ent] = nil
		return
	end

	-- у InfMap для близких чанков (и всегда для игроков) - отрисовка со сдвигом камеры,
	-- для дальних - коробка вместо модели; трогаем только первый случай
	local rel = chunk - lp.CHUNK_OFFSET
	if ent.ValidRenderOverride == true and isfunction(ent.OldRenderOverride) and (ent:IsPlayer() or rel:LengthSqr() <= 100) then
		local visual_offset = rel * InfMap.chunk_size * 2
		local c = chunk
		ent.RenderOverride = function(self, flags)
			drawShifted(self, flags, c, visual_offset)
		end
	end

	tracked[ent] = ent.RenderOverride or false
end

timer.Create("ZCInf_RenderOverride", 0.2, 0, function()
	for ent, ro in pairs(tracked) do
		if not IsValid(ent) then
			tracked[ent] = nil
		elseif ent.ValidRenderOverride == nil then
			tracked[ent] = nil
		elseif (ent.RenderOverride or false) ~= ro then
			-- RenderOverride заменили поверх обёртки InfMap
			ent.ValidRenderOverride = nil
			ent.OldRenderOverride = nil
			InfMap.prop_update_chunk(ent, ent.CHUNK_OFFSET)
		end
	end
end)
ZCInf.Mark("RenderOverride rewrap")

--[[-------------------------------------------------------------------------
	Принудительная отрисовка игроков.
	InfMap каждый кадр вызывает DrawModel у ВСЕХ живых игроков, потому что
	игроки из других чанков иначе не рисуются. Но игроков из нашего чанка движок
	и так рисует, а у Z-City отрисовка игрока тяжёлая (одежда, броня, ragdoll):
	получалось по два раза за кадр, плюс своё тело перед камерой.
	Рисуем принудительно только игроков из чужих чанков.
---------------------------------------------------------------------------]]
local debug_enabled = GetConVar("infmap_debug")
local black = Color(0, 0, 0, 0)
local red = Color(255, 0, 0, 255)
local blue = Color(0, 0, 255, 255)

hook.Add("PostDrawOpaqueRenderables", "infinite_player_render", function()
	local lp = LocalPlayer()
	local chunk_offset = lp.CHUNK_OFFSET
	if not chunk_offset then return end

	for _, v in player.Iterator() do
		if v ~= lp and v:Alive() then
			local vc = v.CHUNK_OFFSET
			if vc ~= nil and vc ~= chunk_offset then
				v:RemoveEffects(EF_DIMLIGHT) -- фонарик из чужого чанка светил бы у нас
				v:DrawModel()
			end
		end
	end

	-- отладочные линии InfMap (infmap_debug 1), как в оригинале
	if not (debug_enabled and debug_enabled:GetBool()) then return end
	local cs = Vector(1, 1, 1) * InfMap.chunk_size
	local co = chunk_offset * InfMap.chunk_size * 2
	local maxsize = InfMap.source_bounds
	render.DrawWireframeSphere(Vector(), 10, 10, 10, red, true)
	render.DrawWireframeBox(Vector(), Angle(), -cs, cs, black, true)
	render.DrawWireframeBox(Vector(), Angle(), -cs - co, cs - co, black, true)
	render.DrawWireframeBox(Vector(), Angle(), -maxsize - co, maxsize - co, blue, true)
end)
ZCInf.Mark("player render")

--[[-------------------------------------------------------------------------
	Проверка: zc_infmap_status
---------------------------------------------------------------------------]]
concommand.Add("zc_infmap_status", function()
	local parts = {}
	for k in pairs(ZCInf.Installed) do parts[#parts + 1] = k end
	table.sort(parts)
	local c = ZCInf.LPChunk()
	print("[Z-City/InfMap] версия " .. ZCInf.Version .. ", карта " .. game.GetMap())
	print("  установлено: " .. table.concat(parts, ", "))
	print("  hook.Call обёрнут: " .. tostring(hook.Call == ZCInf.HookCallWrapper))
	print("  мой чанк: " .. (c and InfMap.ezcoord(c) or "нет"))
	local n = 0
	for _ in pairs(tracked) do n = n + 1 end
	print("  сущностей из чужих чанков с обёрткой отрисовки: " .. n)
end)
