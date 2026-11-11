-- Что игрок скачивает, заходя на сервер: карта, на которой идёт игра, аддоны Мастерской сервера и Lua.
-- Lua (cl_/sh_ файлы) отдаётся всегда целиком - загрузчик (autorun/loader.lua) зовёт AddCSLuaFile для каждого файла.
--   1) аддоны из Мастерской, которые стоят на сервере (engine.GetAddons): их игрок скачивает сам из Steam.
--      Аддоны-карты - только тот, где лежит текущая карта (остальные карты не качаются). Карту не из Мастерской
--      движок отдаёт сам;
--   2) дополнительные ID Мастерской вручную: rem_workshop_extra "id1,id2,..." (например, этот аддон, если он лежит
--      на сервере папкой, а у игроков должен скачаться из Мастерской);
--   3) отдельные файлы (текстуры/звуки/модели по одному) - выключены (autorun/!!rem_download_gate.lua);
--      включить: rem_download_loose 1 - тогда и файлы этого аддона по списку lua/rem_downloads/list.lua
--      (tools/downloads/make.py) + папки materials/rem_* и sound/rem_*.
-- Выключить пункт 1: rem_download_workshop 0 (после смены карты).
local cvWorkshop = CreateConVar("rem_download_workshop", 1, FCVAR_ARCHIVE, "Players download the server's Workshop addons on join", 0, 1)
local cvExtra = CreateConVar("rem_workshop_extra", "", FCVAR_ARCHIVE, "Extra Workshop IDs for players to download, comma separated")

local DL = REM_Downloads or {}
local AddSingle = DL.AddSingleFile or resource.AddSingleFile

local SKIP = {rem_wd_private = true} -- личный видеофон меню: только у себя
local added = {}
local count = 0

local function Add(path)
	local key = string.lower(path) -- регистр самого пути не трогаем: на Linux-сервере он важен
	if added[key] or key:find("rem_wd_private", 1, true) then return end
	added[key] = true
	AddSingle(path)
	count = count + 1
end

local CONTENT_EXT = {vmt = true, vtf = true, png = true, jpg = true, mdl = true, vvd = true, vtx = true, phy = true,
	ani = true, wav = true, mp3 = true, ogg = true, ttf = true, otf = true, pcf = true}

local function Walk(dir)
	local files, dirs = file.Find(dir .. "/*", "GAME")
	for _, f in ipairs(files or {}) do
		if CONTENT_EXT[string.GetExtensionFromFilename(f) or ""] then Add(dir .. "/" .. f) end
	end
	for _, d in ipairs(dirs or {}) do
		if not SKIP[d] then Walk(dir .. "/" .. d) end
	end
end

local function AddContent()
	local ok, list = pcall(include, "rem_downloads/list.lua")
	if ok and istable(list) then
		for _, path in ipairs(list) do Add(path) end
	end
	for _, root in ipairs({"materials", "sound"}) do
		local _, dirs = file.Find(root .. "/rem_*", "GAME")
		for _, d in ipairs(dirs or {}) do
			if not SKIP[d] then Walk(root .. "/" .. d) end
		end
	end
	print("[rem_downloads] content files for players: " .. count)
end

-- аддон-карта: помечен в Мастерской как map или в нём лежат .bsp
local function IsMapAddon(a)
	if string.find(string.lower(a.tags or ""), "map", 1, true) then return true end
	local maps = file.Find("maps/*.bsp", a.title or "")
	return maps and #maps > 0
end

local function HasCurrentMap(a)
	return file.Exists("maps/" .. game.GetMap() .. ".bsp", a.title or "")
end

local function AddWorkshop()
	local ids = {}
	for _, a in ipairs(engine.GetAddons()) do
		if a.mounted and a.wsid and tostring(a.wsid) ~= "0" and (not IsMapAddon(a) or HasCurrentMap(a)) then
			ids[tostring(a.wsid)] = a.title or "?"
		end
	end
	for id in string.gmatch(cvExtra:GetString(), "%d+") do ids[id] = ids[id] or "extra" end
	local n = 0
	for id in pairs(ids) do
		resource.AddWorkshop(id)
		n = n + 1
	end
	print("[rem_downloads] Workshop addons for players: " .. n)
end

if DL.Loose then AddContent() end
if cvWorkshop:GetBool() then AddWorkshop() end
