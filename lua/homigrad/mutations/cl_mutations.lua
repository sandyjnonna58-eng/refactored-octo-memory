-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_mutations.lua
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

local colYellow = Color(230, 190, 0)

local menu

-- implantOnly: станцией пользуется человек, ему доступен только имплант управления
local function OpenMenu(station, implantOnly)
	if IsValid(menu) then menu:Remove() end

	local UI = hg.RemUI
	local U = UI.U
	local ply = LocalPlayer()
	local owned = M.Get(ply)
	local list, subtitle

	if implantOnly then
		list = {M.Implant}
		owned = {[M.Implant.id] = M.HasImplant(ply) or nil}
		subtitle = "Human detected. Only the control implant is available."
	else
		list = M.List
		subtitle = "Slots left: " .. (M.MaxSlots - table.Count(owned)) .. " / " .. M.MaxSlots
	end

	local slotsFull = not implantOnly and table.Count(owned) >= M.MaxSlots
	local rowH = U(64)
	menu = UI.Frame(ScrW() * 0.42, math.min(U(64) + U(28) + (rowH + U(6)) * #list, ScrH() * 0.85), "MUTATION STATION", subtitle)

	local scroll = vgui.Create("DScrollPanel", menu)
	scroll:Dock(FILL)
	UI.StyleScroll(scroll)

	for _, mutation in ipairs(list) do
		local has = owned[mutation.id]
		local available = not has and not slotsFull

		local row = scroll:Add("DButton")
		row:SetText("")
		row:Dock(TOP)
		row:DockMargin(0, 0, U(6), U(6))
		row:SetTall(rowH)
		row.Paint = function(self, w, h)
			UI.PaintCard(w, h, available and self:IsHovered() and UI.CardHover or UI.Card)

			local nameCol = has and UI.TextDim or (available and colYellow or UI.TextDim)
			draw.SimpleText(mutation.name .. (has and "  (installed)" or ""), "RemUI_Small", U(14), h * 0.34, nameCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(mutation.desc, "RemUI_Tiny", U(14), h * 0.7, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			if self:IsHovered() and available then
				surface.SetDrawColor(colYellow)
				surface.DrawRect(0, 0, U(2), h)
			end
			return true
		end
		row.OnCursorEntered = function()
			if available then surface.PlaySound(UI.SoundHover) end
		end
		row.DoClick = function()
			if not available then return end
			surface.PlaySound(UI.SoundClick)

			net.Start("rem_mutation_install")
				net.WriteEntity(station)
				net.WriteString(mutation.id)
			net.SendToServer()
			menu:Remove()
		end
	end
end

net.Receive("rem_mutation_menu", function()
	local station = net.ReadEntity()
	OpenMenu(station, net.ReadBool())
end)

-- имплант управления: меню на Q
local function SendCommand(cmd, target)
	net.Start("rem_control_command")
		net.WriteString(cmd)
		net.WriteEntity(target or NULL)
	net.SendToServer()
end

local function OpenTargetMenu(target)
	local options = {}
	for _, cmd in ipairs({"shock", "paralyze", "terminate"}) do
		options[#options + 1] = {function() SendCommand(cmd, target) end, M.Commands[cmd].name}
	end

	hg.CreateRadialMenu(options)
end

-- ник игрока не должен случайно совпасть с иконкой жеста или фразы
local matTarget = Material("radialmenu_rem/user.png", "smooth mips")

local function OpenControlMenu()
	local ply = LocalPlayer()
	local options = {{function() SendCommand("locate") end, M.Commands.locate.name}}

	for _, target in player.Iterator() do
		if target ~= ply and M.IsExperiment(target) and ply:GetPos():Distance(target:GetPos()) <= M.ControlRange then
			options[#options + 1] = {function()
				OpenTargetMenu(target)
				return -1
			end, target:Nick(), nil, nil, matTarget}
		end
	end

	hg.CreateRadialMenu(options)
end

hook.Add("radialOptions", "rem_control_implant", function()
	local ply = LocalPlayer()
	if not M.HasImplant(ply) then return end

	hg.radialOptions[#hg.radialOptions + 1] = {function()
		OpenControlMenu()
		return -1
	end, "Experiment\nControl"}
end)

-- Locate All: метки экспериментов на экране
local locate_time = 12
local markers = {}
local markersUntil = 0

net.Receive("rem_control_locate", function()
	markers = {}
	for i = 1, net.ReadUInt(8) do
		markers[i] = {pos = net.ReadVector(), name = net.ReadString()}
	end

	markersUntil = CurTime() + locate_time
	surface.PlaySound("buttons/blip1.wav")
end)

local colMarker = Color(192, 57, 43)

hook.Add("HUDPaint", "rem_control_locate", function()
	if CurTime() > markersUntil or not hg.RemUI then return end

	local U = hg.RemUI.U
	colMarker.a = math.Clamp((markersUntil - CurTime()) / 2, 0, 1) * 255

	for _, marker in ipairs(markers) do
		local screen = marker.pos:ToScreen()
		if screen.visible then
			local dist = math.Round(LocalPlayer():GetPos():Distance(marker.pos) / 52.5)
			draw.SimpleTextOutlined("+", "RemUI_Medium", screen.x, screen.y, colMarker, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
			draw.SimpleTextOutlined(marker.name .. "  " .. dist .. "m", "RemUI_Tiny", screen.x, screen.y + U(18), colMarker, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		end
	end
end)

-- Heightened Senses: живые люди рядом подсвечиваются сквозь стены
local senses_range_sqr = 700 * 700

hook.Add("PreDrawHalos", "rem_mutation_senses", function()
	local ply = LocalPlayer()
	if not M.CanUse(ply) or not M.Has(ply, "senses") then return end

	local found = {}
	local pos = ply:GetPos()
	for _, other in player.Iterator() do
		if other ~= ply and other:Alive() then
			local char = hg.GetCurrentCharacter(other)
			if IsValid(char) and char:GetPos():DistToSqr(pos) < senses_range_sqr then found[#found + 1] = char end
		end
	end

	if #found > 0 then halo.Add(found, colYellow, 1, 1, 1, true, true) end
end)
