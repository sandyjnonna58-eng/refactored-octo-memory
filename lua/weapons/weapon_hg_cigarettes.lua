if SERVER then AddCSLuaFile() end
-- Сигареты: пачка на 10 штук, в каждой 6 затяжек. ЛКМ - затяжка (первая - прикурить).
-- Никотин - organism/tier_1/modules/sv_nicotine.lua, привыкание и ломка - sv_addiction.lua.
-- Некурящий от затяжки кашляет; курящему (зависимость) - нет, и ломку снимает.
-- Сигарета рисуется в руке сама (белая с фильтром, тлеет кончик), изо рта после затяжки идёт дым.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Cigarettes"
SWEP.Instructions = "A pack of 10 cigarettes. Calms the nerves, constricts the vessels.\nIt's addictive: smoke enough and you'll crave it.\nLMB to take a drag."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = true
SWEP.WorldModel = "models/props_lab/box01a.mdl"
SWEP.IconOverride = "entities/weapon_hg_cigarettes.png"
if CLIENT then SWEP.WepSelectIcon = Material("entities/weapon_hg_cigarettes.png") end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_cigarettes.png") end

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
	local matColor = Material("color")
	local matGlow = Material("sprites/light_glow02_add")
	local cWhite, cFilter, cAsh, cEmber = Color(240, 238, 230), Color(200, 130, 60), Color(110, 105, 100), Color(255, 120, 40)
	local LENGTH, RADIUS = 3.2, 0.32

	-- сигарета: вдоль оси "вверх" руки (как флакон таблеток - тот же хват), сгорает от затяжек
	function SWEP:DrawWorldModel2(nodraw)
		if nodraw then return end
		local owner = self:GetOwner()
		local char = IsValid(owner) and hg.GetCurrentCharacter(owner) or nil
		if not IsValid(char) then
			self:DrawModel()
			return
		end
		if (self.modeValues and self.modeValues[1] or 1) <= 0 then return end
		local bone = char:LookupBone("ValveBiped.Bip01_R_Hand")
		local m = bone and char:GetBoneMatrix(bone)
		if not m then return end
		local pos, ang = LocalToWorld(self.offsetVec, self.offsetAng, m:GetTranslation(), m:GetAngles())
		local dir = ang:Up()

		local puffs = self:GetNW2Int("puffs", 0)
		local burnt = puffs / self.Puffs
		local len = LENGTH * (1 - burnt * 0.7)
		local filterEnd = pos + dir * 0.9
		local tip = pos + dir * len
		local lit = CurTime() - self:GetNW2Float("lit", 0) < 25

		render.SetMaterial(matColor)
		render.DrawBeam(pos, filterEnd, RADIUS, 0, 1, cFilter)
		render.DrawBeam(filterEnd, tip, RADIUS, 0, 1, cWhite)
		if lit then
			render.DrawBeam(tip, tip + dir * 0.18, RADIUS, 0, 1, cAsh)
			local glow = 0.7 + math.sin(CurTime() * 3) * 0.15 + (CurTime() - (owner:GetNW2Float("rem_smoke_puff", 0)) < 1 and 0.5 or 0)
			render.SetMaterial(matGlow)
			render.DrawSprite(tip + dir * 0.2, 1.6 * glow, 1.6 * glow, cEmber)
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
