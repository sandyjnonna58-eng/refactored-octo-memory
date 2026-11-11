-- Что игрок качает при входе: только карта, на которой идёт игра, аддоны Мастерской сервера и Lua.
-- Отдельные файлы (resource.AddFile / AddSingleFile - звуки, текстуры, модели по одному с сервера или FastDL)
-- выключены для всех аддонов: имя файла начинается с "!!", чтобы он грузился раньше остальных autorun.
-- Карта не из Мастерской движок отдаёт сам (это не resource.*), карты из Мастерской и аддоны - rem_downloads.lua.
-- Lua игроки получают всегда целиком: AddCSLuaFile этим не затрагивается.
-- Вернуть раздачу отдельных файлов: rem_download_loose 1 (после смены карты).
if not SERVER then return end

local cv = CreateConVar("rem_download_loose", 0, FCVAR_ARCHIVE, "1 - players also download loose addon files (sounds/materials/models) on join", 0, 1)

REM_Downloads = REM_Downloads or {}
-- настоящие функции движка - для rem_downloads.lua, если раздачу включат
REM_Downloads.AddFile = REM_Downloads.AddFile or resource.AddFile
REM_Downloads.AddSingleFile = REM_Downloads.AddSingleFile or resource.AddSingleFile
REM_Downloads.Loose = cv:GetBool()

if REM_Downloads.Loose then return end

local blocked = 0
resource.AddFile = function() blocked = blocked + 1 end
resource.AddSingleFile = function() blocked = blocked + 1 end

hook.Add("Initialize", "rem_download_gate", function()
	print("[rem_downloads] loose files skipped (rem_download_loose 0): " .. blocked)
end)
