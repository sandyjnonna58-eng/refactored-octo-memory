--[[-------------------------------------------------------------------------
	Gemini AI для Garry's Mod
	ИИ-помощник на бесплатном API Google Gemini, который может управлять
	сервером, выполняя сгенерированный GLua-код.
---------------------------------------------------------------------------]]

if SERVER then
	AddCSLuaFile("gemini_ai/sh_shared.lua")
	AddCSLuaFile("gemini_ai/cl_chat.lua")
	AddCSLuaFile("gemini_ai/cl_settings.lua")

	include("gemini_ai/sh_shared.lua")
	include("gemini_ai/sv_core.lua")
	include("gemini_ai/sv_commands.lua")
	include("gemini_ai/sv_compat_remorse.lua")

	-- AddSingleFile, а не AddFile: в рекосе AddFile глушит !!rem_download_gate.lua
	resource.AddSingleFile("materials/entities/gemini_ai_terminal.png")
else
	include("gemini_ai/sh_shared.lua")
	include("gemini_ai/cl_chat.lua")
	include("gemini_ai/cl_settings.lua")
end

MsgC(Color(130, 120, 255), "[Gemini AI] ", Color(230, 230, 230), "Загружен, версия " .. GeminiAI.Version .. "\n")
