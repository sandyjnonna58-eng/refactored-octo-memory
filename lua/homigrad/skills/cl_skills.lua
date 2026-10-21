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

surface.CreateFont("Rem_SkillTitle", {font = "Lora", size = ScreenScale(11), weight = 800, antialias = true, extended = true})
surface.CreateFont("Rem_SkillName", {font = "Lora", size = ScreenScale(8), weight = 700, antialias = true, extended = true})
surface.CreateFont("Rem_SkillDesc", {font = "Lora", size = ScreenScale(6), weight = 400, antialias = true, extended = true})

function SK.Open()
	if IsValid(SK.Frame) then SK.Frame:Remove() end

	local ply = LocalPlayer()
	local w, rowH = ScrW() * 0.4, ScrH() * 0.085

	local frame = vgui.Create("DFrame")
	SK.Frame = frame
	frame:SetTitle("")
	frame:SetSize(w, ScrH() * 0.17 + rowH * #SK.List)
	frame:Center()
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.Paint = function(self, pw, ph)
		hg.DrawBlur(self)
		surface.SetDrawColor(colBack)
		surface.DrawRect(0, 0, pw, ph)
		surface.SetDrawColor(colOutline)
		surface.DrawOutlinedRect(0, 0, pw, ph, 1)

		local level = ply:GetNWInt("skill_level", 0)
		local xp, need = ply:GetNWInt("skill_xp", 0), SK.XPForLevel(level)
		draw.SimpleText("SKILLS - level " .. level, "Rem_SkillTitle", 14, ScrH() * 0.025, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText("Points: " .. ply:GetNWInt("skill_points", 0), "Rem_SkillName", pw - 50, ScrH() * 0.025, colBar, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

		local barY, barH = ScrH() * 0.05, ScrH() * 0.022
		draw.RoundedBox(0, 14, barY, pw - 28, barH, colBarBack)
		draw.RoundedBox(0, 14, barY, (pw - 28) * math.Clamp(xp / need, 0, 1), barH, colBar)
		draw.SimpleText(xp .. " / " .. need .. " XP", "Rem_SkillDesc", pw / 2, barY + barH / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	for i, skill in ipairs(SK.List) do
		local row = vgui.Create("DPanel", frame)
		row:SetPos(10, ScrH() * 0.09 + (i - 1) * rowH)
		row:SetSize(w - 20, rowH - ScrH() * 0.008)
		row.Paint = function(self, rw, rh)
			local rank = SK.GetRank(ply, skill.id)
			surface.SetDrawColor(colRow)
			surface.DrawRect(0, 0, rw, rh)
			surface.SetDrawColor(colOutline)
			surface.DrawOutlinedRect(0, 0, rw, rh, 1)

			draw.SimpleText(skill.name .. " - " .. SK.RankNames[rank], "Rem_SkillName", 10, rh * 0.3, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(skill.desc, "Rem_SkillDesc", 10, rh * 0.72, colOutline, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			local pip = rh * 0.22
			for r = 1, SK.MaxRank do
				draw.RoundedBox(2, rw - rh * 1.2 - (SK.MaxRank - r + 1) * (pip + 4), rh / 2 - pip / 2, pip, pip, r <= rank and colPip or colPipEmpty)
			end
		end

		local plus = vgui.Create("DButton", row)
		plus:Dock(RIGHT)
		plus:DockMargin(0, rowH * 0.18, rowH * 0.15, rowH * 0.18)
		plus:SetWide(rowH * 0.7)
		plus:SetText("+")
		plus:SetFont("Rem_SkillTitle")
		plus:SetTextColor(color_white)
		plus.Paint = function(self, bw, bh)
			local can = ply:GetNWInt("skill_points", 0) > 0 and SK.GetRank(ply, skill.id) < SK.MaxRank
			surface.SetDrawColor(can and (self:IsHovered() and colButtonHover or colButton) or colButtonOff)
			surface.DrawRect(0, 0, bw, bh)
			surface.SetDrawColor(colOutline)
			surface.DrawOutlinedRect(0, 0, bw, bh, 1)
		end
		plus.DoClick = function()
			net.Start("rem_skills_upgrade")
				net.WriteString(skill.id)
			net.SendToServer()
		end
	end
end

net.Receive("rem_skills_open", function() SK.Open() end)
concommand.Add("hg_skills", function() SK.Open() end)

net.Receive("rem_skills_levelup", function()
	local level = net.ReadUInt(16)

	sound.PlayFile(levelup_sound, "noblock", function(chan)
		if IsValid(chan) then chan:Play() end
	end)

	if hg.CreateNotification then hg.CreateNotification("Level up! You are now level " .. level .. ". Spend your skill point (!skills).", 4, Color(230, 190, 0)) end
end)

hook.Add("radialOptions", "rem_skills", function()
	hg.radialOptions[#hg.radialOptions + 1] = {function() SK.Open() end, "Skills"}
end)
