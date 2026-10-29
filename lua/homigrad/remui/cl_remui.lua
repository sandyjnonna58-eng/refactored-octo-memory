-- Общий стиль моих меню (навыки, мутации, обвесы) - как главное меню (cl_menu_wd.lua): шрифт Share Tech Mono,
-- тёмные плашки, под мышью синяя плашка. Остальные файлы берут hg.RemUI только во время отрисовки.
hg.RemUI = hg.RemUI or {}
local UI = hg.RemUI

UI.SoundHover = "ui/rem_hover.wav"
UI.SoundClick = "ui/rem_click.wav"
UI.SoundSelect = "ui/rem_select.wav"

UI.White = Color(255, 255, 255, 240)
UI.Text = Color(225, 225, 225)
UI.TextDim = Color(160, 160, 160)
UI.Dim = Color(60, 60, 60, 180)
UI.Accent = Color(0, 0, 255)
UI.Background = Color(10, 10, 10, 225)
UI.Card = Color(22, 22, 22, 215)
UI.CardStrong = Color(14, 14, 14, 225)
UI.CardHover = Color(0, 0, 255, 200)
UI.Line = Color(255, 255, 255, 25)


function UI.U(num)
	return math.floor(num * math.min(ScrW(), ScrH()) / 1000)
end
local U = UI.U

local function CreateFonts()
	local scale = math.min(ScrW(), ScrH()) / 1000
	local font = "Share Tech Mono"

	surface.CreateFont("RemUI_Title", {font = font, size = math.max(18, math.floor(34 * scale)), weight = 300, extended = true})
	surface.CreateFont("RemUI_Medium", {font = font, size = math.max(16, math.floor(26 * scale)), weight = 300, extended = true})
	surface.CreateFont("RemUI_Small", {font = font, size = math.max(14, math.floor(20 * scale)), weight = 300, extended = true})
	surface.CreateFont("RemUI_Tiny", {font = font, size = math.max(12, math.floor(16 * scale)), weight = 300, extended = true})
end

hook.Add("OnScreenSizeChanged", "RemUI_Fonts", CreateFonts)
CreateFonts()

-- фон как у разделов главного меню: внутри меню - ровное затемнение поверх его фона,
-- отдельное окно поверх игры - сплошная тёмная плашка
function UI.PaintBackground(panel, w, h)
	local inMenu = IsValid(MainMenu) and IsValid(panel) and panel:HasParent(MainMenu)
	if inMenu and hg.WDMenu and hg.WDMenu.PaintBackdrop then
		hg.WDMenu.PaintBackdrop(w, h)
	else
		surface.SetDrawColor(UI.Background)
		surface.DrawRect(0, 0, w, h)
	end
end

-- карточка: тёмная подложка и тонкая линия снизу
function UI.PaintCard(w, h, col)
	surface.SetDrawColor(col or UI.Card)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(UI.Line)
	surface.DrawRect(0, h - U(1), w, U(1))
end

-- текст печатается по буквам, недопечатанное закрыто "#", как в меню
function UI.Typewriter(text, startTime, speed)
	local shown = math.floor((CurTime() - startTime) * (speed or 30))
	if shown >= #text then return text end

	return string.sub(text, 1, math.max(shown, 0)) .. string.rep("#", #text - math.max(shown, 0))
end

function UI.StyleScroll(scroll)
	scroll.Paint = function() end

	local bar = scroll:GetVBar()
	bar:SetWide(U(4))
	bar:SetHideButtons(true)
	bar.Paint = function(self, w, h)
		surface.SetDrawColor(0, 0, 0, 80)
		surface.DrawRect(0, 0, w, h)
	end
	bar.btnGrip.Paint = function(self, w, h)
		draw.RoundedBox(2, 1, 1, w - 2, h - 2, self:IsHovered() and UI.Accent or UI.Dim)
	end
end

-- текстовая кнопка: подчёркивание при наведении, тусклая, если нельзя нажать.
-- opts: font, color (или функция), center, getLabel(), canClick(), onClick(), onRightClick()
function UI.TextButton(parent, text, opts)
	opts = opts or {}

	local btn = vgui.Create("DButton", parent)
	btn:SetText("")
	btn.Label = text
	btn.Font = opts.font or "RemUI_Small"
	btn.HoverLerp = 0
	btn.OpenTime = CurTime()

	surface.SetFont(btn.Font)
	local tw, th = surface.GetTextSize(text)
	btn:SetSize(tw + U(8), th + U(8))

	function btn:SetLabel(label)
		self.Label = label
	end

	btn.Think = function(self)
		if opts.getLabel then self.Label = opts.getLabel() end

		local can = not opts.canClick or opts.canClick()
		local hovered = self:IsHovered() and can

		if hovered and not self.WasHovered then surface.PlaySound(UI.SoundHover) end
		self.WasHovered = hovered
		self.HoverLerp = LerpFT(0.2, self.HoverLerp, hovered and 1 or 0)
	end

	btn.Paint = function(self, w, h)
		local can = not opts.canClick or opts.canClick()
		local col = can and (isfunction(opts.color) and opts.color() or opts.color or UI.Text) or UI.TextDim
		local label = UI.Typewriter(self.Label, self.OpenTime)

		surface.SetFont(self.Font)
		local lw, lh = surface.GetTextSize(label)
		local x = opts.center and (w - lw) / 2 or U(4)

		-- под мышью синяя плашка (как выбранный пункт главного меню), текст белый
		if self.HoverLerp > 0.01 then
			surface.SetDrawColor(UI.Accent.r, UI.Accent.g, UI.Accent.b, 255 * self.HoverLerp)
			surface.DrawRect(0, 0, w * self.HoverLerp, h)
		end
		if self.HoverLerp > 0.5 then col = UI.White end
		draw.SimpleTextOutlined(label, self.Font, x, h / 2, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)

		return true
	end

	btn.DoClick = function()
		if opts.canClick and not opts.canClick() then return end
		surface.PlaySound(UI.SoundClick)
		if opts.onClick then opts.onClick() end
	end

	btn.DoRightClick = function()
		if not opts.onRightClick then return end
		surface.PlaySound(UI.SoundClick)
		opts.onRightClick()
	end

	return btn
end

-- окно поверх игры: заголовок с линией, закрытие на "x"
function UI.Frame(w, h, title, hint)
	local frame = vgui.Create("DFrame")
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetSize(w, h)
	frame:Center()
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.OpenTime = CurTime()
	frame.Hint = hint
	frame:DockPadding(U(14), U(64), U(14), U(14))
	frame.Paint = function(self, pw, ph)
		UI.PaintBackground(self, pw, ph)
		UI.PaintCard(pw, U(54), UI.CardStrong)
		draw.SimpleText(UI.Typewriter(title, self.OpenTime), "RemUI_Small", U(14), U(20), UI.White, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		if self.Hint then draw.SimpleText(self.Hint, "RemUI_Tiny", U(14), U(38), UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER) end
	end

	surface.PlaySound(UI.SoundSelect)

	local close = UI.TextButton(frame, "x", {font = "RemUI_Medium", onClick = function() frame:Close() end})
	close:SetPos(w - close:GetWide() - U(10), U(10))

	return frame
end

-- иконка, перекрашенная в нужный цвет
function UI.DrawIcon(mat, x, y, size, col)
	if not mat or mat:IsError() then return end
	surface.SetDrawColor(col or UI.White)
	surface.SetMaterial(mat)
	surface.DrawTexturedRect(x, y, size, size)
end
