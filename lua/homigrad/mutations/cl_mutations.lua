-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_mutations.lua
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

local colYellow = Color(230, 190, 0)
local colRed = Color(255, 120, 120)
local colOwned = Color(120, 120, 120)
local colBack = Color(15, 15, 15, 240)
local colRow = Color(30, 30, 30, 255)
local colRowHover = Color(60, 50, 0, 255)

surface.CreateFont("Rem_MutationTitle", {font = "Lora", size = ScreenScale(12), weight = 800, antialias = true, extended = true})
surface.CreateFont("Rem_MutationName", {font = "Lora", size = ScreenScale(9), weight = 700, antialias = true, extended = true})
surface.CreateFont("Rem_MutationDesc", {font = "Lora", size = ScreenScale(6.5), weight = 400, antialias = true, extended = true})

local menu

-- implantOnly: станцией пользуется человек, ему доступен только имплант управления
local function OpenMenu(station, implantOnly)
	if IsValid(menu) then menu:Remove() end

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
	local w, rowH = ScrW() * 0.42, ScrH() * 0.075
	menu = vgui.Create("DFrame")
	menu:SetTitle("")
	menu:SetSize(w, ScrH() * 0.1 + rowH * #list)
	menu:Center()
	menu:MakePopup()
	menu.Paint = function(self, pw, ph)
		draw.RoundedBox(0, 0, 0, pw, ph, colBack)
		draw.SimpleText("MUTATION STATION", "Rem_MutationTitle", pw / 2, ScrH() * 0.025, colYellow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(subtitle, "Rem_MutationDesc", pw / 2, ScrH() * 0.06, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	for i, mutation in ipairs(list) do
		local has = owned[mutation.id]
		local available = not has and not slotsFull

		local button = vgui.Create("DButton", menu)
		button:SetText("")
		button:SetPos(ScrW() * 0.01, ScrH() * 0.08 + (i - 1) * rowH)
		button:SetSize(w - ScrW() * 0.02, rowH - ScrH() * 0.008)
		button:SetEnabled(available)
		button.Paint = function(self, bw, bh)
			draw.RoundedBox(0, 0, 0, bw, bh, available and self:IsHovered() and colRowHover or colRow)
			draw.SimpleText(mutation.name .. (has and "  (installed)" or ""), "Rem_MutationName", bw * 0.03, bh * 0.3, has and colOwned or colYellow, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(mutation.desc, "Rem_MutationDesc", bw * 0.03, bh * 0.72, has and colOwned or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		button.DoClick = function()
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

local function OpenControlMenu()
	local ply = LocalPlayer()
	local options = {{function() SendCommand("locate") end, M.Commands.locate.name}}

	for _, target in player.Iterator() do
		if target ~= ply and M.IsExperiment(target) and ply:GetPos():Distance(target:GetPos()) <= M.ControlRange then
			options[#options + 1] = {function()
				OpenTargetMenu(target)
				return -1
			end, target:Nick()}
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

hook.Add("HUDPaint", "rem_control_locate", function()
	if CurTime() > markersUntil then return end

	colRed.a = math.Clamp((markersUntil - CurTime()) / 2, 0, 1) * 255

	for _, marker in ipairs(markers) do
		local screen = marker.pos:ToScreen()
		if screen.visible then
			local dist = math.Round(LocalPlayer():GetPos():Distance(marker.pos) / 52.5)
			draw.SimpleText("+", "Rem_MutationName", screen.x, screen.y, colRed, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(marker.name .. " - " .. dist .. "m", "Rem_MutationDesc", screen.x, screen.y + ScreenScale(8), colRed, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end

	colRed.a = 255
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
