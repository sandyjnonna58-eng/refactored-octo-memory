-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_skills.lua; стиль - hg.RemUI (remui/cl_remui.lua)
hg.Skills = hg.Skills or {}
local SK = hg.Skills

local levelup_sound = "sound/rem_levelup.mp3"

local icons = {}
function SK.Icon(id)
	if icons[id] == nil then icons[id] = Material("rem_skills/" .. id .. ".png", "smooth mips") end
	return icons[id]
end

local function PerkState(ply, perk)
	local owned = SK.HasPerk(ply, perk.id)
	local points = ply:GetNWInt("skill_points", 0)
	local conflict = perk.conflicts and SK.HasPerk(ply, perk.conflicts)

	if perk.bad then
		if owned then return "Remove  -" .. perk.gain, points >= perk.gain end
		if conflict then return "Conflict", false end
		return "Take  +" .. perk.gain, SK.CountBadPerks(ply) < SK.MaxBadPerks
	end

	if owned then return "Owned", false end
	if conflict then return "Conflict", false end
	return "Buy  " .. perk.cost, points >= perk.cost
end

-- строка: иконка, название, описание; справа - что передали в addRight
local function Row(scroll, iconId, iconColor, getName, nameColor, desc, addRight)
	local UI = hg.RemUI
	local U = UI.U

	local row = scroll:Add("DPanel")
	row:Dock(TOP)
	row:DockMargin(0, 0, U(6), U(6))
	row:SetTall(U(64))
	row.Paint = function(self, w, h)
		local hovered = self:IsHovered() or self:IsChildHovered()
		UI.PaintCard(w, h, hovered and UI.CardHover or UI.Card)

		local size = U(38)
		UI.DrawIcon(SK.Icon(iconId), U(12), (h - size) / 2, size, isfunction(iconColor) and iconColor() or iconColor)

		draw.SimpleText(getName(), "RemUI_Small", U(62), h * 0.34, isfunction(nameColor) and nameColor() or nameColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(desc, "RemUI_Tiny", U(62), h * 0.7, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	addRight(row)
	return row
end

local function SkillRow(scroll, ply, skill)
	local UI = hg.RemUI
	local U = UI.U

	Row(scroll, skill.id, function() return SK.GetRank(ply, skill.id) > 0 and UI.White or UI.TextDim end,
		function() return skill.name .. "  -  " .. SK.RankNames[SK.GetRank(ply, skill.id)] end, UI.Text, skill.desc,
		function(row)
			local plus = UI.TextButton(row, "+", {
				font = "RemUI_Medium",
				center = true,
				canClick = function() return ply:GetNWInt("skill_points", 0) > 0 and SK.GetRank(ply, skill.id) < SK.MaxRank end,
				onClick = function()
					net.Start("rem_skills_upgrade")
						net.WriteString(skill.id)
					net.SendToServer()
				end,
			})
			plus:Dock(RIGHT)
			plus:DockMargin(0, U(12), U(10), U(12))
			plus:SetWide(U(40))

			local pips = vgui.Create("DPanel", row)
			pips:Dock(RIGHT)
			pips:SetWide(U(16) * SK.MaxRank)
			pips:SetMouseInputEnabled(false)
			pips.Paint = function(self, w, h)
				local rank, size = SK.GetRank(ply, skill.id), U(9)
				for r = 1, SK.MaxRank do
					local x, y = (r - 1) * U(16), (h - size) / 2
					if r <= rank then
						surface.SetDrawColor(UI.White)
						surface.DrawRect(x, y, size, size)
					else
						surface.SetDrawColor(UI.Dim)
						surface.DrawOutlinedRect(x, y, size, size, 1)
					end
				end
			end
		end)
end

local function PerkRow(scroll, ply, perk)
	local UI = hg.RemUI
	local U = UI.U

	local desc = perk.desc
	if perk.conflicts and SK.PerkByID[perk.conflicts] then desc = desc .. "  Not with " .. SK.PerkByID[perk.conflicts].name .. "." end

	local function iconColor()
		if perk.bad then return UI.Accent end
		return SK.HasPerk(ply, perk.id) and UI.White or UI.TextDim
	end

	Row(scroll, perk.id, iconColor, function() return perk.name .. (SK.HasPerk(ply, perk.id) and "  (yours)" or "") end,
		perk.bad and UI.Accent or UI.Text, desc,
		function(row)
			local btn = UI.TextButton(row, "Remove  -00", {
				center = true,
				color = perk.bad and UI.Accent or nil,
				getLabel = function() return (PerkState(ply, perk)) end,
				canClick = function() return select(2, PerkState(ply, perk)) end,
				onClick = function()
					net.Start("rem_skills_perk")
						net.WriteString(perk.id)
						net.WriteBool(perk.bad and SK.HasPerk(ply, perk.id) or false)
					net.SendToServer()
				end,
			})
			btn:Dock(RIGHT)
			btn:DockMargin(0, U(12), U(10), U(12))
			btn:SetWide(U(150))
		end)
end

local function Header(scroll, getText, col)
	local UI = hg.RemUI
	local U = UI.U

	local label = scroll:Add("DPanel")
	label:Dock(TOP)
	label:DockMargin(U(2), U(10), 0, U(6))
	label:SetTall(U(24))
	label.Paint = function(self, w, h)
		draw.SimpleText(getText(), "RemUI_Small", 0, h / 2, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
end

-- общая начинка: окно (!skills) и вкладка Skills в главном меню
function SK.BuildPanel(parent)
	local UI = hg.RemUI
	local U = UI.U
	local ply = LocalPlayer()
	SK.Tab = SK.Tab or "skills"

	local info = vgui.Create("DPanel", parent)
	info:Dock(TOP)
	info:SetTall(U(56))
	info.Paint = function(self, w, h)
		UI.PaintCard(w, h, UI.CardStrong)

		local level = ply:GetNWInt("skill_level", 0)
		local xp, need = ply:GetNWInt("skill_xp", 0), SK.XPForLevel(level)
		draw.SimpleText("Level " .. level, "RemUI_Medium", U(14), h * 0.36, UI.White, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(ply:GetNWInt("skill_points", 0) .. " skill points", "RemUI_Tiny", U(14), h * 0.74, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

		local barW, barX = w * 0.45, w - w * 0.45 - U(14)
		draw.SimpleText(xp .. " / " .. need .. " XP", "RemUI_Tiny", w - U(14), h * 0.36, UI.TextDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		surface.SetDrawColor(UI.Dim)
		surface.DrawRect(barX, h * 0.68, barW, math.max(2, U(3)))
		surface.SetDrawColor(UI.White)
		surface.DrawRect(barX, h * 0.68, barW * math.Clamp(xp / need, 0, 1), math.max(2, U(3)))
	end

	local tabs = vgui.Create("DPanel", parent)
	tabs:Dock(TOP)
	tabs:DockMargin(0, U(8), 0, U(8))
	tabs:SetTall(U(34))
	tabs.Paint = nil

	local scroll = vgui.Create("DScrollPanel", parent)
	scroll:Dock(FILL)
	UI.StyleScroll(scroll)

	local function Show(tab)
		SK.Tab = tab
		scroll:Clear()

		if tab == "perks" then
			Header(scroll, function() return "Perks  -  cost skill points" end, UI.White)
			for _, perk in ipairs(SK.Perks) do
				if not perk.bad then PerkRow(scroll, ply, perk) end
			end

			Header(scroll, function() return "Flaws  -  give skill points  (" .. SK.CountBadPerks(ply) .. " / " .. SK.MaxBadPerks .. ")" end, UI.Accent)
			for _, perk in ipairs(SK.Perks) do
				if perk.bad then PerkRow(scroll, ply, perk) end
			end
		else
			for _, skill in ipairs(SK.List) do SkillRow(scroll, ply, skill) end
		end
	end

	for _, tab in ipairs({{"skills", "Skills"}, {"perks", "Perks"}}) do
		local btn = UI.TextButton(tabs, tab[2], {
			font = "RemUI_Medium",
			color = function() return SK.Tab == tab[1] and UI.White or UI.TextDim end,
			onClick = function() Show(tab[1]) end,
		})
		btn:Dock(LEFT)
		btn:DockMargin(0, 0, U(18), 0)
		btn.PaintOver = function(self, w, h)
			if SK.Tab ~= tab[1] then return end
			surface.SetFont(self.Font)
			local lw, lh = surface.GetTextSize(self.Label)
			surface.SetDrawColor(UI.Accent)
			surface.DrawRect(U(4), h / 2 + lh / 2 + U(2), lw, math.max(1, U(2)))
		end
	end

	Show(SK.Tab)
end

function SK.Open()
	if IsValid(SK.Frame) then SK.Frame:Remove() end

	local UI = hg.RemUI
	local frame = UI.Frame(ScrW() * 0.45, ScrH() * 0.78, "SKILLS", "Spend points on skills, perks and flaws")
	SK.Frame = frame
	SK.BuildPanel(frame)
end

-- вкладка в главном меню (ESC); Return возвращает кнопки меню так же, как в Achievements
local function ReturnToMenu(ParentPanel)
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

	local UI = hg.RemUI
	local U = UI.U
	local openTime = CurTime()

	ParentPanel:SetAlpha(0)
	ParentPanel.Paint = function(self, w, h) UI.PaintBackground(self, w, h) end
	ParentPanel:AlphaTo(255, 0.15, 0)

	local header = vgui.Create("DPanel", ParentPanel)
	header:Dock(TOP)
	header:SetTall(U(70))
	header.Paint = function(self, w, h)
		draw.RoundedBox(0, 0, 0, w, h, UI.CardStrong)
		surface.SetDrawColor(255, 255, 255, 140)
		surface.DrawRect(0, h - U(1), w, U(1))
		draw.SimpleText(UI.Typewriter("SKILLS", openTime, 15), "RemUI_Title", U(25), U(18), UI.White)
	end

	local back = UI.TextButton(ParentPanel, "<- Return", {onClick = function() ReturnToMenu(ParentPanel) end})
	back:Dock(BOTTOM)
	back:DockMargin(U(15), U(2), 0, U(20))
	back:SetTall(U(42))

	local holder = vgui.Create("DPanel", ParentPanel)
	holder:Dock(FILL)
	holder:DockMargin(ScrW() * 0.2, U(22), ScrW() * 0.2, U(10))
	holder.Paint = nil

	SK.BuildPanel(holder)
end

net.Receive("rem_skills_open", function() SK.Open() end)
concommand.Add("hg_skills", function() SK.Open() end)

net.Receive("rem_skills_levelup", function()
	local level = net.ReadUInt(16)

	sound.PlayFile(levelup_sound, "noblock", function(chan)
		if IsValid(chan) then chan:Play() end
	end)

	if hg.CreateNotification then hg.CreateNotification("Level up! You are now level " .. level .. ". Spend your skill point (ESC - Skills).", 4, Color(225, 225, 225)) end
end)
