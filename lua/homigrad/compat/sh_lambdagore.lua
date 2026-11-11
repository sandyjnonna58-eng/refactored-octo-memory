-- Совместимость с отдельным аддоном «Lambda gore mod» (в репозиторий не кладём: его модели, звуки и эффекты чужие).
-- У Z-City своя расчленёнка: организм решает, когда отрывается рука или нога (hg.organism.AmputateLimb ->
-- хук OnAmputateLimb), свои разрыв пополам (organism/sv_torsohalve.lua) и взрыв тела целиком (headgib).
-- Поэтому собственную логику Lambda (порча трупов по костям, разрез пополам, взрыв тела, живая расчленёнка NPC,
-- кэш урона игроков) под Z-City выключаем - иначе он рвал бы и рэгдоллы живых игроков. От него берём только картинку:
-- оторванная часть падает отдельным куском (в одежде этого человека), на месте среза - обрубок, из обрубка бьёт кровь,
-- летят куски мяса, звук разрыва. Свой обрубок Z-City (cl_main.lua GoreCalc), пока работает Lambda, не рисуется.
-- Выключить: rem_lambdagore 0.
hg.LambdaGore = hg.LambdaGore or {}
local LG = hg.LambdaGore

local cv = ConVarExists("rem_lambdagore") and GetConVar("rem_lambdagore")
	or CreateConVar("rem_lambdagore", 1, FCVAR_ARCHIVE + FCVAR_REPLICATED, "Lambda gore visuals for Z-City dismemberment", 0, 1)

-- кости, по которым Z-City отрывает конечность (как limbs в organism/tier_1/sv_input.lua)
LG.LimbBone = {
	larm = "ValveBiped.Bip01_L_Forearm",
	rarm = "ValveBiped.Bip01_R_Forearm",
	lleg = "ValveBiped.Bip01_L_Calf",
	rleg = "ValveBiped.Bip01_R_Calf",
}
-- обрубки Lambda: сетка висит на кости плеча / бедра, к телу цепляются через bonemerge
LG.Stump = {
	larm = "models/noob_dev2323/gib/l_arm67.mdl",
	rarm = "models/noob_dev2323/gib/r_arm67.mdl",
	lleg = "models/noob_dev2323/gib/l_leg_gap.mdl",
	rleg = "models/noob_dev2323/gib/r_leg_gap.mdl",
}

function LG.Enabled()
	if not cv:GetBool() then return false end
	if SERVER then return gore_mod_slice_gib ~= nil and noob_gore_TransferBones ~= nil end
	if LG.installed == nil then LG.installed = file.Exists(LG.Stump.larm, "GAME") end
	return LG.installed
end

if SERVER then
	util.AddNetworkString("rem_lgore_limb")

	-- хуки Lambda, которые сами режут / взрывают тела и рэгдоллы (под Z-City это делает организм)
	local OFF = {
		{"EntityTakeDamage", "pai_do_reabilitado"},          -- урон NPC для разреза трупа
		{"CreateEntityRagdoll", "Replace_shit_Ragdoll"},     -- труп NPC: взрыв, разрез пополам, отрыв по попаданию
		{"OnEntityCreated", "On_shit_ent_is_created"},       -- любой prop_ragdoll делает "разрушаемым" (и рэгдоллы игроков)
		{"EntityTakeDamage", "ççp"},                         -- порча разрушаемых рэгдоллов по костям
		{"EntityTakeDamage", "GoreMod_CachePlayerDamage"},   -- кэш урона игроков
		{"CreateEntityRagdoll", "GoreMod_ApplyToPlayerRagdoll"},
		{"ScaleNPCDamage", "ArmGib"},                        -- живая расчленёнка NPC
		{"EntityTakeDamage", "LambdaGore_LiveMelee"},
		{"Think", "ArmCripple_AI"},
		{"EntityTakeDamage", "LambdaGore_ProceduralLayerDamage"},
	}
	local function DisableLambdaLogic()
		for _, h in ipairs(OFF) do hook.Remove(h[1], h[2]) end
	end
	DisableLambdaLogic()
	timer.Simple(0, DisableLambdaLogic) -- Lambda грузится из autorun/server, позже нашего загрузчика
	hook.Add("InitPostEntity", "rem_lambdagore", DisableLambdaLogic)

	-- откуда прилетело: сила последнего урона, чтобы кусок отлетал в нужную сторону
	local function Remember(org, dmgInfo)
		if not org then return end
		org.remLGForce = dmgInfo:GetDamageForce()
		org.remLGBlast = dmgInfo:IsDamageType(DMG_BLAST)
		org.remLGTime = CurTime()
	end
	hook.Add("EntityTakeDamage", "rem_lambdagore_force", function(ent, dmgInfo)
		Remember(IsValid(ent) and ent.organism, dmgInfo)
	end)
	hook.Add("HomigradDamage", "rem_lambdagore_force", function(ply, dmgInfo)
		Remember(IsValid(ply) and ply.organism, dmgInfo)
	end)

	local max_speed = 650

	-- отдельный рэгдолл той же модели, у которого видна только оторванная часть (как в Lambda: остальные кости
	-- сжаты и без столкновений, саму часть рисует клиент - bonemerge-копия с одеждой)
	function LG.DropLimb(src, bone, force)
		local boneId = src:LookupBone(bone)
		if not boneId then return end

		local gib = ents.Create("prop_ragdoll")
		if not IsValid(gib) then return end
		gib:SetModel(src:GetModel())
		gib:SetPos(src:GetPos())
		gib:SetAngles(src:GetAngles())
		gib:SetSkin(src:GetSkin())
		gib:Spawn()
		if gib:GetPhysicsObjectCount() == 0 then gib:Remove() return end

		gib:SetCollisionGroup(COLLISION_GROUP_WEAPON) -- не мешает ходить
		gib.remLambdaLimb = true
		gib.goremod_is_ragdoll_limb = true
		gib.gib_bone = {}
		gore_mod_slice_gib(gib, bone)
		gore_mod_sigma_scale(gib)
		noob_gore_TransferBones(src, gib)
		gib:SetNoDraw(true)
		gib:DrawShadow(false)

		local phys = gib:GetPhysicsObjectNum(gib:TranslateBoneToPhysBone(gib:LookupBone(bone) or boneId))
		if IsValid(phys) then
			local vel = src:GetVelocity() + force / 18
			if vel:Length() > max_speed then vel = vel:GetNormalized() * max_speed end
			phys:Wake()
			phys:AddVelocity(vel)
			phys:AddAngleVelocity(VectorRand() * 300)
		end

		if istable(gib_PhysBone_RAGDOLLS) then table.insert(gib_PhysBone_RAGDOLLS, gib) end
		if istable(limb_ragdoll_count) then table.insert(limb_ragdoll_count, gib) end -- общий лимит кусков Lambda
		local fade = GetConVar("goremod_sliced_ragdoll_fade_time")
		fade = fade and fade:GetFloat() or 30
		if fade < 998 then SafeRemoveEntityDelayed(gib, math.max(fade, 5)) end

		timer.Simple(0.05, function()
			if not IsValid(gib) then return end
			net.Start("rem_lgore_limb")
				net.WriteEntity(IsValid(src) and src or NULL)
				net.WriteString(bone)
				net.WriteEntity(gib)
			net.Broadcast()
		end)
		return gib
	end

	-- Оторванная конечность у рэгдолла (свой рэгдолл игрока, труп) физически оставалась: невидимую ногу можно было
	-- схватить. Как в Lambda: кости части - пустые (сквозь них проходят лучи и руки), без столкновений и массы,
	-- без связи с телом, и держатся на месте отрыва.
	local goneRags = {}
	local function HideLimbPhysics(rag, bone)
		if not IsValid(rag) or not rag:IsRagdoll() then return end
		local top = rag:LookupBone(bone)
		if not top then return end
		local anchor = rag:TranslateBoneToPhysBone(rag:GetBoneParent(top))
		local list = {top}
		local i = 1
		while list[i] do
			for _, child in ipairs(rag:GetChildBones(list[i])) do list[#list + 1] = child end
			i = i + 1
		end
		rag.remLGGone = rag.remLGGone or {}
		for _, b in ipairs(list) do
			local pb = rag:TranslateBoneToPhysBone(b)
			if pb and pb >= 0 and pb ~= anchor and not rag.remLGGone[pb] then
				local phys = rag:GetPhysicsObjectNum(pb)
				if IsValid(phys) then
					if phys:HasGameFlag(FVPHYSICS_PLAYER_HELD) then rag:ForcePlayerDrop() end
					phys:SetContents(CONTENTS_EMPTY)
					phys:EnableCollisions(false)
					phys:SetMass(0.1)
					phys:EnableGravity(false)
					phys:EnableMotion(false)
					rag:RemoveInternalConstraint(pb)
					rag.remLGGone[pb] = anchor
				end
			end
		end
		goneRags[rag] = true
	end
	LG.HideLimbPhysics = HideLimbPhysics

	timer.Create("rem_lambdagore_gone", 0.1, 0, function()
		for rag in pairs(goneRags) do
			if not IsValid(rag) then goneRags[rag] = nil continue end
			for pb, anchor in pairs(rag.remLGGone or {}) do
				local phys, ap = rag:GetPhysicsObjectNum(pb), anchor and anchor >= 0 and rag:GetPhysicsObjectNum(anchor)
				if IsValid(phys) and IsValid(ap) then
					phys:SetPos(ap:GetPos(), true)
					phys:SetAngles(ap:GetAngles())
				end
			end
		end
	end)

	local function HideAmputated(rag, org)
		if not org or not LG.Enabled() then return end
		for limb, bone in pairs(LG.LimbBone) do
			if org[limb .. "amputated"] then HideLimbPhysics(rag, bone) end
		end
	end
	-- новый рэгдолл игрока (упал, умер) - у него уже нет оторванных частей
	hook.Add("Ragdoll_Create", "rem_lambdagore", function(ply, rag)
		timer.Simple(0, function()
			if IsValid(rag) and IsValid(ply) then HideAmputated(rag, ply.organism or rag.organism) end
		end)
	end)

	hook.Add("OnAmputateLimb", "rem_lambdagore", function(org, ent, limb)
		local bone = LG.LimbBone[limb]
		if not bone or not IsValid(ent) or not LG.Enabled() then return end

		local fresh = org and (org.remLGTime or 0) > CurTime() - 1
		local force = fresh and org.remLGForce
		if not force or force:LengthSqr() < 1 then force = VectorRand() * 2500 + Vector(0, 0, 2500) end
		local data = {dmg_force = force, slice = false}
		local pos = ent:GetBonePosition(ent:LookupBone(bone) or 0) or ent:WorldSpaceCenter()

		if fresh and org.remLGBlast then
			-- взрыв: конечность разносит в клочья - куски кости и мяса Lambda вместо целой руки / ноги
			local custom = goremod_CustomGibs and goremod_CustomGibs[bone]
			if custom and gore_mod_make_gibs then
				for _, g in ipairs(custom.gibs or {}) do ProtectedCall(function() gore_mod_make_gibs(g.model, pos, data) end) end
			end
		else
			ProtectedCall(function() LG.DropLimb(ent, bone, force) end)
		end
		-- немного мяса, кровь из обрубка (готовый хук Lambda) и звук разрыва
		if gore_mod_make_gibs then
			for i = 1, math.random(1, 3) do
				ProtectedCall(function() gore_mod_make_gibs("models/props_junk/watermelon01_chunk02a.mdl", pos, data, true) end)
			end
		end
		ProtectedCall(function() hook.Call("noob_gore_make_limb_blood", nil, ent, bone) end)
		if ent:IsRagdoll() then HideLimbPhysics(ent, bone) end
		ent:EmitSound("goremod_gib_sound")
	end)
end

if CLIENT then
	local limbs = {}  -- {model = ClientsideModel, parent = рэгдолл-кусок}
	local stumps = {} -- [ent] = {[limb] = ClientsideModel}
	local max_limbs = 24

	local function CopyLook(from, to)
		if not IsValid(from) then return end
		to:SetSkin(from:GetSkin())
		to:SetColor(from:GetColor())
		to:SetMaterial(from:GetMaterial())
		for _, group in ipairs(from:GetBodyGroups()) do to:SetBodygroup(group.id, from:GetBodygroup(group.id)) end
		-- одежда Z-City - это сабматериалы модели (new_appearance/sv_init.lua)
		for i = 0, 31 do
			local sub = from:GetSubMaterial(i)
			if sub and sub ~= "" then to:SetSubMaterial(i, sub) end
		end
	end

	local function Collect(ent, bone, set)
		set[bone] = true
		for _, child in ipairs(ent:GetChildBones(bone)) do Collect(ent, child, set) end
	end

	-- видна только оторванная часть: остальные кости сжимаются в точку на месте среза
	local function HideRest(self, count)
		local main = self.remMain and self:GetBoneMatrix(self.remMain)
		if not main then return end
		local pos = main:GetTranslation()
		for i = 0, count - 1 do
			if not self.remKeep[i] then
				local m = self:GetBoneMatrix(i)
				if m then
					m:Scale(vector_origin)
					m:SetTranslation(pos)
					self:SetBoneMatrix(i, m)
				end
			end
		end
	end

	local function RemoveLimb(i)
		local e = table.remove(limbs, i)
		if e and IsValid(e.model) then e.model:Remove() end
	end

	net.Receive("rem_lgore_limb", function()
		local src, bone, gib = net.ReadEntity(), net.ReadString(), net.ReadEntity()
		if not IsValid(gib) or not LG.Enabled() then return end
		local mdl = ClientsideModel(gib:GetModel())
		if not IsValid(mdl) then return end
		CopyLook(src, mdl)
		mdl:SetLOD(0)
		mdl:SetParent(gib)
		mdl:AddEffects(EF_BONEMERGE)
		mdl.remMain = mdl:LookupBone(bone)
		if not mdl.remMain then mdl:Remove() return end
		mdl.remKeep = {}
		Collect(mdl, mdl.remMain, mdl.remKeep)
		mdl:AddCallback("BuildBonePositions", HideRest)
		limbs[#limbs + 1] = {model = mdl, parent = gib}
		while #limbs > max_limbs do RemoveLimb(1) end
	end)

	-- обрубки Lambda сделаны под пропорции L4D и прячутся в рукаве / штанине: увеличиваем вокруг места отрыва
	-- и выдвигаем наружу вдоль плеча / бедра
	local cvScale = CreateClientConVar("rem_lambdagore_stump_scale", 1.35, true, false, "Lambda gore stump size", 0.5, 3)
	local cvPush = CreateClientConVar("rem_lambdagore_stump_push", 1.5, true, false, "Lambda gore stump shift out of the sleeve", -10, 10)
	local STUMP_CUT = { -- кость обрубка -> кость, с которой начинается оторванная часть (место отрыва)
		["ValveBiped.Bip01_L_UpperArm"] = "ValveBiped.Bip01_L_Forearm",
		["ValveBiped.Bip01_R_UpperArm"] = "ValveBiped.Bip01_R_Forearm",
		["ValveBiped.Bip01_L_Thigh"] = "ValveBiped.Bip01_L_Calf",
		["ValveBiped.Bip01_R_Thigh"] = "ValveBiped.Bip01_R_Calf",
	}
	local function FitStump(self, count)
		local parent = self:GetParent()
		if not IsValid(parent) then return end
		local k, push = cvScale:GetFloat(), cvPush:GetFloat()
		for i = 0, count - 1 do
			local cutName = STUMP_CUT[self:GetBoneName(i)]
			local cut = cutName and parent:LookupBone(cutName)
			local m = self:GetBoneMatrix(i)
			local cm = cut and parent:GetBoneMatrix(cut)
			if m and cm then
				local p = cm:GetTranslation()
				local fit = Matrix()
				fit:Translate(p + m:GetForward() * push)
				fit:Scale(Vector(k, k, k))
				fit:Translate(-p)
				self:SetBoneMatrix(i, fit * m)
			end
		end
	end

	local function ClearStumps(ent)
		local t = stumps[ent]
		if not t then return end
		for _, m in pairs(t) do if IsValid(m) then m:Remove() end end
		stumps[ent] = nil
	end

	-- обрубки на теле: у игрока - на том, кем он сейчас нарисован (сам игрок или его рэгдолл), и на трупах
	local function SyncStumps()
		for i = #limbs, 1, -1 do
			if not IsValid(limbs[i].parent) or not IsValid(limbs[i].model) then RemoveLimb(i) end
		end

		local want = {}
		if LG.Enabled() then
			for _, ply in player.Iterator() do
				local org = ply.organism
				local char = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply)
				if org and IsValid(char) and ply:Alive() then want[char] = org end
			end
			for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
				local org = rag.new_organism or rag.organism
				if org and not want[rag] then want[rag] = org end
			end
		end

		for ent in pairs(stumps) do
			if not IsValid(ent) or not want[ent] then ClearStumps(ent) end
		end

		for ent, org in pairs(want) do
			local torsoSevered = ent:GetNWBool("hgTorsoSevered", false) -- ноги у разорванного пополам - отдельно
			local hidden = ent:IsDormant() or ent:GetNoDraw()
			for limb, model in pairs(LG.Stump) do
				local need = org[limb .. "amputated"] and not (torsoSevered and (limb == "lleg" or limb == "rleg"))
				local t = stumps[ent]
				local m = t and t[limb]
				if need and not IsValid(m) then
					m = ClientsideModel(model)
					if IsValid(m) then
						m:SetParent(ent)
						m:AddEffects(EF_BONEMERGE)
						m:AddCallback("BuildBonePositions", FitStump)
						stumps[ent] = stumps[ent] or {}
						stumps[ent][limb] = m
					end
				elseif not need and IsValid(m) then
					m:Remove()
					t[limb] = nil
				end
				if IsValid(m) then m:SetNoDraw(hidden) end
			end
		end
	end
	timer.Create("rem_lambdagore_stumps", 0.3, 0, function() ProtectedCall(SyncStumps) end)

	hook.Add("EntityRemoved", "rem_lambdagore", function(ent) ClearStumps(ent) end)
	hook.Add("PreCleanupMap", "rem_lambdagore", function()
		for ent in pairs(stumps) do ClearStumps(ent) end
		for i = #limbs, 1, -1 do RemoveLimb(i) end
	end)
end
