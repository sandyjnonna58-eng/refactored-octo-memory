-- Позиции в сетевых сообщениях Z-City.
--
-- Две проблемы:
--   1) net.WriteVector не умеет передавать координаты больше ±16384 (граница мира Source),
--      а мировые координаты InfMap выходят за неё уже в соседнем чанке;
--   2) клиент рисует всё относительно своего чанка, а сервер шлёт мировые координаты.
--
-- Для сообщений из списка ниже позиции передаются тремя float'ами (без обрезки),
-- а на приёме переводятся в нужную систему координат:
--   сервер -> клиент: мировые -> относительно чанка LocalPlayer'а;
--   клиент -> сервер: относительно чанка игрока -> мировые.
--
-- Списки общие для сервера и клиента, поэтому формат на обеих сторонах совпадает.
-- Номер = порядковый номер вызова net.Write/ReadVector в сообщении.
--   true  - это позиция, перевести координаты;
--   "raw" - передать без обрезки, но не переводить (позиция считается вместе
--           с матрицей кости, которая тоже мировая).
--   ALL   - все векторы в сообщении - позиции.

local ZCInf = ZCInf
local ALL = "all"

local function spec(...)
	local t = {}
	for _, i in ipairs({...}) do t[i] = true end
	return t
end

-- сервер -> клиент
ZCInf.NetToClient = {
	["hg_fullbody_bloodmist"] = spec(1),
	["hg_bloodimpact"] = spec(1),
	["hg_skullfracture"] = spec(1),
	["bloodsquirt"] = {[1] = "raw"},
	["bloodsquirt2"] = {[1] = "raw"},
	["bruise_decal"] = spec(1),
	["hg_booom"] = spec(1),
	["projectilefarsound"] = spec(1),
	["rpg_explosion_sound"] = spec(1),
	["flashbang"] = spec(1),
	["addflash"] = spec(1),
	["add_supression"] = spec(1),
	["gas particle"] = spec(1),
	["util.screenshake"] = spec(1),
	["rem_fx_kick"] = spec(1),
	["rem_control_locate"] = ALL,
	["hg_melee_block_fx"] = spec(1),
	["hg_gollavo_headshot"] = spec(1),
	["hg_extinguisher_explode_fx"] = spec(1),
	["callbomber_carpet_ready"] = spec(1),
	["callbomber_b2_start"] = spec(1, 2),
	["zb_extractionpoint"] = spec(1),
	["zb_traitorextractionpoint"] = spec(1),
	["hmcd_professions_abilities_addfootstep"] = spec(1),
	["dm_start"] = spec(1),
	["supfight_start"] = spec(1),
	-- Glide: в glide.command векторы пишет только CMD_CREATE_EXPLOSION (позиция, нормаль)
	["glide.command"] = spec(1),
}

-- клиент -> сервер (клиент шлёт свои координаты, они и так в пределах мира)
ZCInf.NetToServer = {
	["deatheffect_updatecam"] = spec(1),
	["rem_uav_mark_request"] = spec(1),
	["callbomber_carpet_begin"] = spec(1),
	["callbomber_carpet_confirm"] = spec(1),
}

local OUT = SERVER and ZCInf.NetToClient or nil         -- что мы шлём в "float"-формате
local IN = SERVER and ZCInf.NetToServer or ZCInf.NetToClient -- что мы принимаем

local function wants(set, n)
	if set == ALL then return true end
	return set[n]
end

--[[ Запись (только сервер) ]]
if SERVER then
	local w_set, w_n = nil, 0
	local WriteFloat = net.WriteFloat

	ZCInf.Detour(net, "Start", function(orig)
		return function(name, unreliable)
			w_set = OUT[string.lower(name)]
			w_n = 0
			return orig(name, unreliable)
		end
	end)

	ZCInf.Detour(net, "WriteVector", function(orig)
		return function(v)
			local set = w_set
			if set ~= nil then
				w_n = w_n + 1
				if wants(set, w_n) then
					WriteFloat(v[1])
					WriteFloat(v[2])
					WriteFloat(v[3])
					return
				end
			end
			return orig(v)
		end
	end)
end

--[[ Чтение ]]
local r_set, r_n, r_ply = nil, 0, nil
local ReadFloat = net.ReadFloat

local convert
if SERVER then
	convert = function(v)
		if IsValid(r_ply) then return ZCInf.ToWorld(v, r_ply.CHUNK_OFFSET) end
		return v
	end
else
	convert = function(v)
		return ZCInf.WorldToClient(v)
	end
end

ZCInf.Detour(net, "ReadVector", function(orig)
	return function()
		local set = r_set
		if set == nil then return orig() end

		r_n = r_n + 1
		local mode = wants(set, r_n)
		if not mode then return orig() end

		if CLIENT then
			-- сервер записал эту позицию тремя float'ами
			local v = Vector(ReadFloat(), ReadFloat(), ReadFloat())
			if mode == "raw" then return v end
			return convert(v)
		end

		return convert(orig())
	end
end)

local wrapped = setmetatable({}, {__mode = "k"})

local function wrapReceiver(name)
	local set = IN[name]
	if set == nil then return end

	local fn = net.Receivers[name]
	if fn == nil or wrapped[fn] then return end

	local function receiver(len, ply)
		local ps, pn, pp = r_set, r_n, r_ply
		r_set, r_n, r_ply = set, 0, ply
		local ok, err = pcall(fn, len, ply)
		r_set, r_n, r_ply = ps, pn, pp
		if not ok then ErrorNoHalt(tostring(err) .. "\n") end
	end

	wrapped[receiver] = true
	net.Receivers[name] = receiver
end

local function wrapAll()
	for name in pairs(IN) do wrapReceiver(name) end
end

ZCInf.Detour(net, "Receive", function(orig)
	return function(name, fn)
		orig(name, fn)
		wrapReceiver(string.lower(name))
	end
end)

wrapAll()
hook.Add("Initialize", "ZCInf_Net", wrapAll)
hook.Add("InitPostEntity", "ZCInf_Net", wrapAll)
timer.Create("ZCInf_NetWatch", 10, 0, wrapAll)

ZCInf.Mark("net positions")
