--[[-------------------------------------------------------------------------
	Gemini AI — общий код (сервер + клиент)
---------------------------------------------------------------------------]]

GeminiAI = GeminiAI or {}
GeminiAI.Version = "1.0.0"

GeminiAI.Colors = {
	Accent  = Color(130, 110, 255),
	Accent2 = Color(60, 180, 255),
	Text    = Color(235, 238, 245),
	Dim     = Color(150, 155, 175),
	Good    = Color(90, 215, 150),
	Bad     = Color(240, 95, 95),
}

-- Модели, которые бесплатны в Google AI Studio (лимиты зависят от модели).
-- *-latest всегда указывает на актуальную версию, поэтому не устаревает.
GeminiAI.Models = {
	"gemini-flash-latest",
	"gemini-flash-lite-latest",
	"gemini-2.5-flash",
	"gemini-2.5-flash-lite",
	"gemini-2.5-pro",
}

---------------------------------------------------------------------------
-- Настройки (ConVar'ы реплицируются клиентам, чтобы меню их видело)
---------------------------------------------------------------------------
local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED)

GeminiAI.CVars = {
	model       = CreateConVar("gemini_ai_model", "gemini-flash-latest", FLAGS, "Модель Gemini"),
	execute     = CreateConVar("gemini_ai_execute", "1", FLAGS, "Разрешить ИИ выполнять Lua-код (1/0)", 0, 1),
	confirm     = CreateConVar("gemini_ai_confirm", "0", FLAGS, "Спрашивать подтверждение перед выполнением кода (1/0)", 0, 1),
	public      = CreateConVar("gemini_ai_public", "1", FLAGS, "Обычные игроки могут болтать с ИИ (без выполнения кода)", 0, 1),
	broadcast   = CreateConVar("gemini_ai_broadcast", "0", FLAGS, "Показывать ответы ИИ всем в чате (1/0)", 0, 1),
	cooldown    = CreateConVar("gemini_ai_cooldown", "4", FLAGS, "Задержка между запросами игрока (сек)", 0, 120),
	history     = CreateConVar("gemini_ai_history", "12", FLAGS, "Сколько сообщений помнит ИИ", 0, 60),
	temperature = CreateConVar("gemini_ai_temperature", "0.7", FLAGS, "Креативность ответов (0.0 - 2.0)", 0, 2),

	-- ИИ-персонажи (боты, которых ведёт Gemini)
	char_model  = CreateConVar("gemini_ai_char_model", "gemini-flash-lite-latest", FLAGS, "Модель для ИИ-персонажей (lite - больше бесплатных запросов)"),
	char_idle   = CreateConVar("gemini_ai_char_idle", "20", FLAGS, "Как часто персонаж думает, когда ничего не происходит (сек)", 5, 600),
	char_gap    = CreateConVar("gemini_ai_char_gap", "4", FLAGS, "Минимальная пауза между мыслями одного персонажа (сек)", 1, 60),
	char_rpm    = CreateConVar("gemini_ai_char_rpm", "12", FLAGS, "Максимум запросов в минуту на всех персонажей (лимит бесплатного ключа)", 1, 300),
	char_hear   = CreateConVar("gemini_ai_char_hear", "900", FLAGS, "Дальность слуха персонажа (юниты)", 100, 5000),
	char_debug  = CreateConVar("gemini_ai_char_debug", "0", FLAGS, "Показывать админам мысли и действия персонажей в чате", 0, 1),
}

-- Параметры, которые админ может менять из игры (gemini_ai_set / меню)
GeminiAI.Settable = {
	model = "string", execute = "bool", confirm = "bool", public = "bool",
	broadcast = "bool", cooldown = "number", history = "number", temperature = "number",
	char_model = "string", char_idle = "number", char_gap = "number", char_rpm = "number", char_hear = "number", char_debug = "bool",
}

---------------------------------------------------------------------------
-- Права доступа. Совместимо с ULX / SAM / ServerGuard / любым CAMI-модом.
-- Без админ-мода используются стандартные IsAdmin/IsSuperAdmin.
---------------------------------------------------------------------------
GeminiAI.Privileges = {
	Chat    = { Name = "GeminiAI.Chat",    MinAccess = "user",       Description = "Gemini AI: общаться с ИИ" },
	Execute = { Name = "GeminiAI.Execute", MinAccess = "superadmin", Description = "Gemini AI: ИИ выполняет Lua-код по вашим просьбам" },
	Admin   = { Name = "GeminiAI.Admin",   MinAccess = "superadmin", Description = "Gemini AI: настройка мода, ключ API, бан игроков" },
	Characters = { Name = "GeminiAI.Characters", MinAccess = "admin", Description = "Gemini AI: создавать ИИ-персонажей и давать им приказы" },
}

local function RegisterPrivileges()
	if not CAMI or not CAMI.RegisterPrivilege then return end
	for _, priv in pairs(GeminiAI.Privileges) do
		CAMI.RegisterPrivilege(priv)
	end
end
RegisterPrivileges()
hook.Add("PostGamemodeLoaded", "GeminiAI_CAMI", RegisterPrivileges)

function GeminiAI.HasAccess(ply, key)
	if not IsValid(ply) then return true end -- консоль сервера может всё

	local priv = GeminiAI.Privileges[key]
	if not priv then return false end

	if CAMI and CAMI.PlayerHasAccess then
		local result
		CAMI.PlayerHasAccess(ply, priv.Name, function(allowed) result = allowed end)
		if result ~= nil then return result end
	end

	if priv.MinAccess == "superadmin" then return ply:IsSuperAdmin() end
	if priv.MinAccess == "admin" then return ply:IsAdmin() end
	return true
end

cleanup.Register("gemini_ai")

if CLIENT then
	language.Add("Cleanup_gemini_ai", "Объекты Gemini AI")
	language.Add("Cleaned_gemini_ai", "Объекты Gemini AI удалены")
	language.Add("Undone_gemini_ai", "Отменено действие Gemini AI")
	language.Add("gemini_ai_terminal", "ИИ Терминал")
end
