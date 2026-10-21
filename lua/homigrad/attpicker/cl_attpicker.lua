-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_attpicker.lua
hg.AttPicker = hg.AttPicker or {}
local AP = hg.AttPicker

local colInstalled = Color(120, 200, 120)

local function InstalledSet(wep)
	local set = {}
	for _, att in pairs(wep:GetNetVar("attachments") or wep.attachments or {}) do
		if istable(att) and att[1] and att[1] ~= "empty" then set[att[1]] = true end
	end
	return set
end

local icons = {}
local function Icon(path)
	if not path then return end
	if icons[path] == nil then icons[path] = Material(path, "smooth mips") end
	return icons[path]
end

local function Fill(frame, scroll)
	local UI = hg.RemUI
	local U = UI.U
	scroll:Clear()

	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValid(wep) or not ishgweapon(wep) then
		frame:Close()
		return
	end

	local installed = InstalledSet(wep)
	local groups = AP.GetMountable(wep)

	if #groups == 0 then
		local empty = scroll:Add("DPanel")
		empty:Dock(TOP)
		empty:SetTall(U(40))
		empty.Paint = function(self, w, h)
			draw.SimpleText("No attachments fit this weapon.", "RemUI_Small", U(4), h / 2, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		return
	end

	for _, group in ipairs(groups) do
		local header = scroll:Add("DPanel")
		header:Dock(TOP)
		header:DockMargin(U(2), U(10), 0, U(6))
		header:SetTall(U(24))
		header.Paint = function(self, w, h)
			draw.SimpleText(group.name, "RemUI_Small", 0, h / 2, UI.White, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		for _, att in ipairs(group.list) do
			local has = installed[att]
			local name = hg.attachmentslaunguage[att] or language.GetPhrase(att)
			local icon = Icon(hg.attachmentsIcons[att])

			local row = scroll:Add("DButton")
			row:SetText("")
			row:Dock(TOP)
			row:DockMargin(0, 0, U(6), U(4))
			row:SetTall(U(44))
			row.Paint = function(self, w, h)
				UI.PaintCard(w, h, self:IsHovered() and UI.CardHover or UI.Card)

				local x = U(12)
				if icon then
					UI.DrawIcon(icon, x, (h - U(34)) / 2, U(34), color_white)
					x = x + U(44)
				end

				draw.SimpleText(name, "RemUI_Small", x, h / 2, has and colInstalled or UI.Text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				if has then draw.SimpleText("on the weapon", "RemUI_Tiny", w - U(12), h / 2, colInstalled, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER) end
				return true
			end
			row.OnCursorEntered = function() surface.PlaySound(UI.SoundHover) end

			row.DoClick = function()
				if has then return end
				surface.PlaySound(UI.SoundClick)
				net.Start("rem_attpicker_install")
					net.WriteString(att)
				net.SendToServer()
			end

			row.DoRightClick = function()
				if not has then return end
				surface.PlaySound(UI.SoundClick)
				RunConsoleCommand("ZB_AttachRemove", att)
			end
		end
	end
end

function AP.Open()
	if IsValid(AP.Frame) then AP.Frame:Remove() end

	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValid(wep) or not ishgweapon(wep) then return end

	local UI = hg.RemUI
	local frame = UI.Frame(ScrW() / 3, ScrH() * 0.6, "ATTACHMENTS  -  " .. string.upper(language.GetPhrase(wep.PrintName or "")), "LMB - put on the weapon  |  RMB - take off")
	AP.Frame = frame

	local scroll = vgui.Create("DScrollPanel", frame)
	scroll:Dock(FILL)
	UI.StyleScroll(scroll)

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
