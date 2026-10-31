-- Пояс смертника: в руке пульт. ЛКМ - случайный крик (sound/rem_vest/jihad*), потом всегда звонок Nokia,
-- потом сильный взрыв через общую очередь взрывов (autorun/server/sv_rem_bombs.lua). Если хозяина убьют
-- раньше - пояс всё равно сработает там, где он лежит.
-- Сам пояс (шашки, изолента, детонатор с проводами, лямки) собран из простых фигур в коде и надет на грудь,
-- как бронежилеты (Spine2); иконка - tools/suicide_vest/vest.py с той же геометрией.
if SERVER then
	AddCSLuaFile()
	resource.AddSingleFile("materials/entities/weapon_suicidevest.png")
	resource.AddSingleFile("sound/rem_vest/jihad1.wav")
	resource.AddSingleFile("sound/rem_vest/jihad3.wav")
	resource.AddSingleFile("sound/rem_vest/nokia.mp3")
end

SWEP.Base = "weapon_base"
SWEP.PrintName = "Suicide Vest"
SWEP.Instructions = "Primary attack to detonate."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"

SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

SWEP.HoldType = "slam"
SWEP.ViewModel = ""
SWEP.WorldModel = "models/sirgibs/ragdoll/css/terror_arctic_radio.mdl"

if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_suicidevest.png")
	SWEP.IconOverride = "entities/weapon_suicidevest.png"
	SWEP.BounceWeaponIcon = false
end

SWEP.Weight = 0
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
SWEP.Slot = 5
SWEP.SlotPos = 6
SWEP.WorkWithFake = true
SWEP.offsetVec = Vector(6, 5.5, -41)
SWEP.offsetAng = Angle(180, 160, 180)

-- крик (длина в секундах), потом звонок, потом взрыв
SWEP.Shouts = {
	{"rem_vest/jihad1.wav", 1.0},
	{"rem_vest/jihad3.wav", 1.31},
}
SWEP.Ring = {"rem_vest/nokia.mp3", 1.07}
SWEP.BlastRadius = 700
SWEP.BlastDamage = 600

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
end

-- ===================== модель пояса =====================
-- оси как у бронежилетов на кости Spine2: x - вперёд (грудь), y - влево, z - вверх
local VEST_BONE = "ValveBiped.Bip01_Spine2"
local VEST_POS, VEST_ANG = Vector(-1, 2, 0), Angle(0, 90, 90)

if CLIENT then
	local RED, CAP, TAPE = Color(185, 38, 28), Color(214, 196, 160), Color(24, 24, 24)
	local BOX, LED, SCREEN = Color(38, 38, 40), Color(255, 30, 20), Color(60, 230, 90)
	local KHAKI = Color(98, 88, 62)
	local WIRES = {Color(220, 30, 30), Color(40, 80, 230), Color(230, 200, 40)}
	local LIGHT = Vector(0.45, 0.35, 0.82):GetNormalized()

	local verts
	-- свет запечён в цвет вершин: модель видна в любом освещении, а общую яркость берём из места на карте
	local function Quad(a, b, c, d, col, n)
		local k = 0.42 + 0.58 * math.max(0, n:Dot(LIGHT))
		local vc = Color(math.min(255, col.r * k), math.min(255, col.g * k), math.min(255, col.b * k))
		for _, p in ipairs({a, b, c, a, c, d}) do
			verts[#verts + 1] = {pos = p, normal = n, color = vc, u = 0, v = 0}
		end
	end

	local function Box(x0, y0, z0, x1, y1, z1, col)
		Quad(Vector(x1,y0,z0), Vector(x1,y1,z0), Vector(x1,y1,z1), Vector(x1,y0,z1), col, Vector(1,0,0))
		Quad(Vector(x0,y0,z0), Vector(x0,y0,z1), Vector(x0,y1,z1), Vector(x0,y1,z0), col, Vector(-1,0,0))
		Quad(Vector(x0,y1,z0), Vector(x0,y1,z1), Vector(x1,y1,z1), Vector(x1,y1,z0), col, Vector(0,1,0))
		Quad(Vector(x0,y0,z0), Vector(x1,y0,z0), Vector(x1,y0,z1), Vector(x0,y0,z1), col, Vector(0,-1,0))
		Quad(Vector(x0,y0,z1), Vector(x1,y0,z1), Vector(x1,y1,z1), Vector(x0,y1,z1), col, Vector(0,0,1))
		Quad(Vector(x0,y0,z0), Vector(x0,y1,z0), Vector(x1,y1,z0), Vector(x1,y0,z0), col, Vector(0,0,-1))
	end

	local function Cylinder(cx, cy, z0, z1, r, col, cap)
		local seg = 10
		for i = 0, seg - 1 do
			local a0, a1 = math.pi * 2 * i / seg, math.pi * 2 * (i + 1) / seg
			local p0 = Vector(cx + r * math.cos(a0), cy + r * math.sin(a0), 0)
			local p1 = Vector(cx + r * math.cos(a1), cy + r * math.sin(a1), 0)
			local am = (a0 + a1) / 2
			Quad(Vector(p0.x, p0.y, z0), Vector(p1.x, p1.y, z0), Vector(p1.x, p1.y, z1), Vector(p0.x, p0.y, z1), col, Vector(math.cos(am), math.sin(am), 0))
			Quad(Vector(cx, cy, z1), Vector(p0.x, p0.y, z1), Vector(p1.x, p1.y, z1), Vector(cx, cy, z1), cap, Vector(0, 0, 1))
			Quad(Vector(cx, cy, z0), Vector(p1.x, p1.y, z0), Vector(p0.x, p0.y, z0), Vector(cx, cy, z0), cap, Vector(0, 0, -1))
		end
	end

	-- брусок вдоль отрезка (провод, лямка)
	local function Segment(p1, p2, thick, col, width)
		local d = p2 - p1
		local f = d:GetNormalized()
		local side = f:Cross(Vector(1, 0, 0))
		if side:LengthSqr() < 1e-6 then side = f:Cross(Vector(0, 0, 1)) end
		side:Normalize()
		local up = side:Cross(f)
		local w, t = (width or thick) / 2, thick / 2
		local sx, ux = {-1, 1, 1, -1}, {-1, -1, 1, 1}
		local c, e = {}, {}
		for i = 1, 4 do
			c[i] = p1 + side * (sx[i] * w) + up * (ux[i] * t)
			e[i] = c[i] + d
		end
		for i = 1, 4 do
			local j = i % 4 + 1
			local n = (side * (sx[i] + sx[j]) + up * (ux[i] + ux[j])):GetNormalized()
			Quad(c[i], c[j], e[j], e[i], col, n)
		end
	end

	local function BuildVest(mat)
		verts = {}
		-- задняя панель и лямки через плечи
		Box(-7.4, -8.6, -3.6, -6.4, 8.6, 3.8, KHAKI)
		for _, y in ipairs({-4.6, 4.6}) do
			Segment(Vector(6.6, y, 4.2), Vector(2.0, y * 1.05, 11.6), 0.6, KHAKI, 2.2)
			Segment(Vector(2.0, y * 1.05, 11.6), Vector(-4.0, y * 1.05, 11.0), 0.6, KHAKI, 2.2)
			Segment(Vector(-4.0, y * 1.05, 11.0), Vector(-6.9, y, 3.8), 0.6, KHAKI, 2.2)
		end
		-- шашки: спереди 7, по бокам по 3
		for i = 0, 6 do
			Cylinder(7.4, -6.6 + i * 2.2, -4.6, 4.6, 1.05, RED, CAP)
		end
		for _, side in ipairs({-1, 1}) do
			for i = 0, 2 do
				Cylinder(4.6 - i * 3.3, side * 9.2, -4.4, 4.4, 1.05, RED, CAP)
			end
		end
		-- изолента
		for _, z in ipairs({-2.9, 2.6}) do
			Box(6.1, -7.9, z - 0.6, 8.6, 7.9, z + 0.6, TAPE)
			for _, side in ipairs({-1, 1}) do
				Box(-2.8, side * 9.2 - 1.25, z - 0.55, 5.8, side * 9.2 + 1.25, z + 0.55, TAPE)
			end
		end
		-- детонатор: коробка, огонёк, экранчик
		Box(8.4, -2.4, -1.6, 10.3, 2.4, 1.6, BOX)
		Box(10.3, 1.0, 0.5, 10.7, 1.6, 1.1, LED)
		Box(10.3, -1.8, -0.7, 10.5, 0.3, 0.5, SCREEN)
		-- провода от детонатора к шашкам
		local wires = {{-1.8, -5.5, 4.0}, {0.0, 0.4, 4.4}, {1.8, 5.7, 3.9}}
		for k, wdat in ipairs(wires) do
			local mid = Vector(10.0, (wdat[1] + wdat[2]) / 2, 3.2)
			Segment(Vector(10.2, wdat[1], 1.6), mid, 0.32, WIRES[k])
			Segment(mid, Vector(8.5, wdat[2], wdat[3]), 0.32, WIRES[k])
		end

		-- формат вершин берём у материала, которым рисуем (Mesh() без материала даёт формат без цвета -
		-- рисование читает мусор и роняет игру)
		local m = Mesh(mat)
		m:BuildFromTriangles(verts)
		verts = nil
		return m
	end

	local vestMesh, vestBroken
	local vestMat = CreateMaterial("rem_suicidevest", "UnlitGeneric", {["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1})

	local function DrawVest(pos, ang)
		if vestBroken then return end
		if not vestMesh then
			local ok, res = pcall(BuildVest, vestMat)
			if not ok or not res then
				vestBroken = true
				ErrorNoHalt("[suicide vest] model build failed: " .. tostring(res) .. "\n")
				return
			end
			vestMesh = res
		end
		-- яркость по освещению в этом месте карты (чтобы в темноте пояс не светился)
		local lc = render.GetLightColor(pos)
		local k = math.Clamp(0.3 + (lc.x + lc.y + lc.z) / 3 * 2.5, 0.3, 1.15)
		local m = Matrix()
		m:Translate(pos)
		m:Rotate(ang)
		render.SetColorModulation(k, k, k)
		render.SetMaterial(vestMat)
		cam.PushModelMatrix(m)
			vestMesh:Draw()
		cam.PopModelMatrix()
		render.SetColorModulation(1, 1, 1)
	end

	-- на груди у всех, у кого пояс (сервер ставит NW-флаг)
	hook.Add("PostDrawOpaqueRenderables", "rem_suicidevest", function(depth, skybox)
		if depth or skybox then return end
		for _, ply in player.Iterator() do
			if not ply:GetNWBool("rem_vest", false) then continue end
			local ent = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or ply
			if not IsValid(ent) then continue end
			-- свой пояс в виде от первого лица не рисуем, чтобы не лез в камеру
			if ent == LocalPlayer() and not LocalPlayer():ShouldDrawLocalPlayer() then continue end
			local bone = ent:LookupBone(VEST_BONE)
			local matrix = bone and ent:GetBoneMatrix(bone)
			if not matrix then continue end
			local pos, ang = LocalToWorld(VEST_POS, VEST_ANG, matrix:GetTranslation(), matrix:GetAngles())
			DrawVest(pos, ang)
		end
	end)

	SWEP.DrawVestAt = DrawVest
end

function SWEP:DrawWorldModel()
	-- на земле лежит сам пояс
	if not IsValid(self:GetOwner()) then
		self.DrawVestAt(self:GetPos() + self:GetUp() * 2, self:GetAngles() + Angle(90, 0, 0))
	end
end

function SWEP:DrawWorldModel2()
	self.model = IsValid(self.model) and self.model or ClientsideModel(self.WorldModel)
	local WorldModel = self.model
	local owner = hg.GetCurrentCharacter(self:GetOwner())

	WorldModel:SetNoDraw(true)

	if IsValid(owner) then
		local boneid = owner:LookupBone("ValveBiped.Bip01_L_Hand")
		if not boneid then return end
		local matrix = owner:GetBoneMatrix(boneid)
		if not matrix then return end

		local newPos, newAng = LocalToWorld(self.offsetVec, self.offsetAng, matrix:GetTranslation(), matrix:GetAngles())
		WorldModel:SetPos(newPos)
		WorldModel:SetAngles(newAng)
		WorldModel:SetupBones()
		WorldModel:DrawModel()
	else
		WorldModel:SetPos(self:GetPos())
		WorldModel:SetAngles(self:GetAngles())
		WorldModel:DrawModel()
	end
end

function SWEP:OnRemove()
	if CLIENT and IsValid(self.model) then self.model:Remove() end
end

function SWEP:SecondaryAttack() end
function SWEP:Reload() end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 10)
	if CLIENT then return end

	local owner = self:GetOwner()
	if not IsValid(owner) or self.Activated then return end
	self.Activated = true
	self:Detonate(owner)
end

if SERVER then
	-- у кого пояс - видно всем (рисует клиент, флаг меняется только когда меняется)
	timer.Create("rem_suicidevest_flag", 0.5, 0, function()
		for _, ply in player.Iterator() do
			ply:SetNWBool("rem_vest", ply:Alive() and ply:HasWeapon("weapon_suicidevest"))
		end
	end)

	-- где сейчас тело хозяина (живой, в рэгдолле или уже мёртвый)
	local function BodyOf(ply)
		local char = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply)
		if IsValid(char) then return char end
		local rag = ply:GetRagdollEntity()
		if IsValid(rag) then return rag end
		return ply
	end

	local function Explode(ply, pos, radius, damage)
		local profile = {
			Decal = "scorch_big",
			Trace = 400,
			Effect = "doi_stuka_explosion",
			EffectAir = "doi_stuka_explosion",
			EffectWater = "ins_water_explosion",
			Sound = "ied/ied_detonate_0" .. math.random(3) .. ".wav",
			FarSound = "ied/ied_detonate_dist_0" .. math.random(3) .. ".wav",
			WaterSound = "iedins/water/ied_water_detonate_01.wav",
			WaterFarSound = "iedins/water/ied_water_detonate_01.wav",
			Force = 60000,
			Lift = 25000,
		}
		if rem_QueueExplosion then
			rem_QueueExplosion({Pos = pos, Radius = radius, Damage = damage, Owner = ply, Profile = profile})
		else
			util.BlastDamage(game.GetWorld(), IsValid(ply) and ply or game.GetWorld(), pos, radius, damage)
		end

		-- сам смертник не выживает ни при какой броне
		timer.Simple(0.2, function()
			if IsValid(ply) and ply:Alive() then ply:Kill() end
		end)
	end

	function SWEP:Detonate(ply)
		local shout = self.Shouts[math.random(#self.Shouts)]
		local ring = self.Ring
		local radius, damage = self.BlastRadius, self.BlastDamage
		local lastPos = BodyOf(ply):WorldSpaceCenter()

		local function track()
			if not IsValid(ply) then return lastPos end
			local body = BodyOf(ply)
			if IsValid(body) then lastPos = body:WorldSpaceCenter() end
			return lastPos
		end

		-- крик
		BodyOf(ply):EmitSound(shout[1], 100, 100, 1, CHAN_VOICE)

		-- звонок Nokia - всегда перед взрывом
		timer.Simple(shout[2], function()
			local pos = track()
			local body = IsValid(ply) and BodyOf(ply)
			if IsValid(body) then
				body:EmitSound(ring[1], 95, 100, 1, CHAN_ITEM)
			else
				sound.Play(ring[1], pos, 95, 100, 1)
			end
		end)

		-- взрыв
		timer.Simple(shout[2] + ring[2], function()
			local pos = track()
			if IsValid(self) then self:Remove() end
			Explode(ply, pos, radius, damage)
		end)
	end
end
