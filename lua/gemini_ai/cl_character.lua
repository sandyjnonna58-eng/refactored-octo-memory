--[[-------------------------------------------------------------------------
	Gemini AI — клиент: окно ИИ-персонажей (создание, роли, приказы)
	Открыть: !aichar, gemini_ai_char, Q -> Энтити -> Gemini AI -> «ИИ Персонаж»
---------------------------------------------------------------------------]]

GeminiAI.CharList = GeminiAI.CharList or {}

local PRESETS = {
	{ "Житель", "Обычный местный житель. Дружелюбный, немного уставший, любит поговорить о жизни и пожаловаться на цены. Боится оружия и убегает от стрельбы." },
	{ "Напарник", "Верный напарник игрока, который его создал. Ходит следом, прикрывает, шутит, подбирает оружие. Нападает на тех, кто нападает на друзей." },
	{ "Бандит", "Грубый уличный бандит. Подходит к людям, требует деньги и оружие, угрожает. Если отказывают или грубят — нападает. Трусоват: при ранении убегает." },
	{ "Охранник", "Строгий охранник объекта. Говорит официально, не пускает посторонних, предупреждает дважды, на третий раз применяет силу. Защищает мирных." },
	{ "Медик", "Добрый, но нервный врач. Беспокоится о раненых, расспрашивает о самочувствии, советует перевязаться. Никогда не нападает первым." },
	{ "Параноик", "Параноик, уверенный, что за ним следят. Подозревает всех, шепчет теории заговора, шарахается от людей с оружием, может внезапно убежать." },
	{ "Торговец", "Болтливый торговец-хитрец. Пытается всем что-то продать, торгуется, льстит, рассказывает байки. Если угрожают — сдаётся и зовёт на помощь." },
	{ "Псих", "Непредсказуемый псих. Говорит странные вещи, смеётся невпопад, то дружелюбен, то агрессивен. Опасен, если его разозлить." },
}

local NAMES = { "Михаил", "Анна", "Дмитрий", "Ольга", "Сергей", "Ирина", "Виктор", "Катя", "Борис", "Лёха", "Марина", "Гоша", "Шрам", "Док", "Седой", "Рыжая" }

local function C() return GeminiAI.UIColors end

local function Dark(pnl, col, r)
	pnl.Paint = function(_, w, h) draw.RoundedBox(r or 8, 0, 0, w, h, col) end
end

local function Label(parent, text, font, col)
	local l = vgui.Create("DLabel", parent)
	l:SetText(text)
	l:SetFont(font or "GeminiAI_Small")
	l:SetTextColor(col or C().dim)
	l:SizeToContents()
	return l
end

local function StyledEntry(parent, multiline)
	local e = vgui.Create("DTextEntry", parent)
	e:SetFont("GeminiAI_Text")
	e:SetTextColor(C().text)
	e:SetCursorColor(C().accent2)
	e:SetMultiline(multiline and true or false)
	e:SetPaintBackground(false)
	e.Paint = function(s, w, h)
		draw.RoundedBox(8, 0, 0, w, h, C().input)
		if s:HasFocus() then
			surface.SetDrawColor(C().accent.r, C().accent.g, C().accent.b, 160)
			surface.DrawOutlinedRect(0, 0, w, h, 1)
		end
		s:DrawTextEntryText(C().text, Color(C().accent.r, C().accent.g, C().accent.b, 120), C().accent2)
	end
	return e
end

local function SendCommand(cmd, name, text)
	net.Start("GeminiAI_CharCommand")
		net.WriteString(cmd)
		net.WriteString(name)
		net.WriteString(text or "")
	net.SendToServer()
end

---------------------------------------------------------------------------
-- Карточка персонажа в списке
---------------------------------------------------------------------------
local function CharCard(parent, info)
	local card = vgui.Create("DPanel", parent)
	card:Dock(TOP)
	card:DockMargin(0, 0, 0, 8)
	card:SetTall(118)
	card.Paint = function(_, w, h)
		local c = C()
		draw.RoundedBox(10, 0, 0, w, h, c.ai)
		draw.RoundedBox(2, 0, 10, 3, h - 20, info.alive and c.accent or c.bad)
		draw.SimpleText(info.name, "GeminiAI_Bold", 14, 14, c.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local status = info.alive and (info.action .. (info.target ~= "" and (" → " .. info.target) or "")) or "мёртв"
		if (info.latency or 0) > 0 then status = status .. string.format("  •  %.1f с", info.latency) end
		draw.SimpleText(status, "GeminiAI_Small", w - 12, 14, info.alive and c.good or c.bad, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.sub(info.role, 1, 70) .. (#info.role > 70 and "…" or ""), "GeminiAI_Small", 14, 34, c.dim)
		if info.said ~= "" then
			draw.SimpleText("«" .. string.sub(info.said, 1, 60) .. (#info.said > 60 and "…" or "") .. "»", "GeminiAI_Small", 14, 52, c.text)
		end
		if (info.err or "") ~= "" then
			draw.SimpleText("ошибка: " .. string.sub(info.err, 1, 70), "GeminiAI_Small", 14, 70, c.bad)
		elseif info.thought ~= "" then
			draw.SimpleText("думает: " .. string.sub(info.thought, 1, 60) .. (#info.thought > 60 and "…" or ""), "GeminiAI_Small", 14, 70, Color(c.accent2.r, c.accent2.g, c.accent2.b, 200))
		end
	end

	local row = vgui.Create("DPanel", card)
	row:Dock(BOTTOM)
	row:SetTall(24)
	row:DockMargin(12, 0, 12, 8)
	row.Paint = nil

	local function Btn(label, col, fn)
		local b = vgui.Create("GeminiAI_Button", row)
		b:SetLabel(label)
		b:Dock(LEFT)
		b:DockMargin(0, 0, 6, 0)
		surface.SetFont("GeminiAI_Small")
		b:SetWide(surface.GetTextSize(label) + 22)
		if col then b:SetColor(col) end
		b.DoClick = fn
	end

	Btn("Приказ", Color(60, 70, 130), function()
		Derma_StringRequest("Тайный приказ для «" .. info.name .. "»",
			"Что персонаж должен сделать? Он выполнит это, оставаясь в роли.\nНапример: «подойди к Саше и попроси сигарету»",
			"", function(t) SendCommand("order", info.name, t) end)
	end)
	Btn("Роль", nil, function()
		Derma_StringRequest("Новая роль для «" .. info.name .. "»", "Опишите характер и поведение:", info.role,
			function(t) SendCommand("role", info.name, t) end)
	end)
	Btn("Ко мне", nil, function() SendCommand("tp", info.name) end)
	Btn("Удалить", Color(120, 40, 50), function()
		Derma_Query("Удалить персонажа «" .. info.name .. "»?", "Gemini AI", "Удалить",
			function() SendCommand("remove", info.name) end, "Отмена")
	end)
	return card
end

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
function GeminiAI.OpenCharMenu(spawnPos)
	if IsValid(GeminiAI.CharFrame) then GeminiAI.CharFrame:Remove() end
	local c = C()

	local f = vgui.Create("DFrame")
	f:SetSize(math.min(ScrW() - 40, 900), math.min(ScrH() - 40, 600))
	f:Center()
	f:SetTitle("")
	f:ShowCloseButton(false)
	f:DockPadding(0, 0, 0, 0)
	f:MakePopup()
	f.Paint = function(_, w, h) draw.RoundedBox(10, 0, 0, w, h, c.bg) end
	GeminiAI.CharFrame = f

	-- Шапка
	local head = vgui.Create("DPanel", f)
	head:Dock(TOP)
	head:SetTall(56)
	head.Paint = function(_, w, h)
		draw.RoundedBoxEx(10, 0, 0, w, h, c.header, true, true, false, false)
		surface.SetDrawColor(c.accent) surface.DrawRect(0, h - 2, w / 2, 2)
		surface.SetDrawColor(c.accent2) surface.DrawRect(w / 2, h - 2, w / 2, 2)
		draw.RoundedBox(10, 12, 10, 36, 36, c.accent)
		draw.SimpleText("AI", "GeminiAI_Icon", 30, 28, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("ИИ-персонажи", "GeminiAI_Title", 58, 18, c.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("живые боты, которые отыгрывают роль • модель " .. GetConVarString("gemini_ai_char_model"), "GeminiAI_Small", 58, 38, c.dim)
	end
	head.OnMousePressed = function() f.Dragging = { gui.MouseX() - f.x, gui.MouseY() - f.y } f:MouseCapture(true) end

	local close = vgui.Create("GeminiAI_Button", head)
	close:SetLabel("X")
	close.Font = "GeminiAI_Bold"
	close:SetSize(32, 32)
	close.DoClick = function() f:Remove() end
	head.PerformLayout = function(_, w) close:SetPos(w - 44, 12) end

	local body = vgui.Create("DPanel", f)
	body:Dock(FILL)
	body:DockPadding(12, 12, 12, 12)
	body.Paint = nil

	-- Левая колонка: создание
	local left = vgui.Create("DPanel", body)
	left:Dock(LEFT)
	left:SetWide(math.floor(f:GetWide() * 0.5) - 18)
	left:DockPadding(14, 12, 14, 14)
	Dark(left, c.panel, 10)

	Label(left, "НОВЫЙ ПЕРСОНАЖ", "GeminiAI_Bold", c.accent):Dock(TOP)

	Label(left, "Имя (так его будут звать и так к нему обращаться в чате)"):Dock(TOP)
	local nameRow = vgui.Create("DPanel", left)
	nameRow:Dock(TOP)
	nameRow:SetTall(32)
	nameRow:DockMargin(0, 4, 0, 10)
	nameRow.Paint = nil
	local nameEntry = StyledEntry(nameRow)
	nameEntry:Dock(FILL)
	nameEntry:SetValue(NAMES[math.random(#NAMES)])
	local dice = vgui.Create("GeminiAI_Button", nameRow)
	dice:SetLabel("Случайное")
	dice:SetWide(96)
	dice:Dock(RIGHT)
	dice:DockMargin(6, 0, 0, 0)
	dice.DoClick = function() nameEntry:SetValue(NAMES[math.random(#NAMES)]) end

	Label(left, "Быстрые роли"):Dock(TOP)
	local grid = vgui.Create("DIconLayout", left)
	grid:Dock(TOP)
	grid:DockMargin(0, 4, 0, 10)
	grid:SetSpaceX(6)
	grid:SetSpaceY(6)

	Label(left, "Роль и характер — опишите своими словами, ИИ будет так себя вести"):Dock(TOP)
	local roleEntry = StyledEntry(left, true)
	roleEntry:Dock(FILL)
	roleEntry:DockMargin(0, 4, 0, 10)
	roleEntry:SetValue(PRESETS[1][2])

	for _, p in ipairs(PRESETS) do
		local b = grid:Add("GeminiAI_Button")
		b:SetLabel(p[1])
		surface.SetFont("GeminiAI_Small")
		b:SetSize(surface.GetTextSize(p[1]) + 22, 26)
		b:SetColor(Color(40, 42, 62))
		b.DoClick = function() roleEntry:SetValue(p[2]) end
	end
	grid:InvalidateLayout(true)
	grid:SizeToChildren(false, true)

	local create = vgui.Create("DButton", left)
	create:Dock(BOTTOM)
	create:SetTall(42)
	create:SetText("")
	create.Paint = function(s, w, h)
		draw.RoundedBox(8, 0, 0, w, h, c.accent)
		local x, y = s:LocalToScreen(0, 0)
		render.SetScissorRect(x + 4, y, x + w - 4, y + h, true)
			surface.SetMaterial(Material("vgui/gradient-r"))
			surface.SetDrawColor(c.accent2.r, c.accent2.g, c.accent2.b, s:IsHovered() and 240 or 140)
			surface.DrawTexturedRect(0, 0, w, h)
		render.SetScissorRect(0, 0, 0, 0, false)
		draw.SimpleText(spawnPos and "Создать здесь" or "Создать там, куда я смотрю", "GeminiAI_Bold", w / 2, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	create.DoClick = function()
		net.Start("GeminiAI_CharCreate")
			net.WriteString(string.Trim(nameEntry:GetValue()))
			net.WriteString(string.Trim(roleEntry:GetValue()))
			net.WriteBool(spawnPos ~= nil)
			if spawnPos then net.WriteVector(spawnPos) end
		net.SendToServer()
		surface.PlaySound("buttons/button14.wav")
		nameEntry:SetValue(NAMES[math.random(#NAMES)])
		spawnPos = nil
	end

	-- Правая колонка: список
	local right = vgui.Create("DPanel", body)
	right:Dock(FILL)
	right:DockMargin(12, 0, 0, 0)
	right:DockPadding(14, 12, 14, 14)
	Dark(right, c.panel, 10)

	Label(right, "НА СЕРВЕРЕ", "GeminiAI_Bold", c.accent):Dock(TOP)
	local hint = Label(right, "Персонажи слышат чат рядом (и своё имя где угодно), видят, кто их ранил, и сами решают, что делать.")
	hint:Dock(TOP)
	hint:SetWrap(true)
	hint:SetAutoStretchVertical(true)
	hint:DockMargin(0, 2, 0, 8)

	local scroll = vgui.Create("DScrollPanel", right)
	scroll:Dock(FILL)
	scroll:GetVBar():SetWide(6)

	local function Rebuild()
		if not IsValid(scroll) then return end
		scroll:Clear()
		if #GeminiAI.CharList == 0 then
			local empty = Label(scroll, "Пока никого нет. Создайте первого персонажа слева.", "GeminiAI_Text")
			empty:Dock(TOP)
			empty:DockMargin(0, 20, 0, 0)
			empty:SetContentAlignment(5)
			return
		end
		for _, info in ipairs(GeminiAI.CharList) do CharCard(scroll, info) end
	end
	Rebuild()
	hook.Add("GeminiAI_CharListUpdated", f, function() Rebuild() end)

	net.Start("GeminiAI_CharList") net.SendToServer()
end

concommand.Add("gemini_ai_char_menu", function() GeminiAI.OpenCharMenu() end, nil, "Окно ИИ-персонажей")

net.Receive("GeminiAI_CharMenu", function()
	local pos = net.ReadBool() and net.ReadVector() or nil
	GeminiAI.OpenCharMenu(pos)
end)

net.Receive("GeminiAI_CharList", function()
	local len = net.ReadUInt(16)
	local data = util.JSONToTable(util.Decompress(net.ReadData(len)) or "") or {}
	GeminiAI.CharList = data
	hook.Run("GeminiAI_CharListUpdated")
end)

---------------------------------------------------------------------------
-- Облачка над головой: что персонаж сказал и «...», пока он думает
---------------------------------------------------------------------------
surface.CreateFont("GeminiAI_Bubble",     { font = "Roboto", size = 18, weight = 600, extended = true, antialias = true })
surface.CreateFont("GeminiAI_BubbleName", { font = "Roboto", size = 14, weight = 800, extended = true, antialias = true })

local bubbleCache = {} -- [бот] = { text, markup }

local function HeadPos(ply)
	-- в рекосе лежащий игрок — это регдолл
	local body = ply:GetNWEntity("FakeRagdoll")
	if not IsValid(body) then body = ply end
	local bone = body:LookupBone("ValveBiped.Bip01_Head1")
	local pos = bone and body:GetBonePosition(bone)
	return (pos or (body:GetPos() + Vector(0, 0, 64))) + Vector(0, 0, 16), body
end

local function Escape(s)
	s = tostring(s or "")
	if markup.Escape then return markup.Escape(s) end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

hook.Add("HUDPaint", "GeminiAI_CharBubbles", function()
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local eye = lp:EyePos()
	local now = CurTime()
	local c = GeminiAI.UIColors

	for _, ply in player.Iterator() do
		if ply ~= lp and ply:GetNW2Bool("GeminiChar", false) and ply:Alive() then
			local said = ply:GetNW2String("GeminiSay", "")
			local sayAge = now - ply:GetNW2Float("GeminiSayTime", -100)
			local showFor = 4 + #said * 0.04
			local thinking = ply:GetNW2Bool("GeminiThinking", false)

			if (said ~= "" and sayAge < showFor) or thinking then
				local pos, body = HeadPos(ply)
				local dist = eye:Distance(pos)
				if dist < 1300 then
					local tr = util.TraceLine({ start = eye, endpos = pos, filter = { lp, ply, body }, mask = MASK_VISIBLE })
					local scr = pos:ToScreen()
					if not tr.Hit and scr.visible then
						local alpha = math.Clamp((1300 - dist) / 300, 0, 1)
						if said ~= "" and sayAge < showFor then
							alpha = alpha * math.Clamp((showFor - sayAge) / 0.5, 0, 1) * math.Clamp(sayAge / 0.15, 0, 1)
						end
						local a = 255 * alpha
						local name = ply:GetNWString("PlayerName", ply:Nick())

						if said ~= "" and sayAge < showFor then
							local cache = bubbleCache[ply]
							if not cache or cache.text ~= said then
								cache = { text = said, mk = markup.Parse("<font=GeminiAI_Bubble>" .. Escape(said) .. "</font>", 300) }
								bubbleCache[ply] = cache
							end
							local mk = cache.mk
							local w = math.max(mk:GetWidth(), 60) + 24
							local h = mk:GetHeight() + 30
							local x, y = scr.x - w / 2, scr.y - h - 12 - (1 - math.Clamp(sayAge / 0.2, 0, 1)) * 10

							draw.RoundedBox(10, x, y, w, h, Color(14, 15, 22, 225 * alpha))
							draw.RoundedBox(2, x + 8, y + 6, 3, 14, Color(c.accent.r, c.accent.g, c.accent.b, a))
							draw.SimpleText(name, "GeminiAI_BubbleName", x + 16, y + 13, Color(c.accent2.r, c.accent2.g, c.accent2.b, a), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
							-- хвостик облачка
							draw.NoTexture()
							surface.SetDrawColor(14, 15, 22, 225 * alpha)
							surface.DrawPoly({ { x = scr.x - 8, y = y + h }, { x = scr.x + 8, y = y + h }, { x = scr.x, y = y + h + 9 } })
							mk:Draw(x + 12, y + 24, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, a)
						elseif thinking then
							-- «печатает...»
							local w, h = 58, 26
							local x, y = scr.x - w / 2, scr.y - h - 12
							draw.RoundedBox(13, x, y, w, h, Color(14, 15, 22, 210 * alpha))
							for i = 0, 2 do
								local k = (math.sin(now * 7 - i * 0.9) + 1) / 2
								draw.RoundedBox(4, x + 13 + i * 12, y + 9 - k * 3, 8, 8, Color(c.accent.r, c.accent.g + k * 70, c.accent.b, (120 + k * 135) * alpha))
							end
						end
					end
				end
			end
		end
	end
end)
