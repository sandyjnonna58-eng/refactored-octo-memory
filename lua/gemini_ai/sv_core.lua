--[[-------------------------------------------------------------------------
	Gemini AI — сервер: запросы к Google Gemini и выполнение кода
---------------------------------------------------------------------------]]

util.AddNetworkString("GeminiAI_Ask")       -- клиент -> сервер: сообщение
util.AddNetworkString("GeminiAI_Reply")     -- сервер -> клиент: ответ ИИ
util.AddNetworkString("GeminiAI_Status")    -- сервер -> клиент: ИИ думает / не думает
util.AddNetworkString("GeminiAI_Open")      -- сервер -> клиент: открыть чат
util.AddNetworkString("GeminiAI_Run")       -- клиент -> сервер: выполнить код из ответа
util.AddNetworkString("GeminiAI_RunResult") -- сервер -> клиент: результат выполнения
util.AddNetworkString("GeminiAI_Notify")    -- сервер -> клиент: сообщение в чат
util.AddNetworkString("GeminiAI_Reset")     -- клиент -> сервер: очистить память
util.AddNetworkString("GeminiAI_AdminSet")  -- клиент -> сервер: изменить настройку
util.AddNetworkString("GeminiAI_KeyState")  -- сервер -> клиент: задан ли ключ

local API_URL = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
local CFG_DIR, CFG_FILE = "gemini_ai", "gemini_ai/config.json"

-- Ключ хранится в локальной переменной, а не в глобальной таблице,
-- чтобы сгенерированный ИИ код не мог его случайно прочитать.
local API_KEY = ""

GeminiAI.Config  = GeminiAI.Config or { blocked = {} }
GeminiAI.History = GeminiAI.History or {}  -- [sid] = { {role, text}, ... }
GeminiAI.Busy    = GeminiAI.Busy or {}     -- [sid] = true, пока ждём ответ
GeminiAI.LastAsk = GeminiAI.LastAsk or {}  -- [sid] = CurTime()
GeminiAI.Codes   = GeminiAI.Codes or {}    -- [sid] = { [id] = code }
GeminiAI.Tracked = GeminiAI.Tracked or { timers = {}, hooks = {} }
GeminiAI.Terminals = GeminiAI.Terminals or {} -- [sid] = терминал, через который говорит игрок
GeminiAI.NextID  = GeminiAI.NextID or 0

-- Точки расширения для модулей совместимости (например, sv_compat_remorse.lua):
GeminiAI.PromptExtras     = GeminiAI.PromptExtras or {}     -- [имя] = строка или function() -> строка
GeminiAI.ContextProviders = GeminiAI.ContextProviders or {} -- [имя] = function(ply, add)
GeminiAI.EnvExtenders     = GeminiAI.EnvExtenders or {}     -- [имя] = function(AI, ply, env)

local cv = GeminiAI.CVars

---------------------------------------------------------------------------
-- Конфиг (ключ API и список заблокированных игроков)
---------------------------------------------------------------------------
function GeminiAI.LoadConfig()
	local raw = file.Read(CFG_FILE, "DATA")
	local data = raw and util.JSONToTable(raw) or {}
	API_KEY = isstring(data.key) and data.key or ""
	GeminiAI.Config.blocked = istable(data.blocked) and data.blocked or {}
end

function GeminiAI.SaveConfig()
	file.CreateDir(CFG_DIR)
	file.Write(CFG_FILE, util.TableToJSON({ key = API_KEY, blocked = GeminiAI.Config.blocked }, true))
end

function GeminiAI.SetKey(key)
	API_KEY = string.Trim(key or "")
	GeminiAI.SaveConfig()
	GeminiAI.SendKeyState()
end

function GeminiAI.HasKey() return API_KEY ~= "" end

function GeminiAI.SendKeyState(ply)
	net.Start("GeminiAI_KeyState")
		net.WriteBool(GeminiAI.HasKey())
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

GeminiAI.LoadConfig()
hook.Add("PlayerInitialSpawn", "GeminiAI_KeyState", function(ply)
	timer.Simple(3, function() if IsValid(ply) then GeminiAI.SendKeyState(ply) end end)
end)

-- Убираем ключ из любого текста, который уходит игрокам
local function Sanitize(text)
	text = tostring(text or "")
	if API_KEY ~= "" then text = string.Replace(text, API_KEY, "***") end
	return text
end

local function SID(ply) return IsValid(ply) and ply:SteamID64() or "console" end

---------------------------------------------------------------------------
-- Сообщения игрокам
---------------------------------------------------------------------------
function GeminiAI.Notify(ply, text, isError)
	text = Sanitize(text)
	if ply ~= nil and not IsValid(ply) then
		MsgC(GeminiAI.Colors.Accent, "[Gemini AI] ", isError and GeminiAI.Colors.Bad or color_white, text .. "\n")
		return
	end
	net.Start("GeminiAI_Notify")
		net.WriteString(text)
		net.WriteBool(isError and true or false)
	if ply then net.Send(ply) else net.Broadcast() end
end

local function SetThinking(ply, state)
	local term = GeminiAI.Terminals[SID(ply)]
	if IsValid(term) then term:SetThinking(state) end
	if not IsValid(ply) then return end
	net.Start("GeminiAI_Status")
		net.WriteBool(state)
	net.Send(ply)
end

---------------------------------------------------------------------------
-- Системная инструкция для ИИ
---------------------------------------------------------------------------
local SYSTEM_PROMPT = [[
Ты — «Gemini AI», ИИ-помощник внутри игры Garry's Mod. Ты находишься на игровом сервере и можешь делать в игре практически что угодно: твой GLua-код сразу выполняется на СЕРВЕРЕ.

ФОРМАТ ОТВЕТА — строго JSON-объект: {"say": "...", "lua": "..."}
• say — короткий живой ответ игроку на его языке (1-3 предложения). Не вставляй код в say.
• lua — серверный GLua-код, который выполнит просьбу. Если действие в игре не нужно (просто разговор) — пустая строка "".

ПЕРЕМЕННЫЕ, ДОСТУПНЫЕ В КОДЕ:
• ME — игрок, который с тобой говорит (Player; может быть NULL, если пишет консоль сервера).
• TR — трасса взгляда игрока: TR.HitPos, TR.HitNormal, TR.Entity.
• AI — помощники:
  AI.Spawn(class, pos, model, ang) -> Entity  создать любой энтити/NPC/проп (попадает в Undo игрока). model/ang необязательны.
  AI.Prop(model, pos, ang) -> Entity           проп; pos по умолчанию — точка взгляда.
  AI.NPC(class, pos, weapon) -> Entity          NPC с оружием, например AI.NPC("npc_combine_s", nil, "weapon_ar2").
  AI.Aim(up) -> Vector                          точка взгляда игрока, поднятая на up юнитов.
  AI.Find(name) -> Player|nil                   найти игрока по части ника.
  AI.Say(text)                                  написать игроку в чат.  AI.All(text) — написать всем.
  AI.Timer(sec, fn)                             отложить действие.
  print(...)                                    вывод попадёт в отчёт о выполнении.
• Все стандартные библиотеки GMod: ents, player, game, timer, hook, util, math, physenv, engine, RunConsoleCommand и т.д.

ПРАВИЛА:
1. Пиши рабочий, короткий код. Всегда проверяй IsValid. Не используй бесконечные циклы и while true.
2. Позиции бери от TR.HitPos или ME:GetPos(); несколько объектов раскладывай со смещением, чтобы они не застревали.
3. Для повторяющихся действий используй timer.Create с именем, начинающимся на "GeminiAI_", и всегда ограничивай число повторов. Хуки называй "GeminiAI_...".
4. Модели бери только из стандартного контента HL2/GMod (models/props_c17/..., models/props_junk/... и т.п.).
5. Никогда не читай и не изменяй data/gemini_ai, не раскрывай API-ключ, не кикай/не баны админов, если об этом не просит игрок с правами.
6. Если просьба неясна или опасна для сервера (краш, удаление файлов) — не пиши код и объясни в say.
7. Цвета задавай через Color(r,g,b). Для вывода сообщений используй AI.Say, а не ME:ChatPrint.

ПРИМЕР: просьба «поставь передо мной 3 бочки» ->
{"say":"Готово, три бочки перед тобой!","lua":"for i = 1, 3 do\n  AI.Prop(\"models/props_c17/oildrum001.mdl\", AI.Aim(10) + Vector(0, (i - 2) * 40, 0))\nend"}
]]

-- Каталог того, что есть на сервере: ИИ берёт отсюда точные классы оружия и энтити
local catalog
local function BuildCatalog()
	if catalog then return catalog end
	local function collect(list, getClass, max)
		local out = {}
		for _, t in pairs(list) do
			local class, spawnable = getClass(t)
			if isstring(class) and spawnable then out[#out + 1] = class end
		end
		table.sort(out)
		if #out > max then
			local extra = #out - max
			for i = #out, max + 1, -1 do out[i] = nil end
			out[#out + 1] = "...и ещё " .. extra
		end
		return table.concat(out, ", ")
	end
	local npcs = {}
	for class in pairs(list.Get("NPC")) do npcs[#npcs + 1] = class end
	table.sort(npcs)
	catalog = "\n\nКАТАЛОГ СЕРВЕРА (используй точные классы отсюда):\n" ..
		"Оружие: " .. collect(weapons.GetList(), function(t) return t.ClassName, t.Spawnable end, 350) .. "\n" ..
		"Энтити: " .. collect(scripted_ents.GetList(), function(t) return t.t and t.t.ClassName, t.t and t.t.Spawnable end, 200) .. "\n" ..
		"NPC: " .. table.concat(npcs, ", ", 1, math.min(#npcs, 120))
	return catalog
end
hook.Add("InitPostEntity", "GeminiAI_Catalog", function() catalog = nil end)

local function GetSystemPrompt()
	local parts = { SYSTEM_PROMPT }
	for _, extra in SortedPairs(GeminiAI.PromptExtras) do
		local text = isfunction(extra) and extra() or extra
		if isstring(text) then parts[#parts + 1] = text end
	end
	local ok, cat = pcall(BuildCatalog)
	if ok then parts[#parts + 1] = cat end
	return table.concat(parts, "\n")
end

local function BuildContext(ply, canExec)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("[КОНТЕКСТ СЕРВЕРА]")
	add("Карта: " .. game.GetMap() .. " | Режим: " .. (engine.ActiveGamemode() or "?") .. " | Игроков: " .. player.GetCount() .. "/" .. game.MaxPlayers())

	if IsValid(ply) then
		local tr = ply:GetEyeTrace()
		add(string.format("Говорит: %s (%s), группа: %s, HP: %d, броня: %d, оружие: %s",
			ply:Nick(), ply:SteamID(), ply:GetUserGroup(), ply:Health(), ply:Armor(),
			IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() or "нет"))
		add(string.format("Позиция: Vector(%d, %d, %d), смотрит в точку Vector(%d, %d, %d), дистанция %d",
			ply:GetPos().x, ply:GetPos().y, ply:GetPos().z, tr.HitPos.x, tr.HitPos.y, tr.HitPos.z,
			ply:GetPos():Distance(tr.HitPos)))
		if IsValid(tr.Entity) then
			add("Смотрит на энтити: " .. tr.Entity:GetClass() .. " (" .. (tr.Entity:GetModel() or "?") .. ")" ..
				(tr.Entity:IsPlayer() and (" — игрок " .. tr.Entity:Nick()) or ""))
		end
	else
		add("Говорит: консоль сервера (ME = NULL, TR пустой)")
	end

	local names = {}
	for _, p in ipairs(player.GetAll()) do
		names[#names + 1] = p:Nick()
		if #names >= 24 then break end
	end
	add("Онлайн: " .. table.concat(names, ", "))

	for name, provider in SortedPairs(GeminiAI.ContextProviders) do
		local ok, err = pcall(provider, ply, add)
		if not ok then ErrorNoHalt("[Gemini AI] контекст «" .. name .. "»: " .. tostring(err) .. "\n") end
	end

	if not canExec then
		add("ВАЖНО: у этого игрока НЕТ прав на выполнение кода. Поле lua оставляй пустым, просто общайся.")
	end

	return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Запрос к Gemini
---------------------------------------------------------------------------
local function ParseResponse(code, body)
	local data = util.JSONToTable(body or "")

	if code ~= 200 then
		local msg = istable(data) and istable(data.error) and data.error.message or ("HTTP " .. tostring(code))
		if code == 429 then
			msg = "Лимит бесплатного тарифа Gemini исчерпан. Подождите минуту или смените модель (gemini_ai_set model gemini-flash-lite-latest)."
		elseif code == 400 and string.find(msg, "API key", 1, true) then
			msg = "Неверный API-ключ. Получите бесплатный ключ на aistudio.google.com и введите gemini_ai_setkey <ключ>."
		elseif code == 403 then
			msg = "Доступ запрещён (403). Проверьте ключ и что Gemini API доступен в вашем регионе. " .. msg
		elseif code == 404 then
			msg = "Модель «" .. cv.model:GetString() .. "» не найдена. Список моделей: gemini_ai_models"
		end
		return nil, msg
	end

	if not istable(data) then return nil, "Сервер Gemini вернул некорректный ответ" end

	local cand = data.candidates and data.candidates[1]
	if not cand then
		local reason = data.promptFeedback and data.promptFeedback.blockReason
		return nil, reason and ("Запрос заблокирован фильтром Gemini: " .. reason) or "Gemini не дал ответа"
	end

	local text = {}
	for _, part in ipairs(cand.content and cand.content.parts or {}) do
		if isstring(part.text) and not part.thought then text[#text + 1] = part.text end
	end
	text = table.concat(text)

	if text == "" then
		return nil, "Пустой ответ (" .. tostring(cand.finishReason or "?") .. ")"
	end

	-- Убираем возможную обёртку ```json ... ```
	local clean = string.Trim(text):gsub("^```%w*%s*", ""):gsub("%s*```$", "")
	local obj = util.JSONToTable(clean)

	if istable(obj) then
		return { say = tostring(obj.say or ""), lua = tostring(obj.lua or ""), raw = clean, data = obj }
	end
	return { say = text, lua = "", raw = util.TableToJSON({ say = text, lua = "" }), data = { say = text } }
end

-- opts (необязательно): system - своя инструкция, schema - своя схема ответа,
-- model - своя модель, temperature, maxTokens (так работают ИИ-персонажи)
function GeminiAI.Request(contents, onDone, opts)
	opts = opts or {}
	if not GeminiAI.HasKey() then
		onDone(nil, "API-ключ не задан. Админ: gemini_ai_setkey <ключ> (бесплатно на aistudio.google.com)")
		return
	end

	local body = {
		systemInstruction = { parts = { { text = opts.system or GetSystemPrompt() } } },
		contents = contents,
		generationConfig = {
			temperature = opts.temperature or cv.temperature:GetFloat(),
			maxOutputTokens = opts.maxTokens or 4096,
			responseMimeType = "application/json",
			responseSchema = opts.schema or {
				type = "OBJECT",
				properties = {
					say = { type = "STRING", description = "Ответ игроку" },
					lua = { type = "STRING", description = "Серверный GLua код или пустая строка" },
				},
				required = { "say", "lua" },
			},
		},
	}

	local ok = HTTP({
		url = string.format(API_URL, opts.model or cv.model:GetString()),
		method = "POST",
		type = "application/json",
		body = util.TableToJSON(body),
		headers = { ["x-goog-api-key"] = API_KEY },
		timeout = 60,
		success = function(code, resp)
			local res, err = ParseResponse(code, resp)
			onDone(res, err)
		end,
		failed = function(reason)
			onDone(nil, "Не удалось подключиться к Gemini: " .. tostring(reason))
		end,
	})

	if ok == false then onDone(nil, "HTTP-запрос отклонён движком (сервер ещё загружается?)") end
end

---------------------------------------------------------------------------
-- Выполнение кода
---------------------------------------------------------------------------
local executing = nil -- таблица создаваемых энтити во время выполнения

local function OwnEntity(ply, ent)
	ent.GeminiAI = true
	if not IsValid(ply) then return end
	if ent.CPPISetOwner then ent:CPPISetOwner(ply) end -- FPP / Falco's / другие защиты пропов
	ply:AddCleanup("gemini_ai", ent)
end

local function AddUndo(ply, list)
	if not IsValid(ply) or #list == 0 then return end
	undo.Create("gemini_ai")
		for _, e in ipairs(list) do undo.AddEntity(e) end
		undo.SetPlayer(ply)
		undo.SetCustomUndoText("Отменено действие Gemini AI")
	undo.Finish()
end

function GeminiAI.BuildEnv(ply, output)
	local tr = IsValid(ply) and ply:GetEyeTrace() or { HitPos = vector_origin, HitNormal = Vector(0, 0, 1), Entity = NULL }
	local AI = {}

	local function out(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		output[#output + 1] = table.concat(parts, "\t")
	end

	function AI.Aim(up) return tr.HitPos + tr.HitNormal * 4 + Vector(0, 0, up or 0) end

	function AI.Spawn(class, pos, model, ang)
		local ent = ents.Create(class)
		if not IsValid(ent) then error("Не удалось создать энтити «" .. tostring(class) .. "»", 2) end
		if model then ent:SetModel(model) end
		ent:SetPos(pos or AI.Aim(10))
		if ang then
			ent:SetAngles(ang)
		elseif IsValid(ply) then
			ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
		end
		ent:Spawn()
		ent:Activate()
		OwnEntity(ply, ent)
		if executing then
			executing[#executing + 1] = ent
		else
			AddUndo(ply, { ent }) -- создано позже, из таймера
		end
		return ent
	end

	function AI.Prop(model, pos, ang)
		local ent = AI.Spawn("prop_physics", pos, model, ang)
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then phys:Wake() end
		return ent
	end

	function AI.NPC(class, pos, weapon)
		local ent = ents.Create(class)
		if not IsValid(ent) then error("Не удалось создать NPC «" .. tostring(class) .. "»", 2) end
		ent:SetPos(pos or AI.Aim(4))
		if IsValid(ply) then ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0)) end
		if weapon then ent:SetKeyValue("additionalequipment", weapon) end
		ent:Spawn()
		ent:Activate()
		OwnEntity(ply, ent)
		if executing then executing[#executing + 1] = ent else AddUndo(ply, { ent }) end
		return ent
	end

	function AI.Find(name)
		name = string.lower(tostring(name or ""))
		for _, p in ipairs(player.GetAll()) do
			if string.find(string.lower(p:Nick()), name, 1, true) then return p end
		end
	end

	function AI.Say(text) GeminiAI.Notify(IsValid(ply) and ply or nil, tostring(text)) end
	function AI.All(text) GeminiAI.Notify(nil, tostring(text)) end
	function AI.Timer(sec, fn) timer.Simple(sec, function() local ok, e = pcall(fn) if not ok then ErrorNoHalt("[Gemini AI] " .. tostring(e) .. "\n") end end) end

	-- Отслеживаем таймеры и хуки ИИ, чтобы gemini_ai_stop мог всё остановить
	local trackedTimer = setmetatable({
		Create = function(name, ...)
			GeminiAI.Tracked.timers[name] = true
			return timer.Create(name, ...)
		end,
	}, { __index = timer })

	local trackedHook = setmetatable({
		Add = function(event, name, ...)
			GeminiAI.Tracked.hooks[#GeminiAI.Tracked.hooks + 1] = { event, name }
			return hook.Add(event, name, ...)
		end,
	}, { __index = hook })

	local env = {
		ME = ply, TR = tr, AI = AI,
		print = out, Msg = out, MsgN = out,
		timer = trackedTimer, hook = trackedHook,
	}

	for name, extend in SortedPairs(GeminiAI.EnvExtenders) do
		local ok, err = pcall(extend, AI, ply, env)
		if not ok then ErrorNoHalt("[Gemini AI] окружение «" .. name .. "»: " .. tostring(err) .. "\n") end
	end

	return setmetatable(env, { __index = _G })
end

function GeminiAI.Execute(ply, code)
	code = tostring(code or "")
	if string.Trim(code) == "" then return true, "Нет кода" end

	local fn = CompileString(code, "GeminiAI", false)
	if isstring(fn) then return false, "Ошибка компиляции: " .. fn end

	local output = {}
	setfenv(fn, GeminiAI.BuildEnv(ply, output))

	-- Ловим и сырые ents.Create, чтобы всё созданное попало в Undo
	local created = {}
	executing = created
	local seen = {}
	hook.Add("OnEntityCreated", "GeminiAI_Track", function(ent) created[#created + 1] = ent end)

	-- Защита от бесконечных циклов: без JIT счётчик инструкций срабатывает надёжно
	if jit and jit.off then pcall(jit.off, fn, true) end
	local oldHook, oldMask, oldCount = debug.gethook()
	debug.sethook(function() error("Код выполнялся слишком долго и был остановлен", 2) end, "", 50000000)

	local ok, err = xpcall(fn, function(e) return tostring(e) end)

	debug.sethook(oldHook, oldMask or "", oldCount or 0)
	hook.Remove("OnEntityCreated", "GeminiAI_Track")
	executing = nil

	local undoList = {}
	for _, ent in ipairs(created) do
		if IsValid(ent) and not seen[ent] and not ent:IsPlayer() and not IsValid(ent:GetParent())
			and not (ent:IsWeapon() and IsValid(ent:GetOwner())) and ent:GetClass() ~= "physgun_beam" then
			seen[ent] = true
			if not ent.GeminiAI then OwnEntity(ply, ent) end
			undoList[#undoList + 1] = ent
		end
	end
	AddUndo(ply, undoList)

	local report = table.concat(output, "\n")
	if not ok then
		return false, "Ошибка: " .. err .. (report ~= "" and ("\n" .. report) or "")
	end

	local summary = "Выполнено"
	if #undoList > 0 then summary = summary .. " • создано объектов: " .. #undoList .. " (Z — отменить)" end
	if report ~= "" then summary = summary .. "\n" .. report end
	return true, summary
end

-- Остановить всё, что запустил ИИ
function GeminiAI.StopAll(removeEnts)
	local t, h, e = 0, 0, 0
	for name in pairs(GeminiAI.Tracked.timers) do
		if timer.Exists(name) then timer.Remove(name) t = t + 1 end
	end
	for _, data in ipairs(GeminiAI.Tracked.hooks) do
		hook.Remove(data[1], data[2]) h = h + 1
	end
	GeminiAI.Tracked = { timers = {}, hooks = {} }

	if removeEnts then
		for _, ent in ipairs(ents.GetAll()) do
			if ent.GeminiAI then ent:Remove() e = e + 1 end
		end
	end
	return t, h, e
end

---------------------------------------------------------------------------
-- Главная функция: игрок что-то сказал ИИ
---------------------------------------------------------------------------
local function SendReply(ply, data)
	if not IsValid(ply) then
		MsgC(GeminiAI.Colors.Accent, "[Gemini AI] ", color_white, Sanitize(data.say or data.err or "") .. "\n")
		if data.code and data.code ~= "" then MsgC(GeminiAI.Colors.Dim, data.code .. "\n") end
		if data.result then MsgC(data.resultOk and GeminiAI.Colors.Good or GeminiAI.Colors.Bad, Sanitize(data.result) .. "\n") end
		return
	end

	net.Start("GeminiAI_Reply")
		net.WriteBool(data.err == nil)
		net.WriteString(Sanitize(data.err or data.say or ""))
		net.WriteString(Sanitize(data.code or ""))
		net.WriteUInt(data.id or 0, 32)
		net.WriteBool(data.canRun and true or false)
		net.WriteBool(data.result ~= nil)
		if data.result ~= nil then
			net.WriteBool(data.resultOk and true or false)
			net.WriteString(Sanitize(data.result))
		end
	net.Send(ply)
end

function GeminiAI.Ask(ply, text)
	local sid = SID(ply)
	text = string.Trim(tostring(text or "")):sub(1, 2000)
	if text == "" then return end

	if IsValid(ply) then
		if GeminiAI.Config.blocked[ply:SteamID()] then
			return SendReply(ply, { err = "Вам запрещено пользоваться Gemini AI." })
		end
		local canChat = GeminiAI.HasAccess(ply, "Chat") and (cv.public:GetBool() or GeminiAI.HasAccess(ply, "Execute"))
		if not canChat then
			return SendReply(ply, { err = "У вас нет доступа к Gemini AI." })
		end
		local wait = (GeminiAI.LastAsk[sid] or 0) + cv.cooldown:GetFloat() - CurTime()
		if wait > 0 and not GeminiAI.HasAccess(ply, "Admin") then
			return SendReply(ply, { err = string.format("Подождите %.1f сек.", wait) })
		end
	end

	if GeminiAI.Busy[sid] then
		return SendReply(ply, { err = "ИИ ещё отвечает на прошлое сообщение…" })
	end

	local canExec = cv.execute:GetBool() and GeminiAI.HasAccess(ply, "Execute")

	-- История диалога
	local hist = GeminiAI.History[sid] or {}
	GeminiAI.History[sid] = hist

	local contents = {}
	local maxHist = cv.history:GetInt()
	for i = math.max(1, #hist - maxHist + 1), #hist do
		contents[#contents + 1] = { role = hist[i].role, parts = { { text = hist[i].text } } }
	end
	contents[#contents + 1] = { role = "user", parts = { { text = BuildContext(ply, canExec) .. "\n\n[СООБЩЕНИЕ ИГРОКА]\n" .. text } } }

	GeminiAI.Busy[sid] = true
	GeminiAI.LastAsk[sid] = CurTime()
	SetThinking(ply, true)

	if IsValid(ply) and cv.broadcast:GetBool() then
		for _, p in ipairs(player.GetAll()) do
			if p ~= ply then GeminiAI.Notify(p, ply:Nick() .. " → ИИ: " .. text) end
		end
	end

	GeminiAI.Request(contents, function(res, err)
		GeminiAI.Busy[sid] = nil
		SetThinking(ply, false)
		if ply ~= nil and IsValid(ply) == false and sid ~= "console" then return end -- игрок вышел

		if not res then
			return SendReply(ply, { err = err })
		end

		hist[#hist + 1] = { role = "user", text = text }
		hist[#hist + 1] = { role = "model", text = res.raw }
		while #hist > 60 do table.remove(hist, 1) end

		local term = GeminiAI.Terminals[sid]
		if IsValid(term) then term:EmitSound("buttons/blip1.wav", 70, 110) end

		local reply = { say = res.say, code = res.lua }
		local hasCode = string.Trim(res.lua) ~= ""

		if hasCode and canExec then
			GeminiAI.NextID = GeminiAI.NextID + 1
			reply.id = GeminiAI.NextID

			local store = GeminiAI.Codes[sid] or {}
			GeminiAI.Codes[sid] = store
			store[reply.id] = res.lua
			store[reply.id - 30] = nil -- храним последние 30

			if cv.confirm:GetBool() and IsValid(ply) then
				reply.canRun = true
			else
				local ok, result = GeminiAI.Execute(ply, res.lua)
				reply.result, reply.resultOk, reply.canRun = result, ok, true
				GeminiAI.Log(ply, text, res.lua, ok)
			end
		elseif hasCode then
			reply.code = "" -- без прав код не показываем и не выполняем
		end

		SendReply(ply, reply)

		if IsValid(ply) and cv.broadcast:GetBool() and res.say ~= "" then
			for _, p in ipairs(player.GetAll()) do
				if p ~= ply then GeminiAI.Notify(p, "ИИ → " .. ply:Nick() .. ": " .. res.say) end
			end
		end
	end)
end

function GeminiAI.Log(ply, prompt, code, ok)
	file.CreateDir(CFG_DIR)
	local line = string.format("[%s] %s (%s): %s\n--- код (%s) ---\n%s\n\n",
		os.date("%Y-%m-%d %H:%M:%S"),
		IsValid(ply) and ply:Nick() or "Консоль", IsValid(ply) and ply:SteamID() or "-",
		prompt, ok and "успех" or "ошибка", code)
	file.Append(CFG_DIR .. "/log.txt", line)
end

---------------------------------------------------------------------------
-- Сеть
---------------------------------------------------------------------------
net.Receive("GeminiAI_Ask", function(_, ply)
	GeminiAI.Ask(ply, net.ReadString())
end)

net.Receive("GeminiAI_Run", function(_, ply)
	local id = net.ReadUInt(32)
	if not (cv.execute:GetBool() and GeminiAI.HasAccess(ply, "Execute")) then return end

	local store = GeminiAI.Codes[ply:SteamID64()]
	local code = store and store[id]
	if not code then return end

	local ok, result = GeminiAI.Execute(ply, code)
	GeminiAI.Log(ply, "(повторный запуск #" .. id .. ")", code, ok)

	net.Start("GeminiAI_RunResult")
		net.WriteUInt(id, 32)
		net.WriteBool(ok)
		net.WriteString(Sanitize(result))
	net.Send(ply)
end)

net.Receive("GeminiAI_Reset", function(_, ply)
	GeminiAI.History[ply:SteamID64()] = nil
	GeminiAI.Notify(ply, "Память ИИ очищена.")
end)

net.Receive("GeminiAI_AdminSet", function(_, ply)
	if not GeminiAI.HasAccess(ply, "Admin") then
		return GeminiAI.Notify(ply, "Нет прав на настройку Gemini AI.", true)
	end
	local key, value = net.ReadString(), net.ReadString()
	if key == "apikey" then
		GeminiAI.SetKey(value)
		GeminiAI.Notify(ply, GeminiAI.HasKey() and "API-ключ сохранён." or "API-ключ удалён.")
		return
	end
	local okSet, msg = GeminiAI.SetSetting(key, value)
	GeminiAI.Notify(ply, msg, not okSet)
end)

function GeminiAI.SetSetting(key, value)
	local kind = GeminiAI.Settable[key]
	if not kind then
		return false, "Неизвестный параметр. Доступны: " .. table.concat(table.GetKeys(GeminiAI.Settable), ", ")
	end
	if kind == "string" and not string.match(value, "^[%w%.%-_]+$") then
		return false, "Недопустимое значение."
	end
	if kind == "bool" then value = (value == "1" or value == "true" or value == "on") and "1" or "0" end
	if kind == "number" and not tonumber(value) then return false, "Нужно число." end
	GeminiAI.CVars[key]:SetString(value)
	return true, "Параметр «" .. key .. "» = " .. value
end

---------------------------------------------------------------------------
-- Получить список моделей (команда gemini_ai_models)
---------------------------------------------------------------------------
function GeminiAI.ListModels(cb)
	if not GeminiAI.HasKey() then return cb(nil, "API-ключ не задан") end
	HTTP({
		url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
		method = "GET",
		headers = { ["x-goog-api-key"] = API_KEY },
		success = function(code, body)
			local data = util.JSONToTable(body or "")
			if code ~= 200 or not istable(data) then return cb(nil, "HTTP " .. code) end
			local list = {}
			for _, m in ipairs(data.models or {}) do
				if istable(m.supportedGenerationMethods) and table.HasValue(m.supportedGenerationMethods, "generateContent") then
					list[#list + 1] = string.gsub(m.name or "", "^models/", "")
				end
			end
			cb(list)
		end,
		failed = function(reason) cb(nil, tostring(reason)) end,
	})
end
