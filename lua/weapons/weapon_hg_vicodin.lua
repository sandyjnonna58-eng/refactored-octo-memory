if SERVER then AddCSLuaFile() end
-- Викодин: обезболивающее без передозировки (действует через org.vicodin, см. sv_pain.lua)
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Vicodin"
SWEP.Instructions = "Prescription painkillers. Dulls the pain for a few minutes, you can't overdose on them. 3 pills.\nLMB to take one, RMB to give one to someone else."
SWEP.Category = "ZCity Medicine"
SWEP.Spawnable = true
SWEP.IconOverride = "entities/weapon_hg_vicodin.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_hg_vicodin.png")
end

local pills = 3

if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_vicodin.png") end

-- Своя модель: прозрачный оранжевый аптечный флакон с белой крышкой и этикеткой, внутри жёлтые таблетки.
-- Собрана из простых фигур в коде; иконка - tools/vicodin/bottle.py с той же геометрией.
-- Оси: начало координат - центр дна, z - вверх (как у флакона обычных таблеток, тот же хват в руке).
if CLIENT then
	local GLASS, SHINE = Color(248, 158, 30, 105), Color(255, 240, 210, 90)
	local CAP, LABEL, INK, STRIPE = Color(240, 240, 236), Color(246, 244, 236), Color(70, 70, 74), Color(200, 40, 40)
	local PILL_COLORS = {Color(252, 214, 52), Color(246, 188, 38), Color(250, 200, 60)}
	local LIGHT = Vector(0.45, -0.35, 0.82):GetNormalized()

	-- таблетки: центр, половина длины (направление), цвет - как на иконке
	local PILLS = {
		{-0.05, 0.11, 0.34, 0.45, 0.22, 0.02, 1}, {-0.03, 0.03, 0.30, 0.49, 0.12, -0.03, 2}, {0.07, 0.03, 0.28, 0.23, -0.44, -0.19, 3},
		{0.08, 0.49, 0.41, -0.44, -0.23, -0.05, 1}, {0.04, -0.01, 0.81, -0.12, 0.48, -0.18, 2}, {0.18, 0.17, 0.80, 0.21, 0.45, 0.04, 3},
		{-0.19, -0.23, 0.73, 0.46, 0.19, -0.22, 1}, {0.15, 0.52, 0.70, -0.20, 0.46, 0.04, 2}, {-0.23, 0.07, 1.21, -0.16, -0.47, -0.13, 3},
		{-0.38, -0.19, 1.23, -0.06, -0.50, -0.11, 1}, {0.09, -0.01, 1.12, 0.02, -0.50, -0.17, 2}, {-0.03, 0.00, 1.18, 0.05, -0.50, 0.04, 3},
		{0.18, -0.18, 1.61, -0.41, -0.28, 0.04, 1}, {-0.65, 0.18, 1.67, -0.49, 0.08, 0.08, 2}, {0.52, 0.21, 1.60, 0.50, -0.02, 0.16, 3},
		{-0.07, 0.30, 1.60, 0.49, 0.07, -0.02, 1}, {0.05, 0.08, 1.87, 0.06, -0.50, -0.19, 2}, {0.00, 0.31, 2.07, 0.44, 0.24, -0.03, 3},
		{-0.67, -0.22, 2.06, 0.33, -0.38, -0.11, 1}, {-0.25, 0.15, 2.07, 0.48, -0.13, -0.17, 2}, {0.08, 0.17, 2.34, -0.50, 0.05, 0.04, 3},
		{-0.00, 0.00, 2.38, -0.34, 0.37, 0.03, 1}, {0.53, -0.16, 2.40, -0.37, -0.34, 0.09, 2}, {0.68, 0.24, 2.47, 0.35, -0.35, 0.15, 3},
	}

	local verts
	-- свет запечён в цвет вершин, общая яркость - по освещению на карте
	local function Quad(a, b, c, d, col, n)
		local k = 0.45 + 0.55 * math.max(0, n:Dot(LIGHT))
		local vc = Color(math.min(255, col.r * k), math.min(255, col.g * k), math.min(255, col.b * k), col.a)
		for _, p in ipairs({a, b, c, a, c, d}) do
			verts[#verts + 1] = {pos = p, normal = n, color = vc, u = 0, v = 0}
		end
	end

	local function Cylinder(z0, z1, r, col, top, bottom, a0, a1, seg)
		a0, a1, seg = a0 or 0, a1 or 360, seg or 24
		for i = 0, seg - 1 do
			local u0, u1 = math.rad(a0 + (a1 - a0) * i / seg), math.rad(a0 + (a1 - a0) * (i + 1) / seg)
			local x0, y0, x1, y1 = r * math.cos(u0), r * math.sin(u0), r * math.cos(u1), r * math.sin(u1)
			local um = (u0 + u1) / 2
			Quad(Vector(x0, y0, z0), Vector(x1, y1, z0), Vector(x1, y1, z1), Vector(x0, y0, z1), col, Vector(math.cos(um), math.sin(um), 0))
			if top then Quad(Vector(0, 0, z1), Vector(x0, y0, z1), Vector(x1, y1, z1), Vector(0, 0, z1), top, Vector(0, 0, 1)) end
			if bottom then Quad(Vector(0, 0, z0), Vector(x1, y1, z0), Vector(x0, y0, z0), Vector(0, 0, z0), bottom, Vector(0, 0, -1)) end
		end
	end

	-- брусок вдоль отрезка (таблетка-капсула)
	local function Segment(p1, p2, thick, col, width)
		local d = p2 - p1
		local f = d:GetNormalized()
		local side = f:Cross(Vector(0, 0, 1))
		if side:LengthSqr() < 1e-6 then side = f:Cross(Vector(1, 0, 0)) end
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
			Quad(c[i], c[j], e[j], e[i], col, (side * (sx[i] + sx[j]) + up * (ux[i] + ux[j])):GetNormalized())
		end
		Quad(c[1], c[4], c[3], c[2], col, -f)
		Quad(e[1], e[2], e[3], e[4], col, f)
	end

	-- формат вершин берём у материала, которым рисуем (Mesh() без материала даёт формат без цвета -
	-- рисование читает мусор и роняет игру)
	local function Finish(mat)
		local m = Mesh(mat)
		m:BuildFromTriangles(verts)
		verts = nil
		return m
	end

	-- непрозрачное (таблетки, этикетка, крышка) и прозрачный пластик - отдельно, пластик рисуется вторым
	local function BuildBottle(solidMat, glassMat)
		verts = {}
		for _, pill in ipairs(PILLS) do
			local c, d = Vector(pill[1], pill[2], pill[3]), Vector(pill[4], pill[5], pill[6])
			Segment(c - d, c + d, 0.42, PILL_COLORS[pill[7]], 0.5)
		end
		-- этикетка только на задней половине: спереди видно таблетки
		Cylinder(1.3, 3.6, 1.49, LABEL, nil, nil, -95, 95, 20)
		Cylinder(3.25, 3.6, 1.5, STRIPE, nil, nil, -95, 95, 20)
		for _, line in ipairs({{2.85, -60, 70}, {2.5, -60, 45}, {2.15, -60, 75}, {1.7, -60, 20}}) do
			Cylinder(line[1] - 0.09, line[1] + 0.09, 1.505, INK, nil, nil, line[2], line[3], 10)
		end
		Cylinder(4.85, 6.0, 1.58, CAP, CAP)
		local solid = Finish(solidMat)

		verts = {}
		Cylinder(4.6, 4.85, 1.2, GLASS)
		Cylinder(0.0, 4.6, 1.45, GLASS, nil, GLASS)
		Cylinder(0.4, 4.3, 1.46, SHINE, nil, nil, 200, 214, 2)
		return solid, Finish(glassMat)
	end

	local solidMesh, glassMesh, bottleBroken
	local solidMat = CreateMaterial("rem_vicodin_solid", "UnlitGeneric", {["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1})
	local glassMat = CreateMaterial("rem_vicodin_glass", "UnlitGeneric", {["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1})

	local function DrawBottle(pos, ang)
		if bottleBroken then return end
		if not solidMesh then
			local ok, solid, glass = pcall(BuildBottle, solidMat, glassMat)
			if not ok or not solid or not glass then
				bottleBroken = true
				ErrorNoHalt("[vicodin] model build failed: " .. tostring(solid) .. "\n")
				return
			end
			solidMesh, glassMesh = solid, glass
		end
		local lc = render.GetLightColor(pos)
		local k = math.Clamp(0.3 + (lc.x + lc.y + lc.z) / 3 * 2.5, 0.3, 1.15)
		local m = Matrix()
		m:Translate(pos)
		m:Rotate(ang)
		render.SetColorModulation(k, k, k)
		cam.PushModelMatrix(m)
			render.SetMaterial(solidMat)
			solidMesh:Draw()
			render.SetMaterial(glassMat)
			glassMesh:Draw()
		cam.PopModelMatrix()
		render.SetColorModulation(1, 1, 1)
	end

	-- вместо модели обычных таблеток - свой флакон, в той же руке и с тем же хватом
	function SWEP:DrawWorldModel2(nodraw)
		if nodraw then return end
		local owner = hg.GetCurrentCharacter(self:GetOwner())
		local pos, ang
		if IsValid(owner) then
			local org = owner.organism
			local left = (org and org.rarmamputated) or (owner.zmanipstart ~= nil and owner.zmanipseq == "interact" and not (org and org.larmamputated))
			local boneid = owner:LookupBone(left and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand")
			local matrix = boneid and owner:GetBoneMatrix(boneid)
			if not matrix then return end
			pos, ang = LocalToWorld(self.offsetVec, self.offsetAng, matrix:GetTranslation(), matrix:GetAngles())
		else
			pos, ang = self:GetPos(), self:GetAngles()
		end
		DrawBottle(pos, ang)
	end
end

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)

	self.modeValues = {
		[1] = pills
	}
end

SWEP.modeValuesdef = {
	[1] = pills,
}

if SERVER then
	local hg_healanims = GetConVar("hg_healanims")

	function SWEP:Heal(ent, mode)
		local org = ent.organism
		if not org then return end
		if ent ~= self:GetOwner() and not IsValid(org.owner.FakeRagdoll) then return end
		if not self.modeValues or (self.modeValues[1] or 0) <= 0 then return end

		local owner = self:GetOwner()
		if ent == hg.GetCurrentCharacter(owner) and hg_healanims and hg_healanims:GetBool() then
			self:SetHolding(math.min(self:GetHolding() + 4, 100))
			if self:GetHolding() < 100 then return end
		end

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		entOwner:EmitSound("snd_jack_hmcd_pillsuse.wav", 60, math.random(95, 105))

		-- ещё одна таблетка только продлевает действие, сильнее не становится
		org.vicodin = 1

		self.modeValues[1] = self.modeValues[1] - 1
		if self.modeValues[1] <= 0 then
			owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
			self:SpawnGarbage(nil, nil, "snd_jack_hmcd_foodbounce.wav")
			self:Remove()
		end

		return true
	end
end
