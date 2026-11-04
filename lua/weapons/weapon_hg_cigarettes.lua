if SERVER then AddCSLuaFile() end
-- Сигареты: пачка на 10 штук, в каждой 6 затяжек. ЛКМ - затяжка (первая - прикурить).
-- Никотин - organism/tier_1/modules/sv_nicotine.lua, привыкание и ломка - sv_addiction.lua.
-- Некурящий от затяжки кашляет; курящему (зависимость) - нет, и ломку снимает.
-- Модели свои (homigrad/libraries/cl_remmesh.lua): в руке сигарета (фильтр, бумага сгорает, пепел, тлеет кончик),
-- на земле - пачка; изо рта после затяжки идёт дым.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Cigarettes"
SWEP.Instructions = "A pack of 10 cigarettes. Calms the nerves, constricts the vessels.\nIt's addictive: smoke enough and you'll crave it.\nLMB to take a drag."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_lab/box01a.mdl"
SWEP.IconOverride = "entities/weapon_hg_cigarettes.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_cigarettes.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_cigarettes.png") end

-- сигарета между пальцами (от кости кисти: x - к пальцам, -z - из ладони): фильтром к ладони, тлеющим концом вперёд
SWEP.CigHoldPos = Vector(2.2, 0, -0.4)
SWEP.CigHoldAng = Angle(90, 0, 0)

SWEP.Cigarettes = 10
SWEP.Puffs = 6
SWEP.PuffNicotine = 0.18
SWEP.PuffCO = 0.6
SWEP.PuffDelay = 2.2
SWEP.DeploySnd = "physics/cardboard/cardboard_box_impact_soft1.wav"
SWEP.FallSnd = "physics/cardboard/cardboard_box_impact_soft2.wav"

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = {[1] = self.Cigarettes}
	self:SetModelScale(0.3, 0)
end
SWEP.modeValuesdef = {[1] = 10}

function SWEP:Think() end
function SWEP:OwnerChanged() end

if SERVER then
	local coughs = {"ambient/voices/cough1.wav", "ambient/voices/cough2.wav", "ambient/voices/cough3.wav", "ambient/voices/cough4.wav"}

	function SWEP:Heal(ent, mode)
		local owner = self:GetOwner()
		if ent ~= owner and ent ~= hg.GetCurrentCharacter(owner) then return end -- курить можно только самому
		local org = owner.organism
		if not org then return end
		if (self.nextPuff or 0) > CurTime() then return end
		if not self.modeValues or (self.modeValues[1] or 0) <= 0 then return end
		self.nextPuff = CurTime() + self.PuffDelay

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		local puffs = self:GetNW2Int("puffs", 0)
		if puffs == 0 then entOwner:EmitSound("ambient/fire/ignite.wav", 55, math.random(115, 130), 0.5) end

		puffs = puffs + 1
		self:SetNW2Int("puffs", puffs)
		self:SetNW2Float("lit", CurTime())
		owner:SetNW2Float("rem_smoke_puff", CurTime())

		org.nicotine = math.min((org.nicotine or 0) + self.PuffNicotine, 5)
		org.CO = math.min((org.CO or 0) + self.PuffCO, 30)

		-- некурящий кашляет
		local dep = hg.Addiction and hg.Addiction.Get and hg.Addiction.Get(owner, "nicotine") or 0
		if math.Rand(0, 1) < (0.55 - dep * 1.5) then
			timer.Simple(0.9, function()
				if not IsValid(entOwner) then return end
				entOwner:EmitSound(coughs[math.random(#coughs)], 65, math.random(95, 110))
				if org then org.painadd = (org.painadd or 0) + 1 end
			end)
		end

		if puffs >= self.Puffs then
			-- докурил: окурок под ноги, следующая сигарета
			self:SetNW2Int("puffs", 0)
			self:SetNW2Float("lit", 0)
			self.modeValues[1] = self.modeValues[1] - 1
			if self.modeValues[1] <= 0 then
				owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
				self:SpawnGarbage(self.WorldModel, nil, "physics/cardboard/cardboard_box_impact_soft3.wav")
				self:Remove()
			end
		end
		return true
	end
end

if CLIENT then
	local matGlow = Material("sprites/light_glow02_add")
	local cEmber = Color(255, 120, 40)
	local FILTER, PAPER, RADIUS = 1.1, 3.1, 0.16
	local RM

	-- сигарета: фильтр + бумага (бумага построена высотой 1 и растягивается по оставшейся длине) + пепел
	local function BuildCig()
		local f = RM.Builder()
		f:Cylinder(0, FILTER, RADIUS, Color(212, 148, 70), {bottom = Color(225, 200, 160)})
		for _, z in ipairs({0.25, 0.6, 0.9}) do
			f:Cylinder(z, z + 0.06, RADIUS + 0.005, Color(170, 105, 45), {a0 = 20, a1 = 160, seg = 6})
		end
		f:Cylinder(FILTER - 0.06, FILTER, RADIUS + 0.008, Color(200, 170, 70))
		local p = RM.Builder()
		p:Cylinder(0, 1, RADIUS - 0.004, Color(244, 242, 236))
		local a = RM.Builder()
		a:Cylinder(0, 0.22, RADIUS - 0.01, Color(95, 90, 86), {top = Color(70, 66, 62)})
		return {filter = f:Finish(RM.SolidMat), paper = p:Finish(RM.SolidMat), ash = a:Finish(RM.SolidMat)}
	end

	-- пачка: белый низ, красный верх, открытая крышка, торчат три фильтра
	local function BuildPack()
		local b = RM.Builder()
		local w, d = 1.45, 0.575
		local white, red, dark = Color(238, 236, 230), Color(196, 28, 32), Color(45, 32, 26)
		b:Box(Vector(-w, -d, 0), Vector(w, d, 2.7), white, {top = true})
		b:Box(Vector(-w, -d, 2.7), Vector(w, d, 4.4), red, {top = true, bottom = true})
		b:Box(Vector(-w + 0.05, -d + 0.05, 4.1), Vector(w - 0.05, d - 0.05, 4.11), dark)
		-- открытая крышка, откинута назад
		b:Box(Vector(-w, d, 4.4), Vector(w, d + 0.12, 5.9), red)
		-- красный "клин" на белом спереди и золотая полоска
		b:Quad(Vector(-w, -d - 0.01, 2.7), Vector(w, -d - 0.01, 2.7), Vector(0, -d - 0.01, 1.6), Vector(0, -d - 0.01, 1.6), red, Vector(0, -1, 0))
		b:Box(Vector(-w, -d - 0.012, 2.66), Vector(w, -d - 0.002, 2.74), Color(205, 175, 80), {back = true})
		for i, x in ipairs({-0.7, 0, 0.7}) do
			b:Lathe({{3.9, 0.17}, {i == 2 and 5.1 or 4.8, 0.17}}, Color(212, 148, 70), {top = Color(225, 200, 160), seg = 10, offset = Vector(x, 0, 0)})
		end
		return {pack = b:Finish(RM.SolidMat)}
	end

	-- по фото (личный пак materials/rem_drinks_private): белая пачка с золотой полоской - картинка на всех четырёх
	-- боковых гранях, открытая белая крышка, внутри белая фольга, торчат шесть пробковых фильтров
	local PACK_TEX, FILTER_TEX = "rem_drinks_private/pack_front.png", "rem_drinks_private/filter.png"
	local function BuildPackPhoto(packMat, filterMat)
		local w, d, h = 1.45, 0.575, 4.4
		local f = RM.Builder()
		local full = {0, 1, 1, 1, 1, 0, 0, 0} -- a(низ-лево) b(низ-право) c(верх-право) d(верх-лево)
		f:Quad(Vector(-w, -d, 0), Vector(w, -d, 0), Vector(w, -d, h), Vector(-w, -d, h), color_white, Vector(0, -1, 0), full)
		f:Quad(Vector(w, d, 0), Vector(-w, d, 0), Vector(-w, d, h), Vector(w, d, h), color_white, Vector(0, 1, 0), full)
		f:Quad(Vector(-w, d, 0), Vector(-w, -d, 0), Vector(-w, -d, h), Vector(-w, d, h), color_white, Vector(-1, 0, 0), full)
		f:Quad(Vector(w, -d, 0), Vector(w, d, 0), Vector(w, d, h), Vector(w, -d, h), color_white, Vector(1, 0, 0), full)
		local faces = f:Finish(packMat)

		local b = RM.Builder()
		local white, foil = Color(240, 240, 236), Color(225, 225, 228)
		b:Box(Vector(-w, -d, -0.01), Vector(w, d, 0), white, {top = true})
		b:Box(Vector(-w + 0.05, -d + 0.05, 3.9), Vector(w - 0.05, d - 0.05, 3.91), foil)
		b:Box(Vector(-w, d, h), Vector(w, d + 0.12, h + 1.5), white) -- откинутая крышка
		local plain = b:Finish(RM.SolidMat)

		local c = RM.Builder()
		local tops = {4.9, 5.15, 4.95, 5.2, 4.85, 5.05}
		for i = 1, 6 do
			local x = -w + 0.26 + (i - 1) * ((2 * w - 0.52) / 5)
			c:Lathe({{3.7, 0.2}, {tops[i], 0.2}}, color_white, {seg = 10, offset = Vector(x, -0.1, 0), top = color_white,
				uv = function(p) return (math.atan2(p.y, p.x) / (2 * math.pi)) % 1, 1 - (p.z - 3.7) / 1.5 end})
		end
		return {faces = faces, plain = plain, filters = c:Finish(filterMat)}
	end

	-- сигарета вдоль пальцев (CigHoldPos/Ang), сгорает от затяжек;
	-- на земле - пачка
	function SWEP:DrawWorldModel2(nodraw)
		if nodraw then return end
		RM = RM or hg.RemMesh
		if not RM then return end
		local owner = self:GetOwner()
		local char = IsValid(owner) and hg.GetCurrentCharacter(owner) or nil
		if not IsValid(char) then
			local ang = self:GetAngles()
			local at = self:LocalToWorld(self:OBBCenter()) - ang:Up() * 2.2
			local packMat, filterMat = RM.TexMat(PACK_TEX), RM.TexMat(FILTER_TEX)
			if packMat and filterMat then
				local pp = RM.Get("rem_cigpack_photo", function() return BuildPackPhoto(packMat, filterMat) end)
				if pp then RM.Draw({{pp.faces, packMat}, {pp.plain, RM.SolidMat}, {pp.filters, filterMat}}, at, ang) end
				return
			end
			local pack = RM.Get("rem_cigpack", BuildPack)
			if not pack then return end
			RM.Draw({{pack.pack, RM.SolidMat}}, at, ang)
			return
		end
		local cig = RM.Get("rem_cigarette", BuildCig)
		if not cig then return end
		local bone = char:LookupBone("ValveBiped.Bip01_R_Hand")
		local m = bone and char:GetBoneMatrix(bone)
		if not m then return end
		local pos, ang = LocalToWorld(self.CigHoldPos, self.CigHoldAng, m:GetTranslation(), m:GetAngles())
		local dir = ang:Up()

		local burnt = self:GetNW2Int("puffs", 0) / self.Puffs
		local paper = PAPER * (1 - burnt * 0.8)
		local lit = CurTime() - self:GetNW2Float("lit", 0) < 25
		local filterMat = RM.TexMat(FILTER_TEX)
		if filterMat then
			local tf = RM.Get("rem_cigfilter_photo", function()
				local b = RM.Builder()
				b:Cylinder(0, FILTER, RADIUS + 0.002, color_white, {seg = 12, bottom = color_white,
					uv = function(p) return (math.atan2(p.y, p.x) / (2 * math.pi)) % 1, 1 - p.z / FILTER end})
				return {filter = b:Finish(filterMat)}
			end)
			if tf then RM.Draw({{tf.filter, filterMat}}, pos, ang) end
		else
			RM.Draw({{cig.filter, RM.SolidMat}}, pos, ang)
		end
		RM.Draw({{cig.paper, RM.SolidMat, paper}}, pos + dir * FILTER, ang)
		local tip = pos + dir * (FILTER + paper)
		if not lit then return end
		RM.Draw({{cig.ash, RM.SolidMat}}, tip, ang)
		local glow = 0.7 + math.sin(CurTime() * 3) * 0.15 + (CurTime() - owner:GetNW2Float("rem_smoke_puff", 0) < 1 and 0.5 or 0)
		render.SetMaterial(matGlow)
		render.DrawSprite(tip + dir * 0.2, 1.4 * glow, 1.4 * glow, cEmber)
		-- тонкая струйка с кончика
		if (self.nextWisp or 0) < CurTime() then
			self.nextWisp = CurTime() + 0.25
			local em = ParticleEmitter(tip)
			if em then
				local p = em:Add("particle/smokesprites_000" .. math.random(1, 9), tip)
				if p then
					p:SetVelocity(Vector(0, 0, 8) + VectorRand() * 2)
					p:SetDieTime(1.6)
					p:SetStartAlpha(60)
					p:SetEndAlpha(0)
					p:SetStartSize(0.5)
					p:SetEndSize(4)
					p:SetRoll(math.Rand(0, 360))
					p:SetColor(200, 200, 200)
				end
				em:Finish()
			end
		end
	end

	-- дым изо рта после затяжки (видят все)
	hook.Add("Think", "rem_cigarette_exhale", function()
		local now = CurTime()
		for _, ply in ipairs(player.GetAll()) do
			local t = now - ply:GetNW2Float("rem_smoke_puff", -100)
			if t < 0.8 or t > 2.4 or ply:IsDormant() or not ply:Alive() then continue end
			if (ply.rem_nextExhale or 0) > now then continue end
			ply.rem_nextExhale = now + 0.05
			local char = hg.GetCurrentCharacter(ply)
			if not IsValid(char) then continue end
			local att = char:GetAttachment(char:LookupAttachment("mouth") or 0) or char:GetAttachment(char:LookupAttachment("eyes") or 0)
			if not att then continue end
			local pos = att.Pos - att.Ang:Up() * (char:LookupAttachment("mouth") > 0 and 0 or 2.5)
			local em = ParticleEmitter(pos)
			if not em then continue end
			local p = em:Add("particle/smokesprites_000" .. math.random(1, 9), pos)
			if p then
				local fade = 1 - (t - 0.8) / 1.6
				p:SetVelocity(att.Ang:Forward() * math.Rand(18, 30) + Vector(0, 0, 6) + VectorRand() * 3)
				p:SetAirResistance(40)
				p:SetDieTime(math.Rand(1.8, 2.6))
				p:SetStartAlpha(90 * fade)
				p:SetEndAlpha(0)
				p:SetStartSize(1.5)
				p:SetEndSize(math.Rand(9, 14))
				p:SetRoll(math.Rand(0, 360))
				p:SetRollDelta(math.Rand(-0.6, 0.6))
				p:SetColor(215, 215, 215)
			end
			em:Finish()
		end
	end)
end
