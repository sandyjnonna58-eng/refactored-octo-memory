--[[-------------------------------------------------------------------------
	Gemini AI — клиент: окно чата, вкладка в меню спавна (Q)
---------------------------------------------------------------------------]]

GeminiAI.Messages = GeminiAI.Messages or {}
GeminiAI.Thinking = false
GeminiAI.KeySet   = GeminiAI.KeySet == nil and true or GeminiAI.KeySet

local C = {
	bg       = Color(14, 15, 22, 250),
	panel    = Color(22, 24, 34),
	header   = Color(26, 28, 42),
	border   = Color(255, 255, 255, 12),
	user     = Color(92, 82, 230),
	user2    = Color(60, 150, 255),
	ai       = Color(32, 35, 50),
	code     = Color(9, 10, 15),
	codeHead = Color(20, 22, 32),
	input    = Color(30, 33, 46),
	text     = Color(235, 238, 245),
	dim      = Color(140, 146, 170),
	accent   = Color(130, 110, 255),
	accent2  = Color(60, 180, 255),
	good     = Color(90, 215, 150),
	bad      = Color(240, 95, 95),
	warn     = Color(255, 190, 80),
}
GeminiAI.UIColors = C

surface.CreateFont("GeminiAI_Title", { font = "Roboto", size = 22, weight = 800, extended = true, antialias = true })
surface.CreateFont("GeminiAI_Text",  { font = "Roboto", size = 17, weight = 500, extended = true, antialias = true })
surface.CreateFont("GeminiAI_Bold",  { font = "Roboto", size = 17, weight = 800, extended = true, antialias = true })
surface.CreateFont("GeminiAI_Small", { font = "Roboto", size = 14, weight = 500, extended = true, antialias = true })
surface.CreateFont("GeminiAI_Code",  { font = "Consolas", size = 15, weight = 500, extended = true, antialias = true })
surface.CreateFont("GeminiAI_Icon",  { font = "Roboto", size = 26, weight = 900, extended = true, antialias = true })

local gradR = Material("vgui/gradient-r")
local gradD = Material("vgui/gradient-d")

local function Escape(s)
	s = tostring(s or "")
	if markup.Escape then return markup.Escape(s) end
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function ColStr(c) return string.format("%d,%d,%d,%d", c.r, c.g, c.b, c.a or 255) end

local function Gradient(x, y, w, h, c1, c2)
	surface.SetDrawColor(c1)
	surface.DrawRect(x, y, w, h)
	surface.SetMaterial(gradR)
	surface.SetDrawColor(c2)
	surface.DrawTexturedRect(x, y, w, h)
end

local function Pulse(speed) return (math.sin(CurTime() * (speed or 3)) + 1) / 2 end

---------------------------------------------------------------------------
-- Стилизованная кнопка
---------------------------------------------------------------------------
local BTN = {}
function BTN:Init()
	self:SetText("")
	self.Label = ""
	self.Col = C.input
	self.Hover = 0
	self.Font = "GeminiAI_Small"
	self:SetCursor("hand")
end
function BTN:SetLabel(t) self.Label = t end
function BTN:SetColor(c) self.Col = c end
function BTN:Paint(w, h)
	self.Hover = Lerp(FrameTime() * 12, self.Hover, (self:IsHovered() and self:IsEnabled()) and 1 or 0)
	local c = self.Col
	local add = 25 * self.Hover
	draw.RoundedBox(6, 0, 0, w, h, Color(math.min(c.r + add, 255), math.min(c.g + add, 255), math.min(c.b + add, 255), self:IsEnabled() and (c.a or 255) or 90))
	draw.SimpleText(self.Label, self.Font, w / 2, h / 2, self:IsEnabled() and C.text or C.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end
vgui.Register("GeminiAI_Button", BTN, "DButton")

---------------------------------------------------------------------------
-- Одно сообщение (пузырь)
---------------------------------------------------------------------------
local MSG = {}
function MSG:Init()
	self:DockMargin(10, 6, 10, 6)
	self:Dock(TOP)
	self.Appear = 0
end

function MSG:SetMessage(msg)
	self.msg = msg
	msg.panels = msg.panels or {}
	msg.panels[self] = true

	if msg.code and msg.code ~= "" then
		self.Copy = vgui.Create("GeminiAI_Button", self)
		self.Copy:SetLabel("Копировать")
		self.Copy:SetSize(92, 20)
		self.Copy.DoClick = function()
			SetClipboardText(msg.code)
			self.Copy:SetLabel("Скопировано!")
			timer.Simple(1.5, function() if IsValid(self.Copy) then self.Copy:SetLabel("Копировать") end end)
		end

		self.Toggle = vgui.Create("GeminiAI_Button", self)
		self.Toggle:SetSize(80, 20)
		self.Toggle.DoClick = function()
			msg.collapsed = not msg.collapsed
			self:InvalidateLayout()
		end

		if msg.canRun then
			self.Run = vgui.Create("GeminiAI_Button", self)
			self.Run:SetSize(110, 20)
			self.Run:SetColor(Color(50, 120, 80))
			self.Run.DoClick = function()
				if msg.running then return end
				msg.running = true
				net.Start("GeminiAI_Run")
					net.WriteUInt(msg.id, 32)
				net.SendToServer()
				surface.PlaySound("buttons/button14.wav")
			end
		end
	end
	self:InvalidateLayout(true)
end

function MSG:PerformLayout(w)
	local msg = self.msg
	if not msg or w < 50 then return end

	local isUser = msg.role == "user"
	local maxW = math.floor(w * (isUser and 0.72 or 0.86))
	local textCol = msg.role == "error" and C.bad or C.text

	self.mk = markup.Parse("<font=GeminiAI_Text><colour=" .. ColStr(textCol) .. ">" .. Escape(msg.text) .. "</colour></font>", maxW - 28)
	self.bubbleW = math.min(maxW, self.mk:GetWidth() + 28)
	if not isUser and msg.code and msg.code ~= "" then self.bubbleW = maxW end
	self.bubbleH = self.mk:GetHeight() + 20

	local y = 20 + self.bubbleH
	self.codeMk, self.resMk = nil, nil

	if msg.code and msg.code ~= "" then
		y = y + 8
		self.codeY = y
		local codeText = msg.collapsed and (string.Explode("\n", msg.code)[1] .. " …") or msg.code
		codeText = string.Replace(codeText, "\t", "    ")
		self.codeMk = markup.Parse("<font=GeminiAI_Code><colour=" .. ColStr(Color(190, 220, 255)) .. ">" .. Escape(codeText) .. "</colour></font>", self.bubbleW - 24)
		self.codeH = 28 + self.codeMk:GetHeight() + 14
		y = y + self.codeH

		local bx = self.bubbleW - 6
		self.Copy:SetPos(bx - self.Copy:GetWide(), self.codeY + 4)
		bx = bx - self.Copy:GetWide() - 6
		self.Toggle:SetLabel(msg.collapsed and "Развернуть" or "Свернуть")
		self.Toggle:SetPos(bx - self.Toggle:GetWide(), self.codeY + 4)
		bx = bx - self.Toggle:GetWide() - 6
		if IsValid(self.Run) then
			self.Run:SetLabel(msg.running and "Выполняю…" or (msg.result and "Повторить" or "Выполнить"))
			self.Run:SetEnabled(not msg.running)
			self.Run:SetPos(bx - self.Run:GetWide(), self.codeY + 4)
		end
	end

	if msg.result then
		y = y + 6
		self.resY = y
		local col = msg.resultOk and C.good or C.bad
		self.resMk = markup.Parse("<font=GeminiAI_Small><colour=" .. ColStr(col) .. ">" .. Escape((msg.resultOk and "Успех: " or "") .. msg.result) .. "</colour></font>", self.bubbleW - 28)
		self.resH = self.resMk:GetHeight() + 12
		y = y + self.resH
	end

	if self:GetTall() ~= y then self:SetTall(y) end
end

function MSG:Paint(w, h)
	local msg = self.msg
	if not msg or not self.mk then return end

	self.Appear = Lerp(FrameTime() * 10, self.Appear, 1)
	local isUser = msg.role == "user"
	local bx = isUser and (w - self.bubbleW) or 0
	local slide = (1 - self.Appear) * 20 * (isUser and 1 or -1)
	bx = bx + slide

	-- Имя и время
	local name = isUser and LocalPlayer():Nick() or (msg.role == "error" and "Gemini AI • ошибка" or "Gemini AI")
	local stamp = os.date("%H:%M", msg.time or os.time())
	if isUser then
		draw.SimpleText(stamp .. "  •  " .. name, "GeminiAI_Small", w, 9, C.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	else
		draw.RoundedBox(4, 0, 2, 14, 14, msg.role == "error" and C.bad or C.accent)
		draw.SimpleText(name .. "  •  " .. stamp, "GeminiAI_Small", 20, 9, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	-- Пузырь
	if isUser then
		draw.RoundedBox(10, bx, 20, self.bubbleW, self.bubbleH, C.user)
		local x, y = self:LocalToScreen(bx, 20)
		render.SetScissorRect(x + 8, y, x + self.bubbleW - 8, y + self.bubbleH, true)
			surface.SetMaterial(gradR)
			surface.SetDrawColor(C.user2.r, C.user2.g, C.user2.b, 160)
			surface.DrawTexturedRect(bx, 20, self.bubbleW, self.bubbleH)
		render.SetScissorRect(0, 0, 0, 0, false)
	else
		draw.RoundedBox(10, bx, 20, self.bubbleW, self.bubbleH, msg.role == "error" and Color(60, 25, 30) or C.ai)
		draw.RoundedBox(2, bx, 26, 3, self.bubbleH - 12, msg.role == "error" and C.bad or C.accent)
	end
	self.mk:Draw(bx + 14, 30)

	-- Блок кода
	if self.codeMk then
		local cy = self.codeY
		draw.RoundedBox(8, bx, cy, self.bubbleW, self.codeH, C.code)
		draw.RoundedBoxEx(8, bx, cy, self.bubbleW, 28, C.codeHead, true, true, false, false)
		draw.SimpleText("GLua", "GeminiAI_Bold", bx + 12, cy + 14, C.accent2, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		local lines = select(2, string.gsub(msg.code, "\n", "")) + 1
		draw.SimpleText(lines .. " стр.", "GeminiAI_Small", bx + 56, cy + 14, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		self.codeMk:Draw(bx + 12, cy + 34)
	end

	-- Результат выполнения
	if self.resMk then
		local col = msg.resultOk and C.good or C.bad
		draw.RoundedBox(6, bx, self.resY, self.bubbleW, self.resH, Color(col.r, col.g, col.b, 22))
		self.resMk:Draw(bx + 14, self.resY + 6)
	end
end
vgui.Register("GeminiAI_Message", MSG, "DPanel")

---------------------------------------------------------------------------
-- Главная панель чата (используется и в окне, и во вкладке меню спавна)
---------------------------------------------------------------------------
local SUGGESTIONS = {
	{ "Поставь 5 бочек", "Поставь передо мной 5 взрывающихся бочек в ряд" },
	{ "Армия комбайнов", "Создай отряд из 4 комбайнов с автоматами вон там, куда я смотрю" },
	{ "Дай оружие", "Выдай мне пистолет, дробовик, RPG и патроны к ним" },
	{ "Построй дом", "Построй небольшой домик из пропов там, куда я смотрю" },
	{ "Низкая гравитация", "Сделай низкую гравитацию на 30 секунд, потом верни обратно" },
	{ "Вылечи меня", "Восстанови мне 100 здоровья и 100 брони" },
}

local CHAT = {}

function CHAT:Init()
	self:DockPadding(0, 0, 0, 0)

	-- Шапка
	self.Header = vgui.Create("DPanel", self)
	self.Header:Dock(TOP)
	self.Header:SetTall(56)
	self.Header.Paint = function(_, w, h)
		draw.RoundedBoxEx(10, 0, 0, w, h, C.header, true, true, false, false)
		Gradient(0, h - 2, w, 2, C.accent, C.accent2)

		-- Логотип
		local p = Pulse(2)
		draw.RoundedBox(10, 12, 10, 36, 36, C.accent)
		surface.SetMaterial(gradD)
		surface.SetDrawColor(C.accent2.r, C.accent2.g, C.accent2.b, 120 + p * 100)
		surface.DrawTexturedRect(12, 10, 36, 36)
		draw.SimpleText("AI", "GeminiAI_Icon", 30, 28, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		draw.SimpleText("Gemini AI", "GeminiAI_Title", 58, 18, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

		local status, col
		if not GeminiAI.KeySet then
			status, col = "нет API-ключа — настройте в Q → Утилиты → Gemini AI", C.warn
		elseif GeminiAI.Thinking then
			status, col = "думает" .. string.rep(".", math.floor(CurTime() * 3) % 4), C.accent2
		else
			status, col = "онлайн • " .. GetConVarString("gemini_ai_model"), C.good
		end
		draw.RoundedBox(4, 58, 33, 8, 8, col)
		draw.SimpleText(status, "GeminiAI_Small", 72, 37, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	self.Close = vgui.Create("GeminiAI_Button", self.Header)
	self.Close:SetLabel("X")
	self.Close:SetFont("GeminiAI_Bold")
	self.Close.Font = "GeminiAI_Bold"
	self.Close:SetSize(32, 32)
	self.Close:SetVisible(false)

	self.Clear = vgui.Create("GeminiAI_Button", self.Header)
	self.Clear:SetLabel("Новый диалог")
	self.Clear:SetSize(110, 32)
	self.Clear.DoClick = function()
		Derma_Query("Очистить переписку и память ИИ?", "Gemini AI", "Да", function()
			GeminiAI.Messages = {}
			net.Start("GeminiAI_Reset") net.SendToServer()
			hook.Run("GeminiAI_Rebuild")
		end, "Отмена")
	end

	self.Header.PerformLayout = function(_, w, h)
		local x = w - 12
		if self.Close:IsVisible() then
			self.Close:SetPos(x - 32, 12)
			x = x - 32 - 8
		end
		self.Clear:SetPos(x - self.Clear:GetWide(), 12)
	end

	-- Поле ввода
	self.Bottom = vgui.Create("DPanel", self)
	self.Bottom:Dock(BOTTOM)
	self.Bottom:SetTall(96)
	self.Bottom:DockPadding(12, 6, 12, 12)
	self.Bottom.Paint = function(_, w, h)
		draw.RoundedBoxEx(10, 0, 0, w, h, C.header, false, false, true, true)
		surface.SetDrawColor(C.border)
		surface.DrawRect(0, 0, w, 1)
	end

	self.Chips = vgui.Create("DHorizontalScroller", self.Bottom)
	self.Chips:Dock(TOP)
	self.Chips:SetTall(30)
	self.Chips:SetOverlap(-6)
	for _, s in ipairs(SUGGESTIONS) do
		local chip = vgui.Create("GeminiAI_Button")
		chip:SetLabel(s[1])
		surface.SetFont("GeminiAI_Small")
		chip:SetSize(surface.GetTextSize(s[1]) + 24, 26)
		chip:SetColor(Color(40, 42, 62))
		chip.DoClick = function() self:Send(s[2]) end
		self.Chips:AddPanel(chip)
	end

	local row = vgui.Create("DPanel", self.Bottom)
	row:Dock(FILL)
	row:DockMargin(0, 6, 0, 0)
	row.Paint = nil

	self.SendBtn = vgui.Create("DButton", row)
	self.SendBtn:Dock(RIGHT)
	self.SendBtn:SetWide(90)
	self.SendBtn:DockMargin(8, 0, 0, 0)
	self.SendBtn:SetText("")
	self.SendBtn.Paint = function(btn, w, h)
		local busy = GeminiAI.Thinking
		btn.h = Lerp(FrameTime() * 12, btn.h or 0, btn:IsHovered() and 1 or 0)
		draw.RoundedBox(8, 0, 0, w, h, busy and C.input or C.accent)
		if not busy then
			local x, y = btn:LocalToScreen(0, 0)
			render.SetScissorRect(x + 4, y, x + w - 4, y + h, true)
				surface.SetMaterial(gradR)
				surface.SetDrawColor(C.accent2.r, C.accent2.g, C.accent2.b, 120 + btn.h * 120)
				surface.DrawTexturedRect(0, 0, w, h)
			render.SetScissorRect(0, 0, 0, 0, false)
		end
		draw.SimpleText(busy and "…" or "Отправить", "GeminiAI_Bold", w / 2, h / 2, busy and C.dim or color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	self.SendBtn.DoClick = function() self:Send(self.Entry:GetValue()) end

	self.Entry = vgui.Create("DTextEntry", row)
	self.Entry:Dock(FILL)
	self.Entry:SetFont("GeminiAI_Text")
	self.Entry:SetPlaceholderText("Напишите, что сделать… например «заспавни 3 зомби рядом со мной»")
	self.Entry:SetPlaceholderColor(C.dim)
	self.Entry:SetTextColor(C.text)
	self.Entry:SetCursorColor(C.accent2)
	self.Entry:SetHighlightColor(Color(C.accent.r, C.accent.g, C.accent.b, 120))
	self.Entry:SetPaintBackground(false)
	self.Entry:SetUpdateOnType(true)
	self.Entry:SetHistoryEnabled(true)
	self.Entry.OnEnter = function(e)
		self:Send(e:GetValue())
		timer.Simple(0, function() if IsValid(e) then e:RequestFocus() end end)
	end
	self.Entry.Paint = function(e, w, h)
		draw.RoundedBox(8, 0, 0, w, h, C.input)
		if e:HasFocus() then
			surface.SetDrawColor(C.accent.r, C.accent.g, C.accent.b, 160)
			surface.DrawOutlinedRect(0, 0, w, h, 1)
		end
		e:DrawTextEntryText(C.text, Color(C.accent.r, C.accent.g, C.accent.b, 120), C.accent2)
		if e:GetValue() == "" and not e:HasFocus() then
			draw.SimpleText(e:GetPlaceholderText(), "GeminiAI_Text", 6, h / 2, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end

	-- Лента сообщений
	self.Scroll = vgui.Create("DScrollPanel", self)
	self.Scroll:Dock(FILL)
	self.Scroll:DockMargin(0, 4, 0, 4)
	local bar = self.Scroll:GetVBar()
	bar:SetWide(8)
	bar:SetHideButtons(true)
	bar.Paint = function(_, w, h) draw.RoundedBox(4, 2, 0, w - 4, h, Color(255, 255, 255, 6)) end
	bar.btnGrip.Paint = function(g, w, h) draw.RoundedBox(4, 2, 0, w - 4, h, g:IsHovered() and C.accent or Color(255, 255, 255, 40)) end

	self:Rebuild()

	GeminiAI.ChatPanels = GeminiAI.ChatPanels or {}
	for i = #GeminiAI.ChatPanels, 1, -1 do
		if not IsValid(GeminiAI.ChatPanels[i]) then table.remove(GeminiAI.ChatPanels, i) end
	end
	table.insert(GeminiAI.ChatPanels, self)

	hook.Add("GeminiAI_NewMessage", self, function(pnl, msg) pnl:AddMessage(msg, true) end)
	hook.Add("GeminiAI_Rebuild", self, function(pnl) pnl:Rebuild() end)
	hook.Add("GeminiAI_UpdateMessage", self, function(pnl, msg)
		for p in pairs(msg.panels or {}) do if IsValid(p) then p:InvalidateLayout() end end
		pnl:ScrollDown()
	end)
end

function CHAT:SetCloseFunc(fn)
	self.Close:SetVisible(true)
	self.Close.DoClick = fn
	self.Header:InvalidateLayout()
end

function CHAT:Rebuild()
	self.Scroll:Clear()
	self.Typing = nil

	if #GeminiAI.Messages == 0 then
		local welcome = vgui.Create("DPanel", self.Scroll)
		welcome:Dock(TOP)
		welcome:SetTall(150)
		welcome:DockMargin(10, 16, 10, 6)
		welcome.Paint = function(_, w, h)
			draw.SimpleText("Привет! Я — ИИ внутри Garry's Mod.", "GeminiAI_Title", w / 2, 40, C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText("Попросите меня что-нибудь сделать — я напишу GLua-код и выполню его на сервере.", "GeminiAI_Text", w / 2, 76, C.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText("Всё, что я создам, можно отменить клавишей Z.", "GeminiAI_Text", w / 2, 100, C.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			Gradient(w / 2 - 80, 128, 160, 2, C.accent, C.accent2)
		end
		self.Welcome = welcome
	end

	for _, msg in ipairs(GeminiAI.Messages) do self:AddMessage(msg, false) end
	self:UpdateTyping()
	self:ScrollDown(true)
end

function CHAT:AddMessage(msg, animate)
	if IsValid(self.Welcome) then self.Welcome:Remove() end
	local p = vgui.Create("GeminiAI_Message", self.Scroll)
	p:SetMessage(msg)
	if not animate then p.Appear = 1 end
	self:UpdateTyping()
	self:ScrollDown()
end

function CHAT:UpdateTyping()
	if IsValid(self.Typing) then self.Typing:Remove() end
	if not GeminiAI.Thinking then return end

	local t = vgui.Create("DPanel", self.Scroll)
	t:Dock(TOP)
	t:SetTall(44)
	t:DockMargin(10, 4, 10, 6)
	t.Paint = function(_, w, h)
		draw.RoundedBox(10, 0, 4, 84, 36, C.ai)
		for i = 0, 2 do
			local a = (math.sin(CurTime() * 6 - i * 0.8) + 1) / 2
			draw.RoundedBox(5, 18 + i * 18, 17 - a * 4, 10, 10, Color(C.accent.r, C.accent.g + a * 60, C.accent.b, 120 + a * 135))
		end
	end
	self.Typing = t
	self:ScrollDown()
end

function CHAT:ScrollDown(instant)
	timer.Simple(0.05, function()
		if not IsValid(self) then return end
		self.Scroll:InvalidateLayout(true)
		local bar = self.Scroll:GetVBar()
		if instant then bar:SetScroll(bar.CanvasSize) else bar:AnimateTo(bar.CanvasSize, 0.25, 0, 0.3) end
	end)
end

function CHAT:Send(text)
	text = string.Trim(text or "")
	if text == "" or GeminiAI.Thinking then return end
	self.Entry:AddHistory(text)
	self.Entry:SetText("")
	GeminiAI.SendMessage(text)
end

function CHAT:Paint(w, h)
	draw.RoundedBox(10, 0, 0, w, h, C.bg)
end

hook.Add("GeminiAI_Thinking", "GeminiAI_UpdateTyping", function()
	for _, pnl in ipairs(GeminiAI.ChatPanels or {}) do
		if IsValid(pnl) then pnl:UpdateTyping() end
	end
end)

vgui.Register("GeminiAI_Chat", CHAT, "DPanel")

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
function GeminiAI.OpenMenu()
	if IsValid(GeminiAI.Frame) then
		GeminiAI.Frame:MakePopup()
		GeminiAI.Frame.Chat.Entry:RequestFocus()
		return
	end

	local w, h = math.min(ScrW() - 40, 820), math.min(ScrH() - 40, 640)
	local f = vgui.Create("DFrame")
	f:SetSize(w, h)
	f:Center()
	f:SetTitle("")
	f:ShowCloseButton(false)
	f:SetDraggable(true)
	f:SetSizable(true)
	f:SetMinWidth(480)
	f:SetMinHeight(380)
	f:DockPadding(0, 0, 0, 0)
	f:MakePopup()
	f:SetAlpha(0)
	f:AlphaTo(255, 0.15)
	f.Paint = function(_, pw, ph)
		DisableClipping(true)
		for i = 1, 4 do draw.RoundedBox(12 + i, -i * 2, -i * 2, pw + i * 4, ph + i * 4, Color(0, 0, 0, 30)) end
		DisableClipping(false)
	end

	local chat = vgui.Create("GeminiAI_Chat", f)
	chat:Dock(FILL)
	chat:SetCloseFunc(function()
		f:AlphaTo(0, 0.12, 0, function() if IsValid(f) then f:Remove() end end)
	end)
	-- Перетаскивание окна за шапку
	chat.Header.OnMousePressed = function() f.Dragging = { gui.MouseX() - f.x, gui.MouseY() - f.y } f:MouseCapture(true) end
	chat.Header.OnMouseReleased = function() f.Dragging = nil f:MouseCapture(false) end
	f.Chat = chat

	f.OnKeyCodePressed = function(_, key) if key == KEY_ESCAPE then f:Remove() end end
	timer.Simple(0.05, function() if IsValid(chat) then chat.Entry:RequestFocus() end end)

	GeminiAI.Frame = f
end

concommand.Add("gemini_ai_menu", GeminiAI.OpenMenu, nil, "Открыть чат Gemini AI")

---------------------------------------------------------------------------
-- Отправка / приём
---------------------------------------------------------------------------
function GeminiAI.AddMessage(msg)
	msg.time = msg.time or os.time()
	table.insert(GeminiAI.Messages, msg)
	while #GeminiAI.Messages > 150 do table.remove(GeminiAI.Messages, 1) end
	hook.Run("GeminiAI_NewMessage", msg)
end

function GeminiAI.SendMessage(text)
	GeminiAI.AddMessage({ role = "user", text = text })
	net.Start("GeminiAI_Ask")
		net.WriteString(text)
	net.SendToServer()
	surface.PlaySound("ui/buttonclick.wav")
end

net.Receive("GeminiAI_Status", function()
	GeminiAI.Thinking = net.ReadBool()
	hook.Run("GeminiAI_Thinking", GeminiAI.Thinking)
end)

net.Receive("GeminiAI_Reply", function()
	local ok = net.ReadBool()
	local text = net.ReadString()
	local code = net.ReadString()
	local id = net.ReadUInt(32)
	local canRun = net.ReadBool()
	local msg = { role = ok and "ai" or "error", text = text, code = code, id = id, canRun = canRun }
	if net.ReadBool() then
		msg.resultOk = net.ReadBool()
		msg.result = net.ReadString()
	end
	if msg.text == "" then msg.text = msg.code ~= "" and "Готово!" or "…" end

	GeminiAI.Thinking = false
	hook.Run("GeminiAI_Thinking", false)
	GeminiAI.AddMessage(msg)
	surface.PlaySound(ok and "buttons/blip1.wav" or "buttons/button10.wav")

	-- Если окно закрыто — дублируем ответ в обычный чат
	if not IsValid(GeminiAI.Frame) then
		chat.AddText(C.accent, "[Gemini AI] ", ok and C.text or C.bad, text)
		if msg.result then chat.AddText(msg.resultOk and C.good or C.bad, "  " .. string.Explode("\n", msg.result)[1]) end
	end
end)

net.Receive("GeminiAI_RunResult", function()
	local id, ok, result = net.ReadUInt(32), net.ReadBool(), net.ReadString()
	for i = #GeminiAI.Messages, 1, -1 do
		local m = GeminiAI.Messages[i]
		if m.id == id then
			m.running, m.resultOk, m.result = false, ok, result
			hook.Run("GeminiAI_UpdateMessage", m)
			break
		end
	end
	surface.PlaySound(ok and "buttons/button9.wav" or "buttons/button10.wav")
end)

net.Receive("GeminiAI_Notify", function()
	local text, isError = net.ReadString(), net.ReadBool()
	chat.AddText(C.accent, "[Gemini AI] ", isError and C.bad or C.text, text)
end)

net.Receive("GeminiAI_Open", GeminiAI.OpenMenu)

net.Receive("GeminiAI_KeyState", function() GeminiAI.KeySet = net.ReadBool() end)

---------------------------------------------------------------------------
-- Вкладка «Gemini AI» в меню спавна (Q)
---------------------------------------------------------------------------
spawnmenu.AddCreationTab("Gemini AI", function()
	local base = vgui.Create("DPanel")
	base:DockPadding(8, 8, 8, 8)
	base.Paint = nil
	local chat = vgui.Create("GeminiAI_Chat", base)
	chat:Dock(FILL)
	return base
end, "icon16/comments.png", 60, "Чат с ИИ Gemini, который управляет сервером")
