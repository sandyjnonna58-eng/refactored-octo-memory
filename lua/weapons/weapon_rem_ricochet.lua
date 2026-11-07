-- Красный рикошетный револьвер (свой, на базе Colt King Cobra из weapon_revolver357).
-- ЛКМ - обычный выстрел, чуть сильнее обычного пистолета (урон 30 против 23-25 у 9 мм).
-- ПКМ зажата - барабан раскручивается (SPIN_TIME); полностью раскручен + ЛКМ - рикошетная пуля вместо обычной:
--   отскакивает от стен под случайным углом; на каждом отскоке с шансом (25%, +5% за каждый отскок) летит прямо
--   в человека (не в того, кто стрелял); человека разрывает на части; после убийства летит дальше в сторону стены,
--   шанс снова 25%; пропадает после 17 отскоков или двух убийств.
-- Неполная раскрутка + ЛКМ - обычный выстрел. ПКМ отпущена - раскрутка сбрасывается.
SWEP.Base = "weapon_revolver357"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.PrintName = "Red Ricochet Revolver"
SWEP.Author = "remorseism"
SWEP.Instructions = "LMB - shot. Hold RMB to spin the drum; fully spun + LMB - ricochet bullet"
SWEP.Category = "Weapons - Pistols"

-- вся таблица целиком (как у weapon_revolver357), иначе поля базы могут не подтянуться
SWEP.Primary.ClipSize = 6
SWEP.Primary.DefaultClip = 6
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = ".357 Magnum"
SWEP.Primary.Cone = 0
SWEP.Primary.Damage = 30 -- обычный пистолет 9 мм - 23-25
SWEP.Primary.Spread = 0
SWEP.Primary.Force = 25
SWEP.Primary.Sound = {"homigrad/weapons/pistols/deagle-1.wav", 75, 105, 115}
SWEP.Primary.Wait = 0.2

local Base = baseclass.Get("weapon_revolver357")

local SPIN_TIME = 1.2
local R = {
	maxBounces = 17,
	maxKills = 2,
	chance = 0.25,      -- шанс полететь в человека на отскоке
	chanceAdd = 0.05,   -- + за каждый отскок
	range = 8000,
	gibForce = 6000,
	lethal = 1000,
	segmentTime = 0.035, -- для красоты: сколько "летит" один отрезок луча
}
SWEP.RicochetConfig = R

local RED = Color(210, 25, 25)

function SWEP:SpinFrac()
	return math.Clamp(self:GetNWFloat("rem_rr_spin", 0), 0, 1)
end

function SWEP:Think()
	if Base.Think then Base.Think(self) end
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return end

	-- раскрутка барабана: пока зажата ПКМ и есть патроны
	local spinning = owner:KeyDown(IN_ATTACK2) and self:Clip1() > 0 and not IsValid(owner.FakeRagdoll)
	if SERVER then
		local s = self:GetNWFloat("rem_rr_spin", 0)
		s = spinning and math.min(s + FrameTime() / SPIN_TIME, 1) or 0
		if s ~= self:GetNWFloat("rem_rr_spin", 0) then self:SetNWFloat("rem_rr_spin", s) end
		-- анимация: барабан крутится и разгоняется (drumroll только для вида, на патроны не влияет);
		-- после раскрутки доворачиваем до целого оборота, чтобы камора встала на место
		if s > 0 then
			if CurTime() >= (self.remSpinStepT or 0) then
				self.remSpinStepT = CurTime() + Lerp(s, 0.18, 0.035)
				self.remSpinSteps = (self.remSpinSteps or 0) + 1
				self:SetNWInt("drumroll", self:GetNWInt("drumroll", 0) + 1)
			end
		elseif (self.remSpinSteps or 0) > 0 then
			local rest = (6 - self.remSpinSteps % 6) % 6
			if rest > 0 then self:SetNWInt("drumroll", self:GetNWInt("drumroll", 0) + rest) end
			self.remSpinSteps = 0
		end
		if s >= 1 and not self.remSpunNotified then
			self.remSpunNotified = true
			self:EmitSound("buttons/button17.wav", 60, 140)
		elseif s < 1 then
			self.remSpunNotified = nil
		end
	end

	if CLIENT then
		-- красный корпус
		local wm = self.GetWM and self:GetWM()
		if IsValid(wm) and wm.remRed ~= true then
			wm.remRed = true
			wm:SetColor(RED)
		end
		-- звук раскрутки у себя
		if owner == LocalPlayer() then
			if spinning and self:SpinFrac() < 1 then
				if not self.remSpinSnd then
					self.remSpinSnd = CreateSound(self, "ambient/machines/spinup.wav")
					self.remSpinSnd:PlayEx(0.35, 90)
				end
				self.remSpinSnd:ChangePitch(90 + 80 * self:SpinFrac(), 0.1)
			elseif self.remSpinSnd then
				self.remSpinSnd:Stop()
				self.remSpinSnd = nil
			end
		end
	end
end

function SWEP:OnRemove()
	if self.remSpinSnd then self.remSpinSnd:Stop() end
	if Base.OnRemove then return Base.OnRemove(self) end
end

-- выстрел: полностью раскручен и ПКМ держится - рикошетная пуля, иначе обычная (патрон, звук и барабан - как у базы)
function SWEP:FireBullet()
	local owner = self:GetOwner()
	if IsValid(owner) and owner:IsPlayer() and owner:KeyDown(IN_ATTACK2) and self:SpinFrac() >= 1 then
		if SERVER then
			self:SetNWFloat("rem_rr_spin", 0)
			hg.RemRicochet.Fire(owner, self, owner:EyePos(), owner:GetAimVector())
		end
		return
	end
	return Base.FireBullet(self)
end

if CLIENT then
	-- полоска раскрутки под прицелом
	hook.Add("HUDPaint", "rem_ricochet_spin", function()
		local ply = LocalPlayer()
		local wep = IsValid(ply) and ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "weapon_rem_ricochet" then return end
		local f = wep:SpinFrac()
		if f <= 0 then return end
		local w, h = 90, 6
		local x, y = ScrW() / 2 - w / 2, ScrH() / 2 + 40
		surface.SetDrawColor(20, 0, 0, 180)
		surface.DrawRect(x - 1, y - 1, w + 2, h + 2)
		local full = f >= 1
		local pulse = full and (math.sin(CurTime() * 12) * 0.5 + 0.5) or 0
		surface.SetDrawColor(200 + 55 * pulse, 30 + 60 * pulse, 30, 230)
		surface.DrawRect(x, y, w * f, h)
	end)
end
