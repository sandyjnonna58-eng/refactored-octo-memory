if SERVER then AddCSLuaFile() end
-- Канцелярский нож: очень слабый, но острый - режет глубоко (сильное кровотечение, легко задевает артерии),
-- можно покончить с собой (как складным ножом) и порезать себе руку: E + ЛКМ (порез левого предплечья, как при
-- самоповреждении в сборке - DoSelfHarmCut: рана, боль, шанс задеть артерию, немного снимает депрессию).
-- Анимации и хват - как у складного ножа (weapon_pocketknife); модель своя, из кода (жёлтый корпус, чёрные вставки,
-- выдвижное сегментное лезвие), рисуется в правой руке.
SWEP.Base = "weapon_pocketknife"
SWEP.PrintName = "Box Cutter"
SWEP.Instructions = "A cheap yellow box cutter. Barely hurts as a weapon, but the blade is razor sharp - deep cuts that bleed a lot.\n\nLMB to attack.\nE + LMB to cut your own arm.\nR + LMB to change attack mode.\nRMB to block."
SWEP.Category = "Weapons - Melee"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/cof/weapons/switchblade/w_switchblade.mdl"
-- видимая модель своя: анимированная модель складного ножа не рисуется (её DrawModel заглушен), рисуем свою
-- в DrawPostWorldModel. Раньше вместо этого подставлялась модель с масштабом 0.001 - это роняло игру.
SWEP.WorldModelExchange = false
SWEP.IconOverride = "entities/weapon_hg_boxcutter.png"
if CLIENT then
	SWEP.WepSelectIcon = Material("entities/weapon_hg_boxcutter.png")
	SWEP.BounceWeaponIcon = false
end
if SERVER then resource.AddSingleFile("materials/entities/weapon_hg_boxcutter.png") end

-- слабый, но острый
SWEP.DamagePrimary = 4
SWEP.DamageSecondary = 3
SWEP.BleedMultiplier = 1.9
SWEP.ArteryChance = 1.35
SWEP.PainMultiplier = 0.6
SWEP.PenetrationPrimary = 2
SWEP.PenetrationSecondary = 1.5
SWEP.MaxPenLen = 1.5
SWEP.PenetrationSizePrimary = 0.8
SWEP.PenetrationSizeSecondary = 0.6
SWEP.StaminaPrimary = 10
SWEP.StaminaSecondary = 8
SWEP.BlockTier = 0.5
SWEP.BreakBoneMul = 0.05
SWEP.weight = 0.3

SWEP.SelfCut = true
SWEP.SelfCutCooldown = 1.6

-- в руке (от кости кисти: x - к пальцам, -z - из ладони): корпус поперёк ладони, лезвие со стороны большого пальца
SWEP.CutterHoldPos = Vector(2.4, 0, -1.0)
SWEP.CutterHoldAng = Angle(0, 90, 0)

if SERVER then
	hook.Add("KeyPress", "rem_boxcutter_selfcut", function(ply, key)
		if key ~= IN_ATTACK or not ply:KeyDown(IN_USE) then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or not wep.SelfCut or not wep.DoSelfHarmCut then return end
		if not ply:Alive() or (wep.nextSelfCut or 0) > CurTime() then return end
		wep.nextSelfCut = CurTime() + (wep.SelfCutCooldown or 1.5)
		wep:DoSelfHarmCut()
		local ent = hg.GetCurrentCharacter(ply)
		local bone = IsValid(ent) and ent:LookupBone("ValveBiped.Bip01_L_Forearm")
		local pos = bone and ent:GetBonePosition(bone)
		if pos then
			local ed = EffectData()
			ed:SetOrigin(pos)
			ed:SetNormal(VectorRand())
			util.Effect("BloodImpact", ed)
		end
	end)
end

if CLIENT then
	local RM

	local function Build()
		local b = RM.Builder()
		local yellow, black, steel, dark = Color(245, 205, 20), Color(28, 28, 30), Color(196, 200, 206), Color(110, 112, 118)
		-- корпус: x вдоль ножа (лезвие в +x), z - вверх (спинка), y - толщина; начало - середина рукояти
		b:Box(Vector(-4.2, -0.3, -0.62), Vector(2.6, 0.3, 0.62), yellow)
		b:Box(Vector(-3.9, -0.31, -0.5), Vector(-2.9, 0.31, 0.2), Color(200, 165, 10)) -- прорезь-петля у хвоста
		b:Box(Vector(-2.4, -0.32, 0.2), Vector(1.6, 0.32, 0.66), black) -- чёрная накладка сверху
		b:Box(Vector(-0.5, -0.2, 0.62), Vector(0.5, 0.2, 0.88), black) -- ползунок
		b:Box(Vector(1.6, -0.32, -0.62), Vector(2.6, 0.32, -0.2), black) -- нос снизу
		-- лезвие: выдвинуто из носа, скошенный кончик, линии сегментов
		local x0, x1, x2 = 2.6, 4.6, 5.3
		local zt, zb = 0.45, -0.45
		for _, y in ipairs({-0.03, 0.03}) do
			local n = Vector(0, y < 0 and -1 or 1, 0)
			local a, bb, c, d = Vector(x0, y, zb), Vector(x2, y, zb), Vector(x1, y, zt), Vector(x0, y, zt)
			if y < 0 then b:Quad(a, bb, c, d, steel, n) else b:Quad(d, c, bb, a, steel, n) end
			for i = 1, 3 do
				local sx = x0 + i * 0.6
				b:Quad(Vector(sx - 0.03, y * 1.4, zb), Vector(sx + 0.03, y * 1.4, zb), Vector(sx + 0.25, y * 1.4, zt), Vector(sx + 0.19, y * 1.4, zt), dark, n)
			end
		end
		return {cutter = b:Finish(RM.SolidMat)}
	end

	local function noDraw() end

	function SWEP:DrawPostWorldModel()
		-- анимированная модель (руки + складной нож) нужна только для хвата, сама не рисуется
		if IsValid(self.worldModel) and self.worldModel.DrawModel ~= noDraw then self.worldModel.DrawModel = noDraw end
		RM = RM or hg.RemMesh
		if not RM then return end
		local model = RM.Get("rem_boxcutter", Build)
		if not model then return end
		local owner = self:GetOwner()
		local char = IsValid(owner) and hg.GetCurrentCharacter(owner) or nil
		local pos, ang
		if IsValid(char) then
			local bone = char:LookupBone("ValveBiped.Bip01_R_Hand")
			local m = bone and char:GetBoneMatrix(bone)
			if not m then return end
			pos, ang = LocalToWorld(self.CutterHoldPos, self.CutterHoldAng, m:GetTranslation(), m:GetAngles())
		elseif IsValid(self.worldModel) then
			pos, ang = self.worldModel:GetPos(), self.worldModel:GetAngles()
		else
			pos, ang = self:GetPos(), self:GetAngles()
		end
		RM.Draw({{model.cutter, RM.SolidMat}}, pos, ang)
	end
end
