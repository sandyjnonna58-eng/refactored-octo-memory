--[[-------------------------------------------------------------------------
	Gemini AI — команды для админов и игроков
	Консоль:  gemini_ai_*      Чат:  !ai  /ai  !aihelp ...
---------------------------------------------------------------------------]]

local function Reply(ply, text, isError)
	if IsValid(ply) then
		GeminiAI.Notify(ply, text, isError)
	else
		MsgC(GeminiAI.Colors.Accent, "[Gemini AI] ", isError and GeminiAI.Colors.Bad or color_white, text .. "\n")
	end
end

local function FindPlayer(name)
	if not name or name == "" then return end
	local lname = string.lower(name)
	for _, p in ipairs(player.GetAll()) do
		if p:SteamID() == name or p:SteamID64() == name then return p end
	end
	for _, p in ipairs(player.GetAll()) do
		if string.find(string.lower(p:Nick()), lname, 1, true) then return p end
	end
end

-- Регистрация команды: и в консоли, и в чате
GeminiAI.Commands = {}

local function AddCommand(name, chatAliases, access, help, fn)
	GeminiAI.Commands[#GeminiAI.Commands + 1] = { name = name, chat = chatAliases, access = access, help = help }

	local function run(ply, args, argStr)
		if access and not GeminiAI.HasAccess(ply, access) then
			return Reply(ply, "Нет прав на эту команду (нужно: " .. GeminiAI.Privileges[access].Name .. ").", true)
		end
		fn(ply, args, argStr or table.concat(args, " "))
	end

	concommand.Add(name, function(ply, _, args, argStr) run(ply, args, argStr) end, nil, help)

	for _, alias in ipairs(chatAliases or {}) do
		GeminiAI.ChatCommands = GeminiAI.ChatCommands or {}
		GeminiAI.ChatCommands[alias] = run
	end
end

---------------------------------------------------------------------------
-- Для всех игроков
---------------------------------------------------------------------------
AddCommand("gemini_ai_ask", { "ai", "ии", "gemini" }, "Chat", "Спросить ИИ: gemini_ai_ask <текст>",
	function(ply, _, text)
		if string.Trim(text) == "" then
			if IsValid(ply) then net.Start("GeminiAI_Open") net.Send(ply) end
			return
		end
		GeminiAI.Ask(ply, text)
	end)

AddCommand("gemini_ai_reset", { "aireset" }, nil, "Очистить память ИИ: gemini_ai_reset [игрок|all] (чужую — только админ)",
	function(ply, args)
		local target = args[1]
		if target and target ~= "" then
			if not GeminiAI.HasAccess(ply, "Admin") then return Reply(ply, "Чужую память может очищать только админ.", true) end
			if target == "all" then
				GeminiAI.History = {}
				return Reply(ply, "Память ИИ очищена у всех.")
			end
			local p = FindPlayer(target)
			if not p then return Reply(ply, "Игрок не найден.", true) end
			GeminiAI.History[p:SteamID64()] = nil
			return Reply(ply, "Память ИИ очищена у " .. p:Nick())
		end
		GeminiAI.History[IsValid(ply) and ply:SteamID64() or "console"] = nil
		Reply(ply, "Память ИИ очищена.")
	end)

AddCommand("gemini_ai_help", { "aihelp" }, nil, "Список команд Gemini AI",
	function(ply)
		Reply(ply, "Команды (консоль / чат):")
		for _, c in ipairs(GeminiAI.Commands) do
			if not c.access or GeminiAI.HasAccess(ply, c.access) then
				local chat = (c.chat and c.chat[1]) and ("  |  !" .. c.chat[1]) or ""
				Reply(ply, c.name .. chat .. " — " .. c.help)
			end
		end
	end)

---------------------------------------------------------------------------
-- Для админов
---------------------------------------------------------------------------
AddCommand("gemini_ai_setkey", { "aikey" }, "Admin", "Задать API-ключ Gemini: gemini_ai_setkey <ключ>",
	function(ply, args)
		local key = args[1] or ""
		if key ~= "" and not string.match(key, "^[%w%-_]+$") then
			return Reply(ply, "Ключ выглядит неправильно.", true)
		end
		GeminiAI.SetKey(key)
		Reply(ply, key == "" and "API-ключ удалён." or "API-ключ сохранён в data/gemini_ai/config.json. Проверка: gemini_ai_test")
	end)

AddCommand("gemini_ai_status", { "aistatus" }, "Admin", "Показать состояние и настройки мода",
	function(ply)
		local cv = GeminiAI.CVars
		Reply(ply, "Версия " .. GeminiAI.Version .. " | ключ: " .. (GeminiAI.HasKey() and "задан" or "НЕ ЗАДАН") .. " | модель: " .. cv.model:GetString())
		Reply(ply, string.format("Выполнение кода: %s | подтверждение: %s | общий доступ: %s | трансляция в чат: %s",
			cv.execute:GetBool() and "вкл" or "выкл", cv.confirm:GetBool() and "вкл" or "выкл",
			cv.public:GetBool() and "вкл" or "выкл", cv.broadcast:GetBool() and "вкл" or "выкл"))
		Reply(ply, string.format("Задержка: %s сек | память: %d сообщ. | температура: %s | заблокировано: %d",
			cv.cooldown:GetString(), cv.history:GetInt(), cv.temperature:GetString(), table.Count(GeminiAI.Config.blocked)))
		Reply(ply, "Админ-мод: " .. (CAMI and "CAMI найден (ULX/SAM/...) — права GeminiAI.*" or "не найден, используются группы superadmin/admin"))
	end)

AddCommand("gemini_ai_set", { "aiset" }, "Admin", "Изменить настройку: gemini_ai_set <model|execute|confirm|public|broadcast|cooldown|history|temperature> <значение>",
	function(ply, args)
		if not args[1] then
			return Reply(ply, "Параметры: " .. table.concat(table.GetKeys(GeminiAI.Settable), ", "), true)
		end
		local ok, msg = GeminiAI.SetSetting(args[1], args[2] or "")
		Reply(ply, msg, not ok)
	end)

AddCommand("gemini_ai_test", { "aitest" }, "Admin", "Проверить подключение к Gemini (gemini_ai_test char — запрос как у ИИ-персонажей)",
	function(ply, args)
		local char = args[1] == "char"
		local model = char and GeminiAI.CVars.char_model:GetString() or GeminiAI.CVars.model:GetString()
		Reply(ply, "Проверяю подключение к " .. model .. (char and " (быстрый режим персонажей)" or "") .. "…")
		local start = SysTime()
		GeminiAI.Request({ { role = "user", parts = { { text = "Ответь одним словом: работает" } } } }, function(res, err)
			if res then
				local lvl = GeminiAI.ModelLevel[model] or 0
				Reply(ply, string.format("Подключение работает! (%.1f сек) Ответ: %s%s", SysTime() - start, res.say,
					lvl > 0 and (" [модель упрощена до уровня " .. lvl .. "]") or ""))
			else
				Reply(ply, "Ошибка: " .. tostring(err), true)
			end
		end, char and { model = model, fast = true, maxTokens = 60 } or nil)
	end)

AddCommand("gemini_ai_models", { "aimodels" }, "Admin", "Список доступных моделей Gemini для вашего ключа",
	function(ply)
		GeminiAI.ListModels(function(list, err)
			if not list then return Reply(ply, "Ошибка: " .. tostring(err), true) end
			Reply(ply, "Доступные модели (" .. #list .. "): " .. table.concat(list, ", "))
			Reply(ply, "Сменить: gemini_ai_set model <название>")
		end)
	end)

AddCommand("gemini_ai_stop", { "aistop" }, "Admin", "Остановить все таймеры и хуки, созданные ИИ",
	function(ply)
		local t, h = GeminiAI.StopAll(false)
		Reply(ply, string.format("Остановлено: таймеров %d, хуков %d.", t, h))
	end)

AddCommand("gemini_ai_cleanup", { "aicleanup" }, "Admin", "Удалить ВСЁ, что создал ИИ (объекты, таймеры, хуки)",
	function(ply)
		local t, h, e = GeminiAI.StopAll(true)
		Reply(ply, string.format("Удалено объектов: %d, таймеров: %d, хуков: %d.", e, t, h))
	end)

AddCommand("gemini_ai_block", { "aiblock" }, "Admin", "Запретить игроку пользоваться ИИ: gemini_ai_block <ник|SteamID>",
	function(ply, args)
		local p = FindPlayer(args[1])
		local sid = p and p:SteamID() or args[1]
		if not sid or not string.match(sid, "^STEAM_%d:%d:%d+$") then return Reply(ply, "Игрок не найден.", true) end
		GeminiAI.Config.blocked[sid] = true
		GeminiAI.SaveConfig()
		Reply(ply, "Заблокирован: " .. (p and p:Nick() or sid))
		if p then GeminiAI.Notify(p, "Администратор запретил вам пользоваться Gemini AI.", true) end
	end)

AddCommand("gemini_ai_unblock", { "aiunblock" }, "Admin", "Разблокировать игрока: gemini_ai_unblock <ник|SteamID>",
	function(ply, args)
		local p = FindPlayer(args[1])
		local sid = p and p:SteamID() or args[1]
		if not sid or not GeminiAI.Config.blocked[sid] then return Reply(ply, "Этот игрок не заблокирован.", true) end
		GeminiAI.Config.blocked[sid] = nil
		GeminiAI.SaveConfig()
		Reply(ply, "Разблокирован: " .. (p and p:Nick() or sid))
	end)

AddCommand("gemini_ai_run", nil, "Execute", "Выполнить Lua через окружение ИИ (ME, TR, AI): gemini_ai_run <код>",
	function(ply, _, code)
		local ok, res = GeminiAI.Execute(ply, code)
		Reply(ply, res, not ok)
	end)

---------------------------------------------------------------------------
-- ИИ-персонажи (sv_character.lua)
---------------------------------------------------------------------------
local function RestAfterFirst(text)
	return string.Trim(string.match(text or "", "^%s*%S+%s*(.*)$") or "")
end

AddCommand("gemini_ai_char", { "aichar" }, "Characters", "Создать ИИ-персонажа: gemini_ai_char [имя] [роль...] (без аргументов — меню)",
	function(ply, args, text)
		if not args[1] then
			if IsValid(ply) then net.Start("GeminiAI_CharMenu") net.WriteBool(false) net.Send(ply) end
			return
		end
		local pos = IsValid(ply) and (ply:GetEyeTrace().HitPos + Vector(0, 0, 4)) or nil
		local ang = IsValid(ply) and Angle(0, ply:EyeAngles().y + 180, 0) or nil
		local char, err = GeminiAI.CreateCharacter(ply, args[1], RestAfterFirst(text), pos, ang)
		Reply(ply, char and ("Персонаж «" .. char.name .. "» создан.") or err, not char)
	end)

AddCommand("gemini_ai_char_list", { "aichars" }, "Characters", "Список ИИ-персонажей",
	function(ply)
		local n = 0
		for bot, char in pairs(GeminiAI.Chars) do
			if IsValid(bot) then
				n = n + 1
				Reply(ply, string.format("%s — %s%s | %s", char.name, char.action,
					char.targetName ~= "" and (" -> " .. char.targetName) or "", string.sub(char.role, 1, 80)))
			end
		end
		if n == 0 then Reply(ply, "Персонажей нет. Создать: !aichar Имя роль") end
	end)

AddCommand("gemini_ai_char_order", { "aiorder" }, "Characters", "Тайный приказ персонажу: gemini_ai_char_order <имя> <что сделать>",
	function(ply, args, text)
		local char = GeminiAI.FindChar(args[1])
		local order = RestAfterFirst(text)
		if not char or order == "" then return Reply(ply, "Использование: !aiorder <имя> <приказ>", true) end
		char.orders[#char.orders + 1] = order
		char.nextThink = CurTime()
		Reply(ply, "Приказ передан «" .. char.name .. "».")
	end)

AddCommand("gemini_ai_char_role", { "airole" }, "Characters", "Сменить роль персонажа: gemini_ai_char_role <имя> <новая роль>",
	function(ply, args, text)
		local char = GeminiAI.FindChar(args[1])
		local role = RestAfterFirst(text)
		if not char or role == "" then return Reply(ply, "Использование: !airole <имя> <роль>", true) end
		char.role, char.history = role, {}
		char.nextThink = CurTime()
		Reply(ply, "Роль «" .. char.name .. "» изменена.")
	end)

AddCommand("gemini_ai_char_tp", { "aitp" }, "Characters", "Телепортировать персонажа туда, куда смотрите: gemini_ai_char_tp <имя>",
	function(ply, args)
		local char = GeminiAI.FindChar(args[1])
		if not char or not IsValid(ply) then return Reply(ply, "Персонаж не найден.", true) end
		char.bot:SetPos(ply:GetEyeTrace().HitPos + Vector(0, 0, 4))
		Reply(ply, "«" .. char.name .. "» перемещён.")
	end)

AddCommand("gemini_ai_char_remove", { "aikick" }, "Characters", "Удалить персонажа: gemini_ai_char_remove <имя|all>",
	function(ply, args)
		if args[1] == "all" then
			local list = {}
			for _, char in pairs(GeminiAI.Chars) do list[#list + 1] = char end
			for _, char in ipairs(list) do GeminiAI.RemoveChar(char) end
			return Reply(ply, "Удалено персонажей: " .. #list)
		end
		local char = GeminiAI.FindChar(args[1])
		if not char then return Reply(ply, "Персонаж не найден.", true) end
		GeminiAI.RemoveChar(char)
		Reply(ply, "Персонаж «" .. char.name .. "» удалён.")
	end)

---------------------------------------------------------------------------
-- Чат-команды: !ai, /ai, .ai
---------------------------------------------------------------------------
-- Возвращает true, если сообщение было нашей командой
function GeminiAI.HandleChat(ply, text)
	if IsValid(ply) and ply.GeminiChar then return false end -- ИИ-персонажи команды не запускают
	local prefix, cmd, rest = string.match(text or "", "^([!/%.])(%S+)%s*(.*)$")
	if not prefix then return false end

	local run = GeminiAI.ChatCommands and GeminiAI.ChatCommands[string.lower(cmd)]
	if not run then return false end

	local args = string.Explode(" ", rest or "")
	if args[1] == "" then args = {} end
	run(ply, args, rest or "")
	return true
end

-- Рекос (ZChat): чат идёт через net -> PlayerSay "ZChat" -> HG_PlayerSay.
-- Обрабатываем команду там и обнуляем текст, а PlayerSay ниже глушит её,
-- чтобы команда (и API-ключ из !aikey) не попала в общий чат.
hook.Add("HG_PlayerSay", "GeminiAI_ChatCommands", function(ply, txtTbl, text)
	ply.GeminiAI_Suppress = nil
	if GeminiAI.HandleChat(ply, text) then
		ply.GeminiAI_Suppress = text
		if istable(txtTbl) then txtTbl[1] = "" end
	end
end)

-- Обычный GMod (и рекос, если наш хук вызовется раньше ZChat)
hook.Add("PlayerSay", "GeminiAI_ChatCommands", function(ply, text)
	if ply.GeminiAI_Suppress ~= nil then
		local handled = ply.GeminiAI_Suppress == text
		ply.GeminiAI_Suppress = nil
		if handled then return "" end
	end
	if GeminiAI.HandleChat(ply, text) then
		return "" -- скрываем команду из общего чата (ключ API тоже не будет виден)
	end
end)
