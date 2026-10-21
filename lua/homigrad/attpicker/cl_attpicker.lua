-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_attpicker.lua
hg.AttPicker = hg.AttPicker or {}
local AP = hg.AttPicker

local colBack = Color(0, 0, 0, 240)
local colOutline = Color(255, 255, 255, 255)
local colRow = Color(20, 20, 20, 235)
local colRowHover = Color(40, 40, 40, 235)
local colInstalled = Color(40, 70, 40, 235)
local colInstalledHover = Color(55, 90, 55, 235)
local colHeader = Color(200, 200, 200)

local function InstalledSet(wep)
	local set = {}
	for _, att in pairs(wep:GetNetVar("attachments") or wep.attachments or {}) do
		if istable(att) and att[1] and att[1] ~= "empty" then set[att[1]] = true end
	end
	return set
end

local function PaintRow(self, w, h)
	local hovered = self:IsHovered()
	surface.SetDrawColor(self.installed and (hovered and colInstalledHover or colInstalled) or (hovered and colRowHover or colRow))
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(colOutline)
	surface.DrawOutlinedRect(0, 0, w, h, 1)
end

local function Fill(frame, scroll)
	scroll:Clear()

	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValid(wep) or not ishgweapon(wep) then
		frame:Close()
		return
	end

	local installed = InstalledSet(wep)
	local groups = AP.GetMountable(wep)

	if #groups == 0 then
		local label = scroll:Add("DLabel")
		label:SetText("No attachments fit this weapon.")
		label:SetFont("ZCity_Tiny")
		label:SetTextColor(colHeader)
		label:Dock(TOP)
		label:DockMargin(8, 8, 8, 0)
		return
	end

	for _, group in ipairs(groups) do
		local header = scroll:Add("DLabel")
		header:SetText(group.name)
		header:SetFont("ZCity_Menu_Settings_Small")
		header:SetTextColor(colHeader)
		header:Dock(TOP)
		header:DockMargin(8, 8, 8, 4)
		header:SetTall(ScreenScaleH(14))

		for _, att in ipairs(group.list) do
			local has = installed[att]

			local row = scroll:Add("DButton")
			row.installed = has
			row:SetText((hg.attachmentslaunguage[att] or language.GetPhrase(att)) .. (has and "  - on the weapon" or ""))
			row:SetFont("ZCity_Tiny")
			row:SetTextColor(color_white)
			row:Dock(TOP)
			row:DockMargin(6, 0, 6, 4)
			row:SetTall(ScreenScaleH(20))
			row.Paint = PaintRow

			local icon = hg.attachmentsIcons[att]
			if icon then
				local img = vgui.Create("DImage", row)
				img:SetSize(ScreenScaleH(20), ScreenScaleH(20))
				img:Dock(LEFT)
				img:DockMargin(5, 0, 0, 0)
				img:SetImage(icon)
			end

			row.DoClick = function()
				if has then return end
				net.Start("rem_attpicker_install")
					net.WriteString(att)
				net.SendToServer()
			end

			row.DoRightClick = function()
				if has then RunConsoleCommand("ZB_AttachRemove", att) end
			end
		end
	end
end

function AP.Open()
	if IsValid(AP.Frame) then AP.Frame:Remove() end

	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValid(wep) or not ishgweapon(wep) then return end

	local frame = vgui.Create("DFrame")
	AP.Frame = frame
	frame:SetTitle("")
	frame:SetSize(ScrW() / 3, ScrH() * 0.6)
	frame:Center()
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.Paint = function(self, w, h)
		hg.DrawBlur(self)
		surface.SetDrawColor(colBack)
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(colOutline)
		surface.DrawOutlinedRect(0, 0, w, h, 1)
		draw.SimpleText("choose attachments: " .. (wep.PrintName or ""), "ZCity_Menu_Settings_Small", 14, 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local hint = vgui.Create("DLabel", frame)
	hint:Dock(BOTTOM)
	hint:DockMargin(10, 0, 10, 8)
	hint:SetTall(ScreenScaleH(14))
	hint:SetText("")
	hint.Paint = function(self, w, h)
		draw.SimpleText("LMB - put on the weapon | RMB - take off", "ZCity_Tiny", w * 0.5, h * 0.5, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:Dock(FILL)
	scroll:DockMargin(4, 14, 4, 4)
	frame.scroll = scroll

	Fill(frame, scroll)
	frame.Refresh = function() if IsValid(scroll) then Fill(frame, scroll) end end
end

concommand.Add("hg_attachment_picker", function() AP.Open() end)

-- меню обновляется, когда обвесы на оружии меняются
hook.Add("OnNetVarSet", "rem_attpicker_refresh", function(index, key)
	if key ~= "attachments" or not IsValid(AP.Frame) then return end
	if Entity(index) ~= LocalPlayer():GetActiveWeapon() then return end

	timer.Simple(0, function()
		if IsValid(AP.Frame) then AP.Frame.Refresh() end
	end)
end)

hook.Add("radialOptions", "rem_attpicker", function()
	local ply = LocalPlayer()
	local org = ply.organism or {}
	if not ply:Alive() or org.otrub then return end

	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) or not ishgweapon(wep) or not istable(wep.availableAttachments) then return end

	hg.radialOptions[#hg.radialOptions + 1] = {function() AP.Open() end, "Choose\nAttachments"}
end)
