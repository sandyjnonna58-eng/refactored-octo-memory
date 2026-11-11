if SERVER then AddCSLuaFile() end
-- Отрубленная конечность в руке (берётся с пола на E - organism/sv_severedlimbs.lua). ЛКМ - откусить (5 укусов):
-- немного сытости, но тошнит сильно и с каждым укусом (и с каждым съеденным куском за жизнь) всё сильнее -
-- рвота (sv_vomit.lua), мысли. В руке рисуется сама конечность: копия модели тела, видны только кости конечности.
SWEP.Base = "weapon_painkillers"
SWEP.PrintName = "Severed limb"
SWEP.Instructions = "Someone's arm or leg. You could eat it.\nYou probably shouldn't.\nLMB to take a bite."
SWEP.Category = "ZCity Other"
SWEP.Spawnable = false
SWEP.WorldModel = "models/props_junk/watermelon01_chunk02a.mdl" -- только физика на земле, рисуется конечность
SWEP.HoldType = "slam"
SWEP.Bites = 5
SWEP.BiteDelay = 1.6
SWEP.DeploySnd = "physics/flesh/flesh_squishy_impact_hard2.wav"
SWEP.FallSnd = "physics/flesh/flesh_squishy_impact_hard3.wav"
SWEP.showstats = false
if CLIENT then
	SWEP.WepSelectIcon = Material("vgui/wep_jack_hmcd_fooddrink")
	SWEP.IconOverride = "vgui/wep_jack_hmcd_fooddrink.png"
end

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = {[1] = 1}
end
SWEP.modeValuesdef = {[1] = 1}
function SWEP:Think() end
function SWEP:OwnerChanged() end

if SERVER then
	local chew = {"physics/flesh/flesh_squishy_impact_hard1.wav", "physics/flesh/flesh_squishy_impact_hard4.wav",
		"npc/barnacle/barnacle_crunch2.wav", "npc/barnacle/barnacle_crunch3.wav"}
	local thoughts = {
		"What am I doing...",
		"It's still warm...",
		"Don't think about it. Just chew.",
		"I can feel the bone...",
		"Oh god, the taste...",
		"I'm going to be sick...",
	}

	function SWEP:Heal(ent, mode)
		local owner = self:GetOwner()
		if ent ~= owner and ent ~= hg.GetCurrentCharacter(owner) then return end -- кормить других нельзя
		local org = owner.organism
		if not org or org.otrub then return end
		if (self.nextBite or 0) > CurTime() then return end
		self.nextBite = CurTime() + self.BiteDelay

		local entOwner = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		entOwner:EmitSound(chew[math.random(#chew)], 60, math.random(85, 100))
		util.Decal("Blood", owner:EyePos(), owner:EyePos() - Vector(0, 0, 90), owner)

		-- сытость - чуть-чуть, тошнота - много и всё больше
		org.satiety = math.min((org.satiety or 0) + 6, 100)
		owner.rem_fleshBites = (owner.rem_fleshBites or 0) + 1
		local n = owner.rem_fleshBites
		if hg.organism.AddNausea then hg.organism.AddNausea(owner, org, math.min(0.22 + n * 0.05, 0.6)) end
		org.depression = org.depression and math.min(org.depression + 0.02, 1) or org.depression
		if owner.Notify and math.random() < 0.6 then owner:Notify(table.Random(thoughts), true, "rem_flesh", 0) end

		local bites = self:GetNW2Int("bitten", 0) + 1
		self:SetNW2Int("bitten", bites)
		if bites >= self.Bites then
			-- осталась кость - под ноги
			owner:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(owner) or "weapon_hands_sh")
			self:Remove()
		end
		return true
	end
end

if CLIENT then
	local ZERO, ONE = Vector(0, 0, 0), Vector(1, 1, 1)
	local HOLD_POS, HOLD_ANG = Vector(-4, 0, -1.5), Angle(0, 0, 0) -- начало конечности у ладони, вдоль пальцев

	local function Collect(ent, bone, out)
		out[bone] = true
		for _, c in ipairs(ent:GetChildBones(bone) or {}) do Collect(ent, c, out) end
	end

	-- копия модели тела, где видна только конечность; root - матрица начала конечности при модели в нуле
	function SWEP:GetLimbModel()
		local mdl, boneName = self:GetNW2String("rem_limb_model", ""), self:GetNW2String("rem_limb_bone", "")
		if mdl == "" or boneName == "" then return nil end
		local cs = self.limbCS
		if IsValid(cs) and cs.remKey == mdl .. boneName then return cs end
		if IsValid(cs) then cs:Remove() end
		cs = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
		if not IsValid(cs) then return nil end
		cs:SetNoDraw(true)
		cs.remKey = mdl .. boneName
		cs:SetSkin(self:GetNW2Int("rem_limb_skin", 0))
		local root = cs:LookupBone(boneName)
		if not root then cs:Remove() return nil end
		local keep = {}
		Collect(cs, root, keep)
		for b = 0, cs:GetBoneCount() - 1 do cs:ManipulateBoneScale(b, keep[b] and ONE or ZERO) end
		cs:SetPos(vector_origin)
		cs:SetAngles(angle_zero)
		cs:SetupBones()
		local m = cs:GetBoneMatrix(root)
		if not m then cs:Remove() return nil end
		cs.remRootInv = m:GetInverseTR()
		self.limbCS = cs
		return cs
	end

	-- поставить копию так, чтобы начало конечности оказалось в pos/ang
	local function PlaceRoot(cs, pos, ang)
		local want = Matrix()
		want:SetTranslation(pos)
		want:SetAngles(ang)
		local res = want * cs.remRootInv
		cs:SetPos(res:GetTranslation())
		cs:SetAngles(res:GetAngles())
		cs:SetupBones()
	end

	function SWEP:DrawWorldModel2(nodraw)
		if nodraw then return end
		local cs = self:GetLimbModel()
		if not cs then return end
		local owner = self:GetOwner()
		local char = IsValid(owner) and hg.GetCurrentCharacter(owner) or nil
		if IsValid(char) then
			local bone = char:LookupBone("ValveBiped.Bip01_R_Hand")
			local m = bone and char:GetBoneMatrix(bone)
			if not m then return end
			local pos, ang = LocalToWorld(HOLD_POS, HOLD_ANG, m:GetTranslation(), m:GetAngles())
			PlaceRoot(cs, pos, ang)
		else
			PlaceRoot(cs, self:GetPos(), self:GetAngles())
		end
		-- откусанное - темнее (кровь)
		local k = 1 - self:GetNW2Int("bitten", 0) / self.Bites * 0.35
		render.SetColorModulation(k, k * 0.92, k * 0.92)
		cs:DrawModel()
		render.SetColorModulation(1, 1, 1)
	end

	function SWEP:DrawWorldModel()
		if not IsValid(self:GetOwner()) then self:DrawWorldModel2() end
	end

	local Base = baseclass.Get("weapon_painkillers")
	function SWEP:OnRemove()
		if IsValid(self.limbCS) then self.limbCS:Remove() end
		if Base and Base.OnRemove then return Base.OnRemove(self) end
	end
end
