--[[-------------------------------------------------------------------------
	Gemini AI — настройки в меню спавна: Q → Утилиты → Gemini AI
---------------------------------------------------------------------------]]

local function AdminSet(key, value)
	net.Start("GeminiAI_AdminSet")
		net.WriteString(key)
		net.WriteString(tostring(value))
	net.SendToServer()
end

local function Header(pnl, text)
	local l = vgui.Create("DLabel", pnl)
	l:SetText(text)
	l:SetFont("GeminiAI_Bold")
	l:SetTextColor(GeminiAI.UIColors.accent)
	l:SetTall(26)
	pnl:AddItem(l)
end

local function BuildSettings(pnl)
	pnl:ClearControls()

	local C = GeminiAI.UIColors
	local open = pnl:Button("Открыть чат с ИИ")
	open.DoClick = GeminiAI.OpenMenu

	pnl:Help("Также: вкладка «Gemini AI» в меню Q, энтити «ИИ Терминал» в разделе Энтити → Gemini AI, или команда !ai в чате.")

	if not GeminiAI.HasAccess(LocalPlayer(), "Admin") then
		pnl:Help("Настройки доступны только администраторам (право GeminiAI.Admin).")
		return
	end

	Header(pnl, "API-ключ Gemini (бесплатно)")
	pnl:Help("1. Откройте aistudio.google.com/apikey\n2. Нажмите «Create API key»\n3. Вставьте ключ ниже. Ключ хранится только на сервере.")

	local state = vgui.Create("DLabel", pnl)
	state:SetFont("GeminiAI_Small")
	state.Think = function(s)
		s:SetText(GeminiAI.KeySet and "Статус: ключ задан" or "Статус: ключ НЕ задан")
		s:SetTextColor(GeminiAI.KeySet and C.good or C.bad)
	end
	pnl:AddItem(state)

	local entry = vgui.Create("DTextEntry", pnl)
	entry:SetPlaceholderText("AIza...")
	pnl:AddItem(entry)

	local save = pnl:Button("Сохранить ключ")
	save.DoClick = function()
		AdminSet("apikey", string.Trim(entry:GetValue()))
		entry:SetText("")
	end

	local test = pnl:Button("Проверить подключение")
	test.DoClick = function() RunConsoleCommand("gemini_ai_test") end

	Header(pnl, "Модель")
	local combo = vgui.Create("DComboBox", pnl)
	combo:SetValue(GetConVarString("gemini_ai_model"))
	for _, m in ipairs(GeminiAI.Models) do combo:AddChoice(m) end
	combo.OnSelect = function(_, _, value) AdminSet("model", value) end
	pnl:AddItem(combo)
	pnl:Help("gemini-flash-latest — быстрая и бесплатная. Если «лимит исчерпан» — выберите flash-lite. Полный список: команда gemini_ai_models.")

	Header(pnl, "Поведение")
	local function Check(label, key, help)
		local cb = vgui.Create("DCheckBoxLabel", pnl)
		cb:SetText(label)
		cb:SetTextColor(Color(30, 30, 30))
		cb:SetChecked(GetConVar("gemini_ai_" .. key):GetBool())
		cb.OnChange = function(_, val) AdminSet(key, val and "1" or "0") end
		pnl:AddItem(cb)
		if help then pnl:ControlHelp(help) end
	end
	Check("ИИ может выполнять Lua-код", "execute", "Только для игроков с правом GeminiAI.Execute (по умолчанию superadmin).")
	Check("Спрашивать перед выполнением", "confirm", "ИИ покажет код, а выполнится он по кнопке «Выполнить».")
	Check("Обычные игроки могут болтать с ИИ", "public", "Без выполнения кода.")
	Check("Показывать ответы ИИ всем в чате", "broadcast")

	local function Slider(label, key, min, max, dec)
		local s = vgui.Create("DNumSlider", pnl)
		s:SetText(label)
		s:SetDark(true)
		s:SetMinMax(min, max)
		s:SetDecimals(dec or 0)
		s:SetValue(GetConVar("gemini_ai_" .. key):GetFloat())
		s.OnValueChanged = function(_, v)
			timer.Create("GeminiAI_Slider_" .. key, 0.4, 1, function() AdminSet(key, math.Round(v, dec or 0)) end)
		end
		pnl:AddItem(s)
	end
	Slider("Задержка (сек)", "cooldown", 0, 60)
	Slider("Память (сообщ.)", "history", 0, 40)
	Slider("Креативность", "temperature", 0, 2, 2)

	Header(pnl, "Управление")
	local stop = pnl:Button("Остановить таймеры/хуки ИИ")
	stop.DoClick = function() RunConsoleCommand("gemini_ai_stop") end
	local clean = pnl:Button("Удалить всё, что создал ИИ")
	clean.DoClick = function()
		Derma_Query("Удалить все объекты, таймеры и хуки, созданные ИИ?", "Gemini AI", "Удалить", function() RunConsoleCommand("gemini_ai_cleanup") end, "Отмена")
	end
	local status = pnl:Button("Статус в консоль")
	status.DoClick = function() RunConsoleCommand("gemini_ai_status") end
	local help = pnl:Button("Список команд")
	help.DoClick = function() RunConsoleCommand("gemini_ai_help") end
end

hook.Add("PopulateToolMenu", "GeminiAI_Settings", function()
	spawnmenu.AddToolMenuOption("Utilities", "Gemini AI", "GeminiAI_Settings", "Настройки ИИ", "", "", BuildSettings)
end)
