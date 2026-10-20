-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_mutations.lua
hg.Mutations = hg.Mutations or {}
local M = hg.Mutations

local colYellow = Color(230, 190, 0)
local colOwned = Color(120, 120, 120)
local colBack = Color(15, 15, 15, 240)

surface.CreateFont("Rem_MutationTitle", {font = "Lora", size = ScreenScale(12), weight = 800, antialias = true, extended = true})
surface.CreateFont("Rem_MutationName", {font = "Lora", size = ScreenScale(9), weight = 700, antialias = true, extended = true})
surface.CreateFont("Rem_MutationDesc", {font = "Lora", size = ScreenScale(6.5), weight = 400, antialias = true, extended = true})

local menu

local function OpenMenu(station)
	if IsValid(menu) then menu:Remove() end

	local ply = LocalPlayer()
	local owned = M.Get(ply)
	local slotsLeft = M.MaxSlots - table.Count(owned)

	local w, rowH = ScrW() * 0.4, ScrH() * 0.1
	menu = vgui.Create("DFrame")
	menu:SetTitle("")
	menu:SetSize(w, ScrH() * 0.1 + rowH * #M.List)
	menu:Center()
	menu:MakePopup()
	menu:ShowCloseButton(true)
	menu.Paint = function(self, pw, ph)
		draw.RoundedBox(0, 0, 0, pw, ph, colBack)
		draw.SimpleText("MUTATION STATION", "Rem_MutationTitle", pw / 2, ScrH() * 0.025, colYellow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("Slots left: " .. slotsLeft .. " / " .. M.MaxSlots, "Rem_MutationDesc", pw / 2, ScrH() * 0.06, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	for i, mutation in ipairs(M.List) do
		local has = owned[mutation.id]
		local available = not has and slotsLeft > 0

		local button = vgui.Create("DButton", menu)
		button:SetText("")
		button:SetPos(ScrW() * 0.01, ScrH() * 0.08 + (i - 1) * rowH)
		button:SetSize(w - ScrW() * 0.02, rowH - ScrH() * 0.01)
		button:SetEnabled(available)
		button.Paint = function(self, bw, bh)
			local hovered = available and self:IsHovered()
			draw.RoundedBox(0, 0, 0, bw, bh, hovered and Color(60, 50, 0, 255) or Color(30, 30, 30, 255))
			draw.SimpleText(mutation.name .. (has and "  (installed)" or ""), "Rem_MutationName", bw * 0.03, bh * 0.3, has and colOwned or colYellow, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(mutation.desc, "Rem_MutationDesc", bw * 0.03, bh * 0.7, has and colOwned or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
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
	OpenMenu(net.ReadEntity())
end)
