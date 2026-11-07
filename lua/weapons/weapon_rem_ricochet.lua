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
	local res = Base.FireBullet(self)
	-- обычная пуля тоже красная: красный след от глаз до попадания (тот же луч, что у рикошета)
	if SERVER and IsValid(owner) and owner:IsPlayer() then
		local start = owner:EyePos()
		local tr = util.TraceLine({start = start, endpos = start + owner:GetAimVector() * 8000, filter = owner, mask = MASK_SHOT})
		net.Start("rem_ricochet")
			net.WriteUInt(2, 6)
			net.WriteVector(start + owner:GetAimVector() * 30)
			net.WriteVector(tr.HitPos)
			net.WriteFloat(0.02)
		net.Broadcast()
	end
	return res
end

if CLIENT then
	-- раскрутка видна: крутим кость барабана той модели, что рисуется (c_357 - и от первого, и от третьего лица);
	-- ось - rem_rr_spin_axis (p/y/r), если на модели барабан крутится "не туда"
	local cvAxis = CreateClientConVar("rem_rr_spin_axis", "r", true, false, "Ricochet revolver: drum spin axis p/y/r")
	local function CylinderBone(wm)
		if wm.remCyl ~= nil then return wm.remCyl or nil end
		wm.remCyl = false
		for i = 0, wm:GetBoneCount() - 1 do
			local n = string.lower(wm:GetBoneName(i) or "")
			if (string.find(n, "cylinder", 1, true) or string.find(n, "drum", 1, true)) and not string.find(n, "release", 1, true) then
				wm.remCyl = i
				break
			end
		end
		return wm.remCyl or nil
	end

	hook.Add("Think", "rem_ricochet_spin_anim", function()
		for _, wep in ipairs(ents.FindByClass("weapon_rem_ricochet")) do
			local wm = wep.GetWM and wep:GetWM()
			local bone = IsValid(wm) and CylinderBone(wm)
			if bone then
				local f = wep:SpinFrac()
				-- скорость: от 0 до ~3 оборотов в секунду; отпустил - барабан останавливается на ближайшей каморе
				wep.remCylAng = wep.remCylAng or 0
				if f > 0 then
					wep.remCylAng = (wep.remCylAng + FrameTime() * f * f * 1080) % 360
				else
					local target = math.Round(wep.remCylAng / 60) * 60
					wep.remCylAng = math.Approach(wep.remCylAng, target, FrameTime() * 240) % 360
				end
				local a, axis = wep.remCylAng, cvAxis:GetString()
				wm:ManipulateBoneAngles(bone, axis == "p" and Angle(a, 0, 0) or axis == "y" and Angle(0, a, 0) or Angle(0, 0, a))
			end
		end
	end)

	-- 6 красных кружков под прицелом - патроны в барабане: выстрел гасит один, перезарядка - снова все 6
	hook.Add("HUDPaint", "rem_ricochet_rounds", function()
		local ply = LocalPlayer()
		local wep = IsValid(ply) and ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "weapon_rem_ricochet" then return end
		local n = math.Clamp(wep:Clip1(), 0, 6)
		local r, gap = 6, 17
		local x0, y = ScrW() / 2 - gap * 2.5, ScrH() / 2 + 58
		draw.NoTexture()
		for i = 1, 6 do
			local x = x0 + (i - 1) * gap
			surface.SetDrawColor(30, 0, 0, 200)
			draw.Circle(x, y, r + 2, 16)
			if i <= n then
				surface.SetDrawColor(235, 25, 25, 255)
				draw.Circle(x, y, r, 16)
			else
				surface.SetDrawColor(90, 10, 10, 160)
				draw.Circle(x, y, r * 0.45, 12)
			end
		end
	end)

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

-- круг для HUD (если в проекте ещё нет)
if CLIENT and not draw.Circle then
	function draw.Circle(x, y, radius, seg)
		local cir = {}
		for i = 0, seg do
			local a = math.rad((i / seg) * -360)
			cir[#cir + 1] = {x = x + math.sin(a) * radius, y = y + math.cos(a) * radius}
		end
		surface.DrawPoly(cir)
	end
end
