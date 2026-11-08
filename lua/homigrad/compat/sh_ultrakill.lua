-- Совместимость с отдельными аддонами "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk)
-- и "ULTRAKILL Coin Mechanics" (в репозиторий не кладём - чужие модели/звуки, ставятся в garrysmod/addons).
-- Оружие работает как оружие zcity:
--   * камера homigrad и своё тело от первого лица; вьюмодели ULTRAKILL (рука V1) не видно - пушку (её модель
--     от третьего лица *_3rd.mdl) держит в правой руке аватар zcity: кисть ставится перед глазами (SetHandPos),
--     руку дотягивает TPIK homigrad (hg.MainTPIKFunction -> hg.DoTPIK), модель рисуется по кости кисти (DrawWorldModel2,
--     её зовёт fake/sh_render.lua). Так же это видят и другие игроки;
--   * можно падать в рэгдолл с оружием в руке (WorkWithFake): пушка остаётся в руке рэгдолла, ЛКМ/ПКМ - выстрел,
--     рука с пушкой тянется по прицелу (fake/sv_control.lua, флаг remHeldGun), стрельба - из точки перед лицом.
-- Монетки (ultrakill_toss_coin) кода не требуют: их рикошет бьёт обычным TakeDamageInfo с позицией попадания -
-- организм homigrad разбирает его сам.
hg.UK = hg.UK or {}

local UK_BASES = {weapon_dredux_base2_uk = true, weapon_dredux_base3_uk = true}

local function IsUKClass(class, base)
	return string.sub(class or "", 1, 17) == "weapon_dredux_uk_" or UK_BASES[class or ""] == true or UK_BASES[base or ""] == true
end

function hg.UK.Weapon(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	local w = ply:GetActiveWeapon()
	if not IsValid(w) then return false end
	return IsUKClass(w:GetClass(), w.Base)
end

-- общая уступка камеры чужим аддонам (cl_camera.lua): сейчас только Снейк (sh_mgsv.lua); оружию ULTRAKILL камеру
-- больше не отдаём - его держит аватар
function hg.CameraYield(ply)
	return hg.MGSV and hg.MGSV.Owns and hg.MGSV.Owns(ply) or false
end

local HAND = "ValveBiped.Bip01_R_Hand"

if CLIENT then
	-- где кисть относительно глаз (вперёд, вправо, вверх) - пушка внизу справа, как оружие zcity
	local HOLD = Vector(15, 7, -9)
	local SPRINT_PITCH = 35 -- на бегу ствол опускается

	-- кость кисти у модели оружия в нулевой позе: по ней модель ставится в руку
	local handInv = {}
	local function HandInv(model)
		local v = handInv[model]
		if v ~= nil then return v or nil end
		local cs = ClientsideModel(model, RENDERGROUP_OTHER)
		if not IsValid(cs) then handInv[model] = false return end
		cs:SetNoDraw(true)
		cs:SetPos(vector_origin)
		cs:SetAngles(angle_zero)
		cs:SetupBones()
		local bone = cs:LookupBone(HAND)
		local m = bone and cs:GetBoneMatrix(bone)
		v = m and m:GetInverseTR() or false
		cs:Remove()
		handInv[model] = v
		return v or nil
	end

	-- кисть аватара - перед глазами, ствол по прицелу; руку дотягивает hg.DoTPIK
	-- (у моделей *_3rd ствол идёт по +x кисти, верх пушки - по -z кисти)
	local function SetHandPos(self)
		self.rhandik, self.lhandik = false, false
		local ply = self:GetOwner()
		if not IsValid(ply) or not ply:IsPlayer() then return end
		local ent = hg.GetCurrentCharacter(ply)
		if ent ~= ply then return end -- в рэгдолле рука физическая (fake/sv_control.lua)
		local rh = ent:LookupBone(HAND)
		local old = rh and ent:GetBoneMatrix(rh)
		if not old then return end

		self.remSprint = Lerp(math.min(FrameTime() * 8, 1), self.remSprint or 0, ply:IsSprinting() and 1 or 0)
		local ang = ply:EyeAngles()
		if self.remSprint > 0.01 then ang:RotateAroundAxis(ang:Right(), -SPRINT_PITCH * self.remSprint) end
		local pos = ply:EyePos() + ang:Forward() * HOLD.x + ang:Right() * HOLD.y + ang:Up() * HOLD.z
		ang:RotateAroundAxis(ang:Forward(), 180)

		local m = Matrix()
		m:SetTranslation(pos)
		m:SetAngles(ang)
		ply.rhold = old
		hg.bone_apply_matrix(ent, rh, m)
		self.rhandik = true
	end

	-- модель оружия по кости кисти (своего тела, чужого игрока или рэгдолла)
	local function DrawWorldModel2(self)
		local owner = self:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() or owner.NotSeen then return end
		local ent = hg.GetCurrentCharacter(owner)
		if not IsValid(ent) then return end
		local model = self.WorldModel
		local inv = model and model ~= "" and HandInv(model)
		if not inv then return end
		local rh = ent:LookupBone(HAND)
		local m = rh and ent:GetBoneMatrix(rh)
		if not m then return end

		local cs = self.remWM
		if not IsValid(cs) then
			cs = ClientsideModel(model, RENDERGROUP_OPAQUE)
			if not IsValid(cs) then return end
			cs:SetNoDraw(true)
			self.remWM = cs
			self:CallOnRemove("rem_uk_wm", function() if IsValid(cs) then cs:Remove() end end)
		end
		if cs:GetModel() ~= model then cs:SetModel(model) end
		cs:SetSkin(self:GetSkin())
		cs:SetBodygroup(0, self.GetSelectedMod and self:GetSelectedMod() or self:GetBodygroup(0))
		local w = m * inv
		cs:SetRenderOrigin(w:GetTranslation())
		cs:SetRenderAngles(w:GetAngles())
		cs:SetupBones()
		cs:DrawModel()
	end

	-- движок рисует оружие в руке сам (по анимации, мимо TPIK) - в руках его рисует DrawWorldModel2, сам - только лежащее
	local function DrawWorldModel(self, flags)
		local owner = self:GetOwner()
		if IsValid(owner) and owner:IsPlayer() then return end
		if self.GetSelectedMod then self:SetBodygroup(0, self:GetSelectedMod()) end
		self:DrawModel(flags)
	end

	hg.UK.SetHandPos, hg.UK.DrawWorldModel2, hg.UK.DrawWorldModel = SetHandPos, DrawWorldModel2, DrawWorldModel
end

-- свойства оружия zcity: таблицы классов (новые экземпляры) и уже созданное оружие
local function Patch(t)
	if not t or t.remUKPatched then return end
	t.remUKPatched = true
	t.WorkWithFake = true -- не убирается при падении в рэгдолл (homigrad_base/sv_fake.lua)
	t.remHeldGun = true   -- управление рукой рэгдолла (fake/sv_control.lua)
	if CLIENT then
		t.SetHandPos = hg.UK.SetHandPos
		t.DrawWorldModel2 = hg.UK.DrawWorldModel2
		t.DrawWorldModel = hg.UK.DrawWorldModel
	end
end

local function PatchAll()
	for _, t in ipairs(weapons.GetList()) do
		if IsUKClass(t.ClassName, t.Base) then Patch(weapons.GetStored(t.ClassName)) end
	end
	for _, e in ents.Iterator() do
		if e:IsWeapon() and IsUKClass(e:GetClass(), e.Base) then Patch(e:GetTable()) end
	end
end

hook.Add("PreRegisterSWEP", "rem_ultrakill", function(swep, class)
	if IsUKClass(class, swep.Base) then Patch(swep) end
end)
hook.Add("InitPostEntity", "rem_ultrakill", PatchAll)
timer.Simple(0, PatchAll)

if SERVER then
	-- в рэгдолле игрок стоит в голове рэгдолла (fake/sv_control.lua), и выстрел/снаряд ULTRAKILL (из GetShootPos)
	-- попадал бы в свою же голову - точка выстрела выносится вперёд по прицелу
	local SHOOT_FWD = 14
	local up = Vector(0, 0, 1)

	hook.Add("Think", "rem_ultrakill_fakeshoot", function()
		for _, ply in player.Iterator() do
			local rag = ply.FakeRagdoll
			local wep = IsValid(rag) and ply:Alive() and ply:GetActiveWeapon()
			local on = IsValid(wep) and wep.remHeldGun and not ply:InVehicle() and ply:GetMoveType() == MOVETYPE_NOCLIP
			if on then
				local aim, pos = ply:GetAimVector(), ply:GetPos()
				local tr = util.TraceLine({start = pos, endpos = pos + aim * SHOOT_FWD, filter = {ply, rag}, mask = MASK_SOLID})
				local off = tr.HitPos - aim * 2 - pos
				ply:SetViewOffset(off)
				ply:SetViewOffsetDucked(off)
				ply.remUKOffset = true
			elseif ply.remUKOffset then
				ply.remUKOffset = nil
				-- всё ещё лежит (сменил оружие) - как ставит homigrad; встал - вид уже вернул homigrad
				if IsValid(rag) and ply:GetMoveType() == MOVETYPE_NOCLIP then
					ply:SetViewOffset(up)
					ply:SetViewOffsetDucked(up)
				end
			end
		end
	end)
end
