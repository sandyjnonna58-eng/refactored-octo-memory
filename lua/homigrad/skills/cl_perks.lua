-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_skills.lua
hg.Skills = hg.Skills or {}
local SK = hg.Skills

local hint_dist = 75


local stealFinish = 0
local stealStart = 0

net.Receive("rem_pickpocket", function()
	stealFinish = net.ReadFloat()
	stealStart = CurTime()
end)

local function HintTarget(ply)
	if not SK.HasPerk or not SK.HasPerk(ply, "pickpocket") or not ply:Alive() or not ply:Crouching() then return end

	local tr = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * hint_dist,
		filter = ply,
	})

	local target = tr.Entity
	if IsValid(target) and target:IsPlayer() and target:Alive() and SK.IsBehind(ply, target) then return target end
end

hook.Add("HUDPaint", "rem_pickpocket", function()
	local UI = hg.RemUI
	if not UI then return end

	local U = UI.U
	local ply = LocalPlayer()
	local x, y = ScrW() / 2, ScrH() * 0.6

	if stealFinish > CurTime() then
		local w = ScrW() * 0.15
		local frac = math.Clamp((CurTime() - stealStart) / math.max(stealFinish - stealStart, 0.01), 0, 1)

		draw.SimpleTextOutlined("stealing...", "RemUI_Small", x, y - U(16), UI.Text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
		surface.SetDrawColor(UI.Dim)
		surface.DrawRect(x - w / 2, y, w, math.max(2, U(3)))
		surface.SetDrawColor(UI.White)
		surface.DrawRect(x - w / 2, y, w * frac, math.max(2, U(3)))
		return
	end

	if HintTarget(ply) then
		draw.SimpleTextOutlined("[E] pickpocket", "RemUI_Small", x, y, UI.TextDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
	end
end)
