-- Совместимость с отдельными аддонами "ULTRAKILL Weapons Pack" (weapon_dredux_uk_*, база weapon_dredux_base2_uk)
-- и "ULTRAKILL Coin Mechanics" (в репозиторий не кладём - чужие модели/звуки, ставятся в garrysmod/addons).
-- Оружие работает как оружие zcity:
--   * камера homigrad и своё тело от первого лица; вьюмодели ULTRAKILL (рука V1) не видно - пушку (её модель
--     от третьего лица *_3rd.mdl) держит в правой руке аватар zcity: кисть ставится перед глазами (SetHandPos),
--     руку дотягивает TPIK homigrad (hg.MainTPIKFunction -> hg.DoTPIK), модель рисуется по кости кисти (DrawWorldModel2,
--     её зовёт fake/sh_render.lua). Так же это видят и другие игроки;
--   * анимации как в SWEP (Anim): невидимая вьюмодель продолжает играть свои анимации и моды костей - их поза
--     переносится на кисть аватара (выстрел, перезарядка, доставание; левая рука - когда она у пушки) и на детали
--     модели в руке (барабан, стволы, пила, колесо, помпа, пипки). У других игроков детали - только по модам SCK;
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

	local function Copy(m) local c = Matrix() c:Set(m) return c end
	local function IsArmBone(name) return string.sub(name, 1, 10) == "ValveBiped" end

	-- положение кости относительно родителя
	local function LocalOf(ent, bone)
		local m = ent:GetBoneMatrix(bone)
		if not m then return end
		local p = ent:GetBoneParent(bone)
		local pm = p and p >= 0 and ent:GetBoneMatrix(p)
		return pm and pm:GetInverseTR() * m or Copy(m)
	end

	-- модель оружия (*_3rd) в нулевой позе: кисть (по ней модель ставится в руку) и повороты деталей
	local wmInfo = {}
	local function WMInfo(model)
		local v = wmInfo[model]
		if v ~= nil then return v or nil end
		local cs = ClientsideModel(model, RENDERGROUP_OTHER)
		if not IsValid(cs) then wmInfo[model] = false return end
		cs:SetNoDraw(true)
		cs:SetPos(vector_origin)
		cs:SetAngles(angle_zero)
		cs:SetupBones()
		local bone = cs:LookupBone(HAND)
		local m = bone and cs:GetBoneMatrix(bone)
		v = false
		if m then
			v = {handInv = m:GetInverseTR(), rot = {}}
			for i = 0, cs:GetBoneCount() - 1 do
				local name = cs:GetBoneName(i)
				local l = name and not IsArmBone(name) and LocalOf(cs, i)
				if l then l:SetTranslation(vector_origin) v.rot[name] = l end
			end
		end
		cs:Remove()
		wmInfo[model] = v
		return v or nil
	end

	-- Анимации как в SWEP: вьюмодель ULTRAKILL не рисуется, но продолжает играть свои анимации (выстрел, перезарядка,
	-- доставание) и SCK-моды костей (крутится барабан, стволы, пила, колесо, пипки). Каждый кадр её поза копируется
	-- в невидимую модель-зеркало, и отличие от покоя ("idle", кадр 0) переносится: кисть - на руку аватара,
	-- детали (weapon_*) - на модель в руке (по именам костей, они у моделей вида и мира одинаковые).
	-- У части костей оси в моделях вида и мира развёрнуты по-разному - поправка (оси модели мира в осях вьюмодели,
	-- посчитано по костям моделей относительно weapon_base / ствола).
	local FIX = {}
	local function Fix(model, bone, rows)
		FIX[model] = FIX[model] or {}
		local K = Matrix({{rows[1][1], rows[1][2], rows[1][3], 0}, {rows[2][1], rows[2][2], rows[2][3], 0},
			{rows[3][1], rows[3][2], rows[3][3], 0}, {0, 0, 0, 1}})
		FIX[model][bone] = {K, K:GetInverseTR()}
	end
	local SG, RC = "models/ultrakill/weapons/shotgun/shotgun_3rd.mdl", "models/ultrakill/weapons/railcannon/railcannon_3rd.mdl"
	Fix(SG, "weapon_barrel", {{-0.071, -0.050, 0.996}, {-0.074, -0.996, -0.055}, {0.995, -0.077, 0.067}})
	Fix(SG, "weapon_pump", {{-0.071, -0.050, 0.996}, {-0.074, -0.996, -0.055}, {0.995, -0.077, 0.067}})
	Fix(RC, "weapon_pip_1", {{0.727, 0.687, 0.003}, {-0.687, 0.727, 0.006}, {0.003, -0.006, 1}})
	Fix(RC, "weapon_pip_2", {{0.627, 0.779, 0.005}, {-0.779, 0.627, 0.009}, {0.004, -0.010, 1}})
	Fix(RC, "weapon_pip_3", {{0.668, 0.744, 0.004}, {-0.744, 0.668, 0.008}, {0.003, -0.008, 1}})
	Fix(RC, "weapon_pip_4", {{0.742, 0.671, 0.002}, {-0.671, 0.742, 0.006}, {0.002, -0.006, 1}})
	-- у revolver_3rd барабан висит прямо на кисти, ствол - по его -z (у вьюмодели - по +z)
	Fix("models/ultrakill/weapons/revolver/revolver_3rd.mdl", "weapon_cylinder", {{-1, 0, 0}, {0, 1, 0}, {0, 0, -1}})

	local function IdleSeq(cs)
		local s = cs:SelectWeightedSequence(ACT_VM_IDLE)
		if not s or s < 0 then s = cs:LookupSequence("idle") end
		if not s or s < 0 then s = 0 end
		return s
	end

	-- вьюмодель в покое: кисть и детали относительно родителей
	local vmRest = {}
	local function VMRest(model)
		local r = vmRest[model]
		if r ~= nil then return r or nil end
		local cs = ClientsideModel(model, RENDERGROUP_OTHER)
		if not IsValid(cs) then vmRest[model] = false return end
		cs:SetNoDraw(true)
		cs:SetPos(vector_origin)
		cs:SetAngles(angle_zero)
		cs:ResetSequence(IdleSeq(cs))
		cs:SetCycle(0)
		cs:SetupBones()
		local hb = cs:LookupBone(HAND)
		local hm = hb and cs:GetBoneMatrix(hb)
		r = false
		if hm then
			r = {rhInv = hm:GetInverseTR(), loc = {}}
			for i = 0, cs:GetBoneCount() - 1 do
				local name = cs:GetBoneName(i)
				-- weapon_base не берём: движение всей пушки уже даёт кисть
				local l = name and not IsArmBone(name) and name ~= "weapon_base" and LocalOf(cs, i)
				if l then r.loc[name] = l:GetInverseTR() end
			end
		end
		cs:Remove()
		vmRest[model] = r
		return r
	end

	-- анимация этого кадра (только своё оружие - вьюмодель есть только у себя): {hand, lh, parts}
	local function Anim(self)
		local fn = FrameNumber()
		if self.remAnimFrame == fn then return self.remAnim end
		self.remAnimFrame, self.remAnim = fn, nil
		local ply = self:GetOwner()
		if ply ~= LocalPlayer() then return end
		local vm = ply:GetViewModel(0)
		if not IsValid(vm) then return end
		local model = vm:GetModel()
		if not model or model == "" or string.lower(model) ~= string.lower(self.ViewModel or "") then return end
		local r = VMRest(model)
		if not r then return end

		local mir = self.remMir
		if not IsValid(mir) then
			mir = ClientsideModel(model, RENDERGROUP_OTHER)
			if not IsValid(mir) then return end
			mir:SetNoDraw(true)
			mir:SetPos(vector_origin)
			mir:SetAngles(angle_zero)
			self.remMir = mir
			self:CallOnRemove("rem_uk_mir", function() if IsValid(mir) then mir:Remove() end end)
		end
		if mir:GetModel() ~= model then mir:SetModel(model) end
		local seq = vm:GetSequence()
		if mir:GetSequence() ~= seq then mir:ResetSequence(seq) end
		mir:SetCycle(vm:GetCycle())
		if self.UpdateBonePositions then pcall(self.UpdateBonePositions, self, mir) end -- моды SCK (вращение)
		mir:InvalidateBoneCache()
		mir:SetupBones()

		local hb = mir:LookupBone(HAND)
		local A = hb and mir:GetBoneMatrix(hb)
		if not A then return end
		local a = {hand = r.rhInv * A, parts = {}}
		-- левая рука, когда она у пушки (перезарядка, помпа): положение относительно правой
		local lb = mir:LookupBone("ValveBiped.Bip01_L_Hand")
		local L = lb and mir:GetBoneMatrix(lb)
		if L then
			local lp = L:GetTranslation()
			if lp.x > 2 and lp:DistToSqr(A:GetTranslation()) < 900 then a.lh = A:GetInverseTR() * L end
		end
		for name, restInv in pairs(r.loc) do
			local b = mir:LookupBone(name)
			local l = b and LocalOf(mir, b)
			if l then a.parts[name] = restInv * l end
		end
		self.remAnim = a
		return a
	end

	-- кисть аватара - перед глазами, ствол по прицелу, плюс анимация кисти из SWEP; руку дотягивает hg.DoTPIK
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
		local anim = Anim(self)
		if anim then m = m * anim.hand end
		ply.rhold = old
		hg.bone_apply_matrix(ent, rh, m)
		self.rhandik = true

		local lh = anim and anim.lh and ent:LookupBone("ValveBiped.Bip01_L_Hand")
		local lold = lh and ent:GetBoneMatrix(lh)
		if lold then
			ply.lhold = lold
			hg.bone_apply_matrix(ent, lh, m * anim.lh)
			self.lhandik = true
		end
	end

	-- детали модели в руке: своё оружие - как у вьюмодели (анимация + моды), чужое - только моды SCK
	local function AnimateParts(self, cs, model, info)
		local a = Anim(self)
		if not a then
			if self.UpdateBonePositions then pcall(self.UpdateBonePositions, self, cs) end
			return
		end
		local fix = FIX[model]
		for name, D in pairs(a.parts) do
			local b = cs:LookupBone(name)
			if b then
				local f = fix and fix[name]
				if f then D = f[2] * D * f[1] end
				cs:ManipulateBoneAngles(b, D:GetAngles())
				local R = info.rot[name]
				cs:ManipulateBonePosition(b, R and R * D:GetTranslation() or D:GetTranslation())
			end
		end
	end

	-- модель оружия по кости кисти (своего тела, чужого игрока или рэгдолла)
	local function DrawWorldModel2(self)
		local owner = self:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() or owner.NotSeen then return end
		local ent = hg.GetCurrentCharacter(owner)
		if not IsValid(ent) then return end
		local model = self.WorldModel
		local info = model and model ~= "" and WMInfo(model)
		if not info then return end
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
		AnimateParts(self, cs, model, info)
		local w = m * info.handInv
		cs:SetRenderOrigin(w:GetTranslation())
		cs:SetRenderAngles(w:GetAngles())
		cs:InvalidateBoneCache()
		cs:SetupBones()
		cs:DrawModel()
		self.remDrawn = CurTime()
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
-- каждое новое оружие - тоже (на случай, если таблица экземпляра собрана без наших полей)
hook.Add("OnEntityCreated", "rem_ultrakill", function(e)
	timer.Simple(0, function()
		if IsValid(e) and e:IsWeapon() and IsUKClass(e:GetClass(), e.Base) then Patch(e:GetTable()) end
	end)
end)

-- rem_uk_debug: что с оружием ULTRAKILL сейчас (вводить лёжа в рэгдолле, если пушки не видно)
local function DebugLine(ply, wep)
	return string.format("weapon=%s WorkWithFake=%s remHeldGun=%s FakeRagdoll=%s",
		IsValid(wep) and wep:GetClass() or "none", tostring(IsValid(wep) and wep.WorkWithFake),
		tostring(IsValid(wep) and wep.remHeldGun), tostring(IsValid(ply.FakeRagdoll)))
end
if SERVER then
	concommand.Add("rem_uk_debug_sv", function(ply)
		if not IsValid(ply) then return end
		ply:PrintMessage(HUD_PRINTCONSOLE, "[rem_uk] server: " .. DebugLine(ply, ply:GetActiveWeapon())
			.. " heldBeforeFall=" .. tostring(IsValid(ply.remUKFallWep) and ply.remUKFallWep:GetClass()))
	end)
else
	concommand.Add("rem_uk_debug", function(ply)
		local wep = ply:GetActiveWeapon()
		print("[rem_uk] client: " .. DebugLine(ply, wep) .. " DrawWorldModel2=" .. tostring(IsValid(wep) and wep.DrawWorldModel2 ~= nil)
			.. " drawnAgo=" .. tostring(IsValid(wep) and wep.remDrawn and math.Round(CurTime() - wep.remDrawn, 2)))
		RunConsoleCommand("rem_uk_debug_sv")
	end)
end

if SERVER then
	-- в рэгдолле игрок стоит в голове рэгдолла (fake/sv_control.lua), и выстрел/снаряд ULTRAKILL (из GetShootPos)
	-- попадал бы в свою же голову - точка выстрела выносится вперёд по прицелу
	local SHOOT_FWD = 14
	local up = Vector(0, 0, 1)

	-- упал с пушкой ULTRAKILL - она остаётся в руке (homigrad_base/sv_fake.lua делает так для WorkWithFake; здесь - страховка,
	-- если что-то успело убрать оружие при падении)
	hook.Add("Fake", "rem_ultrakill_keep", function(ply)
		local wep = ply.ActiveWeapon
		if not IsValid(wep) or not IsUKClass(wep:GetClass(), wep.Base) then ply.remUKFallWep = nil return end
		Patch(wep:GetTable())
		ply.remUKFallWep = wep
		timer.Simple(0, function()
			if not IsValid(ply) or not IsValid(wep) or not IsValid(ply.FakeRagdoll) or wep:GetOwner() ~= ply then return end
			if ply:GetActiveWeapon() ~= wep then ply:SetActiveWeapon(wep) end
		end)
	end)

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
