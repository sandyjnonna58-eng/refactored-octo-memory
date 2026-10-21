-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_skills.lua
hg.Skills = hg.Skills or {}
local SK = hg.Skills

local levelup_sound = "sound/rem_levelup.mp3"

local colBack = Color(0, 0, 0, 240)
local colOutline = Color(255, 255, 255, 255)
local colRow = Color(20, 20, 20, 235)
local colBar = Color(230, 190, 0)
local colBarBack = Color(50, 50, 50)
local colPip = Color(230, 190, 0)
local colPipEmpty = Color(60, 60, 60)
local colButton = Color(40, 70, 40, 235)
local colButtonHover = Color(60, 100, 60, 235)
local colButtonOff = Color(40, 40, 40, 235)
local colRowHover = Color(40, 40, 40, 235)

surface.CreateFont("Rem_SkillTitle", {font = "Lora", size = ScreenScale(11), weight = 800, antialias = true, extended = true})
surface.CreateFont("Rem_SkillName", {font = "Lora", size = ScreenScale(8), weight = 700, antialias = true, extended = true})
surface.CreateFont("Rem_SkillDesc", {font = "Lora", size = ScreenScale(6), weight = 400, antialias = true, extended = true})

local colTab = Color(30, 30, 30, 235)
local colTabActive = Color(60, 50, 0, 235)

local function PaintBox(self, w, h, col)
	surface.SetDrawColor(col)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(colOutline)
	surface.DrawOutlinedRect(0, 0, w, h, 1)
end

local function MakeButton(parent, text, canFn, onClick)
	local btn = vgui.Create("DButton", parent)
	btn:SetText(text)
	btn:SetFont("Rem_SkillName")
	btn:SetTextColor(color_white)
	btn.Paint = function(self, w, h)
		local can = canFn()
		PaintBox(self, w, h, can and (self:IsHovered() and colButtonHover or colButton) or colButtonOff)
	end
	btn.DoClick = function()
		if canFn() then onClick() end
	end

	return btn
end

local function SkillRow(scroll, ply, skill, rowH)
	local row = scroll:Add("DPanel")
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, ScrH() * 0.006)
	row:SetTall(rowH)
	row.Paint = function(self, rw, rh)
		local rank = SK.GetRank(ply, skill.id)
		PaintBox(self, rw, rh, colRow)

		draw.SimpleText(skill.name .. " - " .. SK.RankNames[rank], "Rem_SkillName", 10, rh * 0.3, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(skill.desc, "Rem_SkillDesc", 10, rh * 0.72, colOutline, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

		local pip = rh * 0.22
		for r = 1, SK.MaxRank do
			draw.RoundedBox(2, rw - rh * 1.2 - (SK.MaxRank - r + 1) * (pip + 4), rh / 2 - pip / 2, pip, pip, r <= rank and colPip or colPipEmpty)
		end
	end

	local plus = MakeButton(row, "+", function()
		return ply:GetNWInt("skill_points", 0) > 0 and SK.GetRank(ply, skill.id) < SK.MaxRank
	end, function()
		net.Start("rem_skills_upgrade")
			net.WriteString(skill.id)
		net.SendToServer()
	end)
	plus:SetFont("Rem_SkillTitle")
	plus:Dock(RIGHT)
	plus:DockMargin(0, rowH * 0.18, rowH * 0.15, rowH * 0.18)
	plus:SetWide(rowH * 0.7)
end

local colBad = Color(255, 120, 120)
local colBadButton = Color(90, 35, 35, 235)
local colBadButtonHover = Color(120, 50, 50, 235)

local function PerkState(ply, perk)
	local owned = SK.HasPerk(ply, perk.id)
	local points = ply:GetNWInt("skill_points", 0)
	local conflict = perk.conflicts and SK.HasPerk(ply, perk.conflicts) and SK.PerkByID[perk.conflicts]

	if perk.bad then
		if owned then return "Remove (-" .. perk.gain .. ")", points >= perk.gain end
		if conflict then return "Conflict", false end
		return "+" .. perk.gain .. " pts", SK.CountBadPerks(ply) < SK.MaxBadPerks
	end

	if owned then return "Owned", false end
	if conflict then return "Conflict", false end
	return perk.cost .. " pts", points >= perk.cost
end

local function PerkRow(scroll, ply, perk, rowH)
	local row = scroll:Add("DPanel")
	row:Dock(TOP)
	row:DockMargin(0, 0, 0, ScrH() * 0.006)
	row:SetTall(rowH)
	row.Paint = function(self, rw, rh)
		local owned = SK.HasPerk(ply, perk.id)
		PaintBox(self, rw, rh, colRow)

		local nameCol = perk.bad and colBad or (owned and colPip or color_white)
		local desc = perk.desc
		if perk.conflicts and SK.PerkByID[perk.conflicts] then desc = desc .. "  Not with " .. SK.PerkByID[perk.conflicts].name .. "." end

		draw.SimpleText(perk.name .. (owned and "  (yours)" or ""), "Rem_SkillName", 10, rh * 0.3, nameCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(desc, "Rem_SkillDesc", 10, rh * 0.72, colOutline, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local btn = vgui.Create("DButton", row)
	btn:SetFont("Rem_SkillName")
	btn:SetTextColor(color_white)
	btn:Dock(RIGHT)
	btn:DockMargin(0, rowH * 0.2, rowH * 0.15, rowH * 0.2)
	btn:SetWide(rowH * 2)
	btn.Think = function(self)
		local text = PerkState(ply, perk)
		if self:GetText() ~= text then self:SetText(text) end
	end
	btn.Paint = function(self, w, h)
		local _, can = PerkState(ply, perk)
		local on, hover = colButton, colButtonHover
		if perk.bad then on, hover = colBadButton, colBadButtonHover end
		PaintBox(self, w, h, can and (self:IsHovered() and hover or on) or colButtonOff)
	end
	btn.DoClick = function()
		local _, can = PerkState(ply, perk)
		if not can then return end

		net.Start("rem_skills_perk")
			net.WriteString(perk.id)
			net.WriteBool(perk.bad and SK.HasPerk(ply, perk.id) or false)
		net.SendToServer()
	end
end

local function PerkHeader(scroll, text, col)
	local label = scroll:Add("DLabel")
	label:Dock(TOP)
	label:DockMargin(4, ScrH() * 0.006, 0, ScrH() * 0.004)
	label:SetFont("Rem_SkillName")
	label:SetTextColor(col)
	label:SetText(text)
	label:SizeToContents()
	return label
end

-- общая начинка: окно на Q / !skills и вкладка Skills в главном меню
function SK.BuildPanel(parent)
	local ply = LocalPlayer()
	local rowH = ScrH() * 0.075
	SK.Tab = SK.Tab or "skills"

	local header = vgui.Create("DPanel", parent)
	header:Dock(TOP)
	header:SetTall(ScrH() * 0.085)
	header.Paint = function(self, pw, ph)
		local level = ply:GetNWInt("skill_level", 0)
		local xp, need = ply:GetNWInt("skill_xp", 0), SK.XPForLevel(level)
		draw.SimpleText("SKILLS - level " .. level, "Rem_SkillTitle", 4, ph * 0.25, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Points: " .. ply:GetNWInt("skill_points", 0), "Rem_SkillName", pw - 4, ph * 0.25, colBar, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

		local barY, barH = ph * 0.55, ph * 0.28
		draw.RoundedBox(0, 4, barY, pw - 8, barH, colBarBack)
		draw.RoundedBox(0, 4, barY, (pw - 8) * math.Clamp(xp / need, 0, 1), barH, colBar)
		draw.SimpleText(xp .. " / " .. need .. " XP", "Rem_SkillDesc", pw / 2, barY + barH / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local tabs = vgui.Create("DPanel", parent)
	tabs:Dock(TOP)
	tabs:DockMargin(0, ScrH() * 0.008, 0, ScrH() * 0.008)
	tabs:SetTall(ScrH() * 0.04)
	tabs.Paint = nil

	local scroll = vgui.Create("DScrollPanel", parent)
	scroll:Dock(FILL)

	local function Show(tab)
		SK.Tab = tab
		scroll:Clear()

		if tab == "perks" then
			PerkHeader(scroll, "Perks - cost skill points", colPip)
			for _, perk in ipairs(SK.Perks) do
				if not perk.bad then PerkRow(scroll, ply, perk, rowH) end
			end

			local badHeader = PerkHeader(scroll, "", colBad)
			badHeader.Think = function(self)
				local text = "Flaws - give skill points (" .. SK.CountBadPerks(ply) .. " / " .. SK.MaxBadPerks .. ")"
				if self:GetText() ~= text then self:SetText(text) self:SizeToContents() end
			end
			for _, perk in ipairs(SK.Perks) do
				if perk.bad then PerkRow(scroll, ply, perk, rowH) end
			end
		else
			for _, skill in ipairs(SK.List) do SkillRow(scroll, ply, skill, rowH) end
		end
	end

	for i, tab in ipairs({{"skills", "Skills"}, {"perks", "Perks"}}) do
		local btn = vgui.Create("DButton", tabs)
		btn:SetText(tab[2])
		btn:SetFont("Rem_SkillName")
		btn:SetTextColor(color_white)
		btn:Dock(LEFT)
		btn:DockMargin(0, 0, 6, 0)
		btn:SetWide(ScrW() * 0.08)
		btn.Paint = function(self, w, h)
			PaintBox(self, w, h, SK.Tab == tab[1] and colTabActive or (self:IsHovered() and colRowHover or colTab))
		end
		btn.DoClick = function() Show(tab[1]) end
	end

	Show(SK.Tab)
end

function SK.Open()
	if IsValid(SK.Frame) then SK.Frame:Remove() end

	local frame = vgui.Create("DFrame")
	SK.Frame = frame
	frame:SetTitle("")
	frame:SetSize(ScrW() * 0.42, ScrH() * 0.7)
	frame:Center()
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame:DockPadding(12, 26, 12, 12)
	frame.Paint = function(self, pw, ph)
		hg.DrawBlur(self)
		surface.SetDrawColor(colBack)
		surface.DrawRect(0, 0, pw, ph)
		surface.SetDrawColor(colOutline)
		surface.DrawOutlinedRect(0, 0, pw, ph, 1)
	end

	SK.BuildPanel(frame)
end

-- вкладка в главном меню (ESC); Return возвращает кнопки меню так же, как в Achievements
local function ReturnToMenu(ParentPanel)
	surface.PlaySound("ui/rem_select.wav")

	local luaMenu = ParentPanel:GetParent()
	ParentPanel:AlphaTo(0, 0.2, 0, function()
		if IsValid(ParentPanel) then ParentPanel:Remove() end
	end)
	if not IsValid(luaMenu) then return end

	for _, child in ipairs(luaMenu:GetChildren()) do
		if child ~= ParentPanel then
			child:SetVisible(true)
			child:AlphaTo(255, 0.2, 0)
		end
	end

	if luaMenu.panelparrent then
		luaMenu.panelparrent = vgui.Create("DPanel", luaMenu)
		luaMenu.panelparrent:SetPos(0, 0)
		luaMenu.panelparrent:SetSize(ScrW(), ScrH())
		luaMenu.panelparrent:MoveToFront()
		luaMenu.panelparrent:SetMouseInputEnabled(false)
		luaMenu.panelparrent.Paint = function() end
	end

	if luaMenu.ResetCurrentPanel then luaMenu:ResetCurrentPanel() end
end

function hg.DrawSkillsMenu(ParentPanel)
	if not IsValid(ParentPanel) then return end

	ParentPanel:SetAlpha(0)
	ParentPanel.Paint = function(self, w, h)
		hg.DrawBlur(self, 5)
		surface.SetDrawColor(0, 0, 0, 200)
		surface.DrawRect(0, 0, w, h)
	end
	ParentPanel:AlphaTo(255, 0.25, 0)

	local holder = vgui.Create("DPanel", ParentPanel)
	holder:SetSize(ScrW() * 0.45, ScrH() * 0.78)
	holder:Center()
	holder:DockPadding(14, 14, 14, 14)
	holder.Paint = function(self, w, h)
		surface.SetDrawColor(colBack)
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(colOutline)
		surface.DrawOutlinedRect(0, 0, w, h, 1)
	end

	SK.BuildPanel(holder)

	local back = vgui.Create("DButton", ParentPanel)
	back:SetText("<- Return")
	back:SetFont("Rem_SkillTitle")
	back:SetTextColor(color_white)
	back:SizeToContents()
	back:SetPos(ScrW() * 0.03, ScrH() * 0.9)
	back.Paint = function(self, w, h)
		self:SetTextColor(self:IsHovered() and colBar or color_white)
	end
	back.DoClick = function() ReturnToMenu(ParentPanel) end
end

net.Receive("rem_skills_open", function() SK.Open() end)
concommand.Add("hg_skills", function() SK.Open() end)

net.Receive("rem_skills_levelup", function()
	local level = net.ReadUInt(16)

	sound.PlayFile(levelup_sound, "noblock", function(chan)
		if IsValid(chan) then chan:Play() end
	end)

	if hg.CreateNotification then hg.CreateNotification("Level up! You are now level " .. level .. ". Spend your skill point (!skills or ESC - Skills).", 4, Color(230, 190, 0)) end
end)

hook.Add("radialOptions", "rem_skills", function()
	hg.radialOptions[#hg.radialOptions + 1] = {function() SK.Open() end, "Skills"}
end)
