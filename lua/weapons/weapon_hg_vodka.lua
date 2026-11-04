if SERVER then AddCSLuaFile() end
-- Водка: ЛКМ - глоток, ПКМ - влить тому, кто лежит. Алкоголь - organism/tier_1/modules/sv_alcohol.lua
-- (сначала в желудок, потом за полминуты-минуту всасывается: пьянеешь не сразу).
-- Глоток водки ~0.35 промилле: 3 глотка - пьяный, 6-7 - рвёт, вся бутылка залпом - можно не проснуться.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Vodka"
SWEP.Instructions = "A bottle of cheap vodka. Numbs the pain and the fear, warms you up (not really - you lose heat faster).\nKicks in after a while. Too much and you'll throw up, pass out or worse.\nLMB to take a swig, RMB to pour some into someone lying down."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_junk/garbage_glassbottle003a.mdl"
SWEP.IconOverride = "entities/weapon_hg_vodka.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_vodka.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_vodka.png") end
SWEP.offsetVec = Vector(3, -2.5, 1)
SWEP.offsetAng = Angle(-90, 0, 0)

SWEP.Sips = 8              -- глотков в бутылке
SWEP.SipAlcohol = 0.35     -- промилле за глоток
SWEP.SipSound = {"npc/barnacle/barnacle_gulp1.wav", "npc/barnacle/barnacle_gulp2.wav"}
SWEP.EmptyGivesBottle = false -- пустая бутылка: false - бросить, true - остаётся в руке как "розочка"-бутылка (weapon_hg_bottle)

SWEP.DeploySnd = "physics/glass/glass_bottle_impact_hard1.wav"
SWEP.FallSnd = "physics/glass/glass_bottle_impact_hard2.wav"

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = {[1] = self.Sips}
	if SERVER then self:SetNW2Int("sips", self.Sips) end
end
SWEP.modeValuesdef = {[1] = 8}

function SWEP:Think()
	if not self:GetOwner():KeyDown(IN_ATTACK) and GetConVar("hg_healanims") and GetConVar("hg_healanims"):GetBool() then
		self:SetHolding(math.max(self:GetHolding() - 4, 0))
	end
end

-- NPC бутылку не пьют
function SWEP:OwnerChanged() end

if SERVER then
	function SWEP:Heal(ent, mode)
		local org = ent.organism
		if not org then return end
		local owner = self:GetOwner()
		if ent ~= hg.GetCurrentCharacter(owner) and ent ~= owner and not IsValid(org.owner.FakeRagdoll) then return end
		if not self.modeValues or (self.modeValues[1] or 0) <= 0 then return end
		if (self.nextSip or 0) > CurTime() then return end

		local anims = GetConVar("hg_healanims")
		if ent == hg.GetCurrentCharacter(owner) and anims and anims:GetBool() then
			self:SetHolding(math.min(self:GetHolding() + 4, 100))
			if self:GetHolding() < 100 then return end
		end

		self.nextSip = CurTime() + 1.2
		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		local snd = self.SipSound[math.random(#self.SipSound)]
		entOwner:EmitSound(snd, 60, math.random(95, 108))

		org.alcoholStomach = (org.alcoholStomach or 0) + self.SipAlcohol

		self.modeValues[1] = self.modeValues[1] - 1
		self:SetNW2Int("sips", self.modeValues[1])
		if self.modeValues[1] <= 0 then
			local hands = hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh"
			if self.EmptyGivesBottle and not owner:HasWeapon("weapon_hg_bottle") then
				self:Remove()
				local b = owner:Give("weapon_hg_bottle")
				if IsValid(b) then owner:SelectWeapon("weapon_hg_bottle") else owner:SelectWeapon(hands) end
				return true
			end
			owner:SelectWeapon(hands)
			self:SpawnGarbage(self.WorldModel, nil, "physics/glass/glass_bottle_impact_hard3.wav")
			self:Remove()
		end
		return true
	end
end

-- своя модель бутылки (homigrad/libraries/cl_remmesh.lua): стекло, жидкость (уровень по оставшимся глоткам),
-- этикетка, крышка. Оси: начало - центр дна, z - вверх. grip - на какой высоте держит рука.
SWEP.Bottle = {
	profile = {{0, 1.75}, {0.3, 1.9}, {8.6, 1.9}, {9.6, 1.55}, {10.6, 0.85}, {11, 0.72}, {13.4, 0.72}, {13.6, 0.8}},
	glass = Color(225, 235, 240, 70),
	liquid = Color(225, 238, 250, 55), liquidTop = 8.6, liquidR = 1.78,
	cap = {13.4, 14.6, 0.82, Color(200, 25, 30)},
	label = {3.0, 7.2, Color(240, 240, 232), -110, 110},
	stripe = {6.4, 7.0, Color(196, 28, 32)},
	ink = {Color(30, 30, 34), {4.0, 4.6, 5.2}},
	grip = 5,
	-- по фото (tools/drink_textures/make.py): форма снята с силуэта, фото натягивается спереди и сзади;
	-- картинка из личного пака materials/rem_drinks_private (нет её - рисуется цветная модель выше)
	photo = {
		tex = "rem_drinks_private/vodka.png", H = 13.6, R = 2.19, flat = 0.62,
		profile = {{0, 1.75}, {0.33, 2.06}, {0.66, 2.14}, {1.04, 2.16}, {1.36, 2.16}, {1.69, 2.19}, {2.02, 2.19}, {2.4, 2.19}, {2.73, 2.19}, {3.06, 2.19}, {3.39, 2.19}, {3.72, 2.19}, {4.09, 2.19}, {4.42, 2.19}, {4.75, 2.19}, {5.08, 2.19}, {5.46, 2.19}, {5.79, 2.19}, {6.12, 2.19}, {6.45, 2.19}, {6.78, 2.19}, {7.15, 2.19}, {7.48, 2.19}, {7.81, 2.19}, {8.14, 2.19}, {8.52, 2.12}, {8.85, 2.01}, {9.18, 1.79}, {9.51, 1.48}, {9.88, 1.09}, {10.21, 0.95}, {10.54, 0.92}, {10.87, 0.92}, {11.2, 0.96}, {11.58, 0.94}, {11.91, 0.94}, {12.24, 0.92}, {12.56, 0.94}, {12.94, 0.92}, {13.27, 0.94}, {13.6, 0.72}},
	},
}

if CLIENT then
	local RM

	local function Build(b)
		local glassMat, solidMat = RM.GlassMat, RM.SolidMat
		local s = RM.Builder()
		local outer = b.profile[3][2] + 0.03
		if b.label then
			s:Cylinder(b.label[1], b.label[2], outer, b.label[3], {a0 = b.label[4], a1 = b.label[5], seg = 20})
		end
		if b.stripe then
			s:Cylinder(b.stripe[1], b.stripe[2], outer + 0.01, b.stripe[3], {a0 = b.label[4], a1 = b.label[5], seg = 20})
		end
		if b.ink then
			for _, z in ipairs(b.ink[2]) do
				s:Cylinder(z - 0.1, z + 0.1, outer + 0.015, b.ink[1], {a0 = -55, a1 = 55, seg = 10})
			end
		end
		if b.cap then s:Cylinder(b.cap[1], b.cap[2], b.cap[3], b.cap[4], {top = b.cap[4]}) end
		local solid = s:Finish(solidMat)

		local l = RM.Builder()
		l:Cylinder(0.02, 1, b.liquidR, b.liquid, {top = b.liquid})
		local liquid = l:Finish(glassMat)

		local g = RM.Builder()
		g:Lathe(b.profile, b.glass, {bottom = b.glass})
		local glass = g:Finish(glassMat)
		return {solid = solid, liquid = liquid, glass = glass}
	end

	-- модель по фото: силуэт вращается, картинка проецируется спереди (u - по x, v - по высоте)
	local function BuildPhoto(ph, mat)
		local g = RM.Builder()
		local function uv(p) return 0.5 + p.x / (2 * ph.R), 1 - p.z / ph.H end
		g:Lathe(ph.profile, color_white, {uv = uv, seg = 32, top = color_white, bottom = color_white})
		if ph.flat then g:FlattenY(ph.flat) end
		return {photo = g:Finish(mat)}
	end

	function SWEP:DrawWorldModel2(nodraw)
		if nodraw then return end
		RM = RM or hg.RemMesh
		if not RM then return end
		local b = self.Bottle
		local ph = b.photo
		local phMat = ph and RM.TexMat(ph.tex)
		local model
		if phMat then
			model = RM.Get(self:GetClass() .. "_photo", function() return BuildPhoto(ph, phMat) end)
		else
			model = RM.Get(self:GetClass(), function() return Build(b) end)
		end
		if not model then return end

		local owner = self:GetOwner()
		local char = IsValid(owner) and hg.GetCurrentCharacter(owner) or nil
		local pos, ang
		if IsValid(char) then
			local org = char.organism
			local left = (org and org.rarmamputated) or (char.zmanipstart ~= nil and char.zmanipseq == "interact" and not (org and org.larmamputated))
			local bone = char:LookupBone(left and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand")
			local m = bone and char:GetBoneMatrix(bone)
			if not m then return end
			pos, ang = LocalToWorld(self.offsetVec, self.offsetAng, m:GetTranslation(), m:GetAngles())
			pos = pos - ang:Up() * b.grip
		else
			ang = self:GetAngles()
			local top = phMat and ph.H or (b.cap and b.cap[2] or b.profile[#b.profile][1])
			pos = self:LocalToWorld(self:OBBCenter()) - ang:Up() * top * 0.5
		end

		if phMat then
			RM.Draw({{model.photo, phMat}}, pos, ang)
			return
		end

		local full = math.Clamp(self:GetNW2Int("sips", self.Sips) / self.Sips, 0, 1)
		RM.Draw({
			{model.solid, RM.SolidMat},
			full > 0 and {model.liquid, RM.GlassMat, b.liquidTop * full} or {},
			{model.glass, RM.GlassMat},
		}, pos, ang)
	end
end
