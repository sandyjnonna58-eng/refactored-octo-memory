-- cl_ грузится раньше sh_ (по алфавиту), таблицу заполнит sh_skills.lua
hg.Skills = hg.Skills or {}
local SK = hg.Skills

local hint_dist = 75

local colPerk = Color(230, 190, 0)
local colBack = Color(0, 0, 0, 200)

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
	local ply = LocalPlayer()
	local x, y = ScrW() / 2, ScrH() * 0.6

	if stealFinish > CurTime() then
		local w, h = ScrW() * 0.15, ScrH() * 0.012
		local frac = math.Clamp((CurTime() - stealStart) / math.max(stealFinish - stealStart, 0.01), 0, 1)

		draw.SimpleText("Stealing...", "Rem_SkillDesc", x, y - h * 1.5, colPerk, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.RoundedBox(0, x - w / 2, y, w, h, colBack)
		draw.RoundedBox(0, x - w / 2, y, w * frac, h, colPerk)
		return
	end

	if HintTarget(ply) then
		draw.SimpleText("[E] Pickpocket", "Rem_SkillDesc", x, y, colPerk, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end)
