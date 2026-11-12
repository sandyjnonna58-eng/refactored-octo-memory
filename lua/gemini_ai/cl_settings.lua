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

local BuildSettings
function BuildSettings(pnl)
	pnl:ClearControls()

	local C = GeminiAI.UIColors
	local open = pnl:Button("Открыть чат с ИИ")
	open.DoClick = GeminiAI.OpenMenu

	pnl:Help("Также: вкладка «Gemini AI» в меню Q, энтити «ИИ Терминал» в разделе Энтити → Gemini AI, или команда !ai в чате.")

	if GeminiAI.HasAccess(LocalPlayer(), "Characters") then
		local chars = pnl:Button("ИИ-персонажи (боты с ролью)")
		chars.DoClick = function() GeminiAI.OpenCharMenu() end
		pnl:ControlHelp("Живые боты под управлением ИИ: ходят, говорят, дерутся и отыгрывают роль. Нужен мультиплеер.")
	end

	if not GeminiAI.HasAccess(LocalPlayer(), "Admin") then
		pnl:Help("Настройки доступны только администраторам (право GeminiAI.Admin).")
		return
	end

	-- Провайдер ИИ: при смене перестраиваем панель (ключ и модели у каждого свои)
	local prov = GetConVarString("gemini_ai_provider")
	if not GeminiAI.ProviderNames[prov] then prov = "gemini" end

	Header(pnl, "Провайдер ИИ")
	local pcombo = vgui.Create("DComboBox", pnl)
	pcombo:SetValue(GeminiAI.ProviderNames[prov])
	for _, name in ipairs(GeminiAI.ProviderList) do pcombo:AddChoice(GeminiAI.ProviderNames[name], name) end
	pcombo.OnSelect = function(_, _, _, data)
		AdminSet("provider", data)
		timer.Simple(0.6, function() if IsValid(pnl) then BuildSettings(pnl) end end)
	end
	pnl:AddItem(pcombo)

	local HELP = {
		gemini = "Бесплатно. Ключ: aistudio.google.com/apikey → Create API key. В России нужен VPN на компьютере сервера.",
		deepseek = "Платно, но очень дёшево. Ключ: platform.deepseek.com → API keys (пополните баланс в Top up). Работает без VPN.",
		custom = "Любой OpenAI-совместимый сервер. Примеры адресов:\n• OpenRouter: https://openrouter.ai/api/v1 (есть бесплатные модели с «:free»)\n• Ollama на этом ПК: http://localhost:11434/v1 (ключ не нужен; серверу нужен параметр запуска -allowlocalhttp)",
	}
	pnl:Help(HELP[prov])

	Header(pnl, "Ключ " .. GeminiAI.ProviderNames[prov])
	local state = vgui.Create("DLabel", pnl)
	state:SetFont("GeminiAI_Small")
	state.Think = function(s)
		s:SetText(GeminiAI.KeySet and "Статус: готово к работе" or "Статус: ключ НЕ задан")
		s:SetTextColor(GeminiAI.KeySet and C.good or C.bad)
	end
	pnl:AddItem(state)

	local entry = vgui.Create("DTextEntry", pnl)
	entry:SetPlaceholderText(({ gemini = "AIza...", deepseek = "sk-...", custom = "ключ (если нужен)" })[prov])
	pnl:AddItem(entry)

	local save = pnl:Button("Сохранить ключ")
	save.DoClick = function()
		AdminSet("apikey", string.Trim(entry:GetValue()))
		entry:SetText("")
	end

	local test = pnl:Button("Проверить подключение")
	test.DoClick = function() RunConsoleCommand("gemini_ai_test") end

	Header(pnl, "Модель")
	if prov == "gemini" then
		local combo = vgui.Create("DComboBox", pnl)
		combo:SetValue(GetConVarString("gemini_ai_model"))
		for _, m in ipairs(GeminiAI.Models) do combo:AddChoice(m) end
		combo.OnSelect = function(_, _, value) AdminSet("model", value) end
		pnl:AddItem(combo)
		pnl:Help("gemini-flash-latest — быстрая и бесплатная. Если «лимит исчерпан» — выберите flash-lite. Полный список: команда gemini_ai_models.")
	elseif prov == "deepseek" then
		local combo = vgui.Create("DComboBox", pnl)
		combo:SetValue(GetConVarString("gemini_ai_ds_model"))
		for _, m in ipairs(GeminiAI.DeepSeekModels) do combo:AddChoice(m) end
		combo.OnSelect = function(_, _, value) AdminSet("ds_model", value) end
		pnl:AddItem(combo)
		pnl:Help("deepseek-chat — быстрая, для чата и персонажей. deepseek-reasoner — умнее в коде, но отвечает заметно дольше.")
	else
		local url = vgui.Create("DTextEntry", pnl)
		url:SetValue(GetConVarString("gemini_ai_custom_url"))
		url:SetPlaceholderText("https://openrouter.ai/api/v1")
		url.OnEnter = function(e) AdminSet("custom_url", string.Trim(e:GetValue())) end
		pnl:AddItem(url)
		local model = vgui.Create("DTextEntry", pnl)
		model:SetValue(GetConVarString("gemini_ai_custom_model"))
		model:SetPlaceholderText("deepseek/deepseek-chat")
		model.OnEnter = function(e) AdminSet("custom_model", string.Trim(e:GetValue())) end
		pnl:AddItem(model)
		local apply = pnl:Button("Сохранить адрес и модель")
		apply.DoClick = function()
			AdminSet("custom_url", string.Trim(url:GetValue()))
			AdminSet("custom_model", string.Trim(model:GetValue()))
		end
		pnl:Help("Список моделей сервера — команда gemini_ai_models.")
	end

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

	Header(pnl, "ИИ-персонажи")
	if prov == "gemini" then
		local cm = vgui.Create("DComboBox", pnl)
		cm:SetValue(GetConVarString("gemini_ai_char_model"))
		for _, m in ipairs(GeminiAI.Models) do cm:AddChoice(m) end
		cm.OnSelect = function(_, _, value) AdminSet("char_model", value) end
		pnl:AddItem(cm)
		pnl:ControlHelp("Модель персонажей. lite — больше бесплатных запросов в минуту.")
	else
		pnl:ControlHelp("Персонажи используют ту же модель: " .. GeminiAI.ActiveModel(true))
	end
	Slider("Думает раз в (сек)", "char_idle", 5, 120)
	Slider("Запросов в минуту", "char_rpm", 1, 60)
	Slider("Дальность слуха", "char_hear", 100, 3000)
	Check("Показывать мысли персонажей админам", "char_debug")

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
