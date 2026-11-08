-- Что игрок скачивает, заходя на сервер.
-- Lua (cl_/sh_ файлы) отдаётся и так - загрузчик (autorun/loader.lua) зовёт AddCSLuaFile для каждого файла.
-- Здесь - контент:
--   1) все текстуры/звуки/модели/шрифты этого аддона: список lua/rem_downloads/list.lua (tools/downloads/make.py)
--      + обход папок materials/rem_* и sound/rem_* (новое в них - само; туда же попадает sound/rem_panic не из git);
--   2) аддоны из Мастерской, которые стоят на сервере (engine.GetAddons): их игрок скачивает сам из Steam -
--      так приезжают MGSV, ULTRAKILL и прочие, если на сервер они поставлены через Мастерскую (коллекция);
--   3) дополнительные ID Мастерской вручную: rem_workshop_extra "id1,id2,..." (например, если аддон на сервере лежит
--      папкой, а у игроков должен скачаться из Мастерской).
-- Без sv_downloadurl (FastDL) файлы аддона качаются прямо с сервера - медленно; лучше залить аддон в Мастерскую
-- или поднять FastDL. Выключить пункт 1: rem_download_content 0, пункт 2: rem_download_workshop 0 (после смены карты).
local cvContent = CreateConVar("rem_download_content", 1, FCVAR_ARCHIVE, "Players download this addon's materials/sounds/models on join", 0, 1)
local cvWorkshop = CreateConVar("rem_download_workshop", 1, FCVAR_ARCHIVE, "Players download the server's Workshop addons on join", 0, 1)
local cvExtra = CreateConVar("rem_workshop_extra", "", FCVAR_ARCHIVE, "Extra Workshop IDs for players to download, comma separated")

local SKIP = {rem_wd_private = true} -- личный видеофон меню: только у себя
local added = {}
local count = 0

local function Add(path)
	local key = string.lower(path) -- регистр самого пути не трогаем: на Linux-сервере он важен
	if added[key] or key:find("rem_wd_private", 1, true) then return end
	added[key] = true
	resource.AddSingleFile(path)
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

local function AddWorkshop()
	local ids = {}
	for _, a in ipairs(engine.GetAddons()) do
		if a.mounted and a.wsid and tostring(a.wsid) ~= "0" then ids[tostring(a.wsid)] = a.title or "?" end
	end
	for id in string.gmatch(cvExtra:GetString(), "%d+") do ids[id] = ids[id] or "extra" end
	local n = 0
	for id in pairs(ids) do
		resource.AddWorkshop(id)
		n = n + 1
	end
	print("[rem_downloads] Workshop addons for players: " .. n)
end

if cvContent:GetBool() then AddContent() end
if cvWorkshop:GetBool() then AddWorkshop() end
