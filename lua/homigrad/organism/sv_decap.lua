-- Отрезание головы режущим оружием (ножи, мачете, топоры, мечи, бензопила) - по Lambda Gore Mod (модели мода,
-- права на копию у пользователя): голова отваливается целиком - копия тела, где видна только голова, снизу срез
-- headcap (bonemerge), на шее тела обрубок common_infected_w_neck, из шеи фонтан крови (как у Z-City).
-- Голова на земле - cl_decap.lua (остальные кости сжаты в точку среза, кровь из шеи).
-- Обычно Z-City сносит голову с одного сильного удара; для этого оружия так нельзя (sv_input.lua спрашивает
-- hg.RemDecapBlocks): голова отлетает не раньше MIN_HITS-го удара по голове/шее, дальше - по шансу (CHANCE по виду).
-- Бензопила: каждые SAW_STEP с пиления головы - один "удар". Удар - раз за взмах (режущее оружие бьёт каждый тик).
local cvOn = CreateConVar("rem_decap", "1", FCVAR_ARCHIVE, "Cutting weapons can cut the head off (from the 4th head hit, random)", 0, 1)

local MIN_HITS = 4
local SWING_GAP = 0.6
local SAW_STEP = 0.5

-- вид оружия по классу: шанс отрубить голову за удар (начиная с MIN_HITS-го)
local KIND_CHANCE = {knife = 0.2, machete = 0.35, axe = 0.45, sword = 0.5, saw = 0.6}
local CLASS_KIND = {
	weapon_buck200knife = "knife", weapon_combatknife = "knife", weapon_sogknife = "knife", weapon_pocketknife = "knife",
	weapon_hg_spear_knife = "knife",
	weapon_hg_machete = "machete", weapon_fc3_machete = "machete", weapon_fc3_tribalknife = "machete",
	weapon_hg_axe = "axe", weapon_hatchet = "axe",
	weapon_hg_katana = "sword", weapon_hg_slayersword = "sword",
	weapon_chainsaw = "saw",
}
-- оружие из других наборов - по имени класса
local PATTERNS = {{"chainsaw", "saw"}, {"katana", "sword"}, {"sword", "sword"}, {"axe", "axe"}, {"hatchet", "axe"},
	{"machete", "machete"}, {"knife", "knife"}, {"bayonet", "knife"}}

local function Kind(wep)
	if not IsValid(wep) or not wep:IsWeapon() then return nil end
	local class = wep:GetClass()
	if CLASS_KIND[class] then return CLASS_KIND[class] end
	for _, p in ipairs(PATTERNS) do
		if string.find(class, p[1], 1, true) then return p[2] end
	end
	return nil
end

-- sv_input.lua: не сносить голову с одного удара, если бьёт это оружие (решаем здесь)
function hg.RemDecapBlocks(dmgInfo)
	return cvOn:GetBool() and Kind(dmgInfo:GetInflictor()) ~= nil
end

local function Owner(ent)
	if not IsValid(ent) then return nil end
	if ent:IsPlayer() then return ent end
	local ply = hg.RagdollOwner and hg.RagdollOwner(ent) or ent:GetNWEntity("ply")
	return IsValid(ply) and ply:IsPlayer() and ply or nil
end

local function BonePos(ent, name)
	local b = ent:LookupBone(name)
	if not b then return nil end
	local m = ent:GetBoneMatrix(b)
	return m and m:GetTranslation() or ent:GetBonePosition(b)
end

-- удар по голове или шее?
local function HeadHit(body, pos)
	if not IsValid(body) or not pos then return false end
	local head, neck = BonePos(body, "ValveBiped.Bip01_Head1"), BonePos(body, "ValveBiped.Bip01_Neck1")
	if head and pos:DistToSqr(head + (head - (neck or head)) * 0.5) < 10 * 10 then return true end
	if neck and pos:DistToSqr(neck) < 7 * 7 then return true end
	return false
end

local function OnDamage(target, dmg)
	if not cvOn:GetBool() or not IsValid(target) then return end
	if not (target:IsPlayer() or target:IsRagdoll()) or target.headexploded or target.noHead then return end
	local wep = dmg:GetInflictor()
	local kind = Kind(wep)
	if not kind then return end
	local attacker = dmg:GetAttacker()
	local ply = Owner(target)
	if IsValid(ply) and ply == attacker then return end -- себе не рубим

	local body = target
	if target:IsPlayer() then body = hg.GetCurrentCharacter and hg.GetCurrentCharacter(target) or target end
	if not IsValid(body) or body.headexploded or body.noHead then return end
	if not HeadHit(body, dmg:GetDamagePosition()) then return end

	-- один "удар" - раз за взмах (у пилы - раз в SAW_STEP пиления)
	local holder = IsValid(ply) and ply or target
	local now = CurTime()
	wep.__remDecapNext = wep.__remDecapNext or setmetatable({}, {__mode = "k"})
	if (wep.__remDecapNext[holder] or 0) > now then return end
	wep.__remDecapNext[holder] = now + (kind == "saw" and SAW_STEP or SWING_GAP)

	local hits = (holder.__remHeadHits or 0) + 1
	holder.__remHeadHits = hits
	if hits < MIN_HITS or math.random() >= KIND_CHANCE[kind] then return end

	local force = (IsValid(attacker) and attacker:GetAimVector() or dmg:GetDamageForce():GetNormalized()) * 300
	local victim = (IsValid(ply) and ply:Alive() and (target == ply or target == ply.FakeRagdoll)) and ply or body
	timer.Simple(0, function() hg.Decapitate(victim, force) end)
end

hook.Add("EntityTakeDamage", "rem_decap", function(target, dmg) OnDamage(target, dmg) end)
hook.Add("PostEntityTakeDamage", "rem_decap", function(target, dmg)
	-- второй хук на случай, если первый заблокирован; тот же удар второй раз не посчитается (пауза взмаха)
	OnDamage(target, dmg)
end)

hook.Add("PlayerSpawn", "rem_decap_reset", function(ply) ply.__remHeadHits = nil end)
hook.Add("Org Clear", "rem_decap_reset", function(org)
	local ply = istable(org) and org.owner
	if IsValid(ply) then ply.__remHeadHits = nil end
end)

-- ================= само отрезание =================
local NECK_CAP = "models/noob_dev2323/gib/l4d/common_infected_w_neck.mdl"
local HEAD_CAP = "models/noob_dev2323/gib/l4d/headcap.mdl"
local NECK_ANG = Angle(180, 110, 90)                               -- из мода (giblist.lua, bone_name_togap)
local NECK_POS, NECK_POS_F = Vector(-0.812, -2.608, 0), Vector(-2.912, -2.608, 0)
local HEAD_LIFE = 300
local BLEED_TIME = 40
for _, f in ipairs({
	"models/noob_dev2323/gib/l4d/common_infected_w_neck.mdl", "models/noob_dev2323/gib/l4d/common_infected_w_neck.vvd",
	"models/noob_dev2323/gib/l4d/common_infected_w_neck.dx80.vtx", "models/noob_dev2323/gib/l4d/common_infected_w_neck.dx90.vtx",
	"models/noob_dev2323/gib/l4d/headcap.mdl", "models/noob_dev2323/gib/l4d/headcap.vvd", "models/noob_dev2323/gib/l4d/headcap.phy",
	"models/noob_dev2323/gib/l4d/headcap.dx80.vtx", "models/noob_dev2323/gib/l4d/headcap.dx90.vtx",
	"materials/models/noob_dev2323/gibs/l4d/master_wound_cmapmaterial.vmt", "materials/models/noob_dev2323/gibs/l4d/master_wound_cmap.vtf",
	"materials/models/noob_dev2323/gibs/l4d/master_wound_normal.vtf",
	"materials/models/mosi/fnv/props/character/meatcapgore01.vmt", "materials/models/mosi/fnv/props/character/meatcapinsect.vmt",
	"materials/models/mosi/fnv/props/character/meatcapgore01grey.vmt", "materials/models/mosi/fnv/props/character/meatcapgore01grey.vtf",
	"materials/models/mosi/fnv/props/character/meatcapgore01grey2.vmt", "materials/models/mosi/fnv/props/character/meatcapgore01grey2.vtf",
	"materials/models/mosi/fnv/props/gore/meatcapgore01.vtf", "materials/models/mosi/fnv/props/gore/meatcapgore01_n.vtf",
	"materials/models/mosi/fnv/props/gore/meatcapinsect.vtf", "materials/models/mosi/fnv/props/gore/meatcapinsect_n.vtf",
}) do resource.AddSingleFile(f) end

local headsAlive = {}

local function Collect(ent, bone, out)
	out[bone] = true
	for _, c in ipairs(ent:GetChildBones(bone) or {}) do
		if not out[c] then Collect(ent, c, out) end
	end
end

local function CopyLook(src, dst)
	dst:SetSkin(src:GetSkin() or 0)
	dst:SetColor(src:GetColor())
	dst:SetMaterial(src:GetMaterial() or "")
	for _, g in ipairs(src:GetBodyGroups() or {}) do dst:SetBodygroup(g.id, src:GetBodygroup(g.id)) end
	for i = 0, #(src:GetMaterials() or {}) - 1 do dst:SetSubMaterial(i, src:GetSubMaterial(i) or "") end
	dst:SetNWVector("PlayerColor", src:GetNWVector("PlayerColor", vector_origin))
	dst:SetNWString("PlayerName", src:GetNWString("PlayerName", "Head"))
	for k = 1, 8 do
		local c = src:GetNWString("Colthes" .. k, "")
		if c ~= "" then dst:SetNWString("Colthes" .. k, c) end
	end
	if dst.SetNetVar and src.GetNetVar then
		dst:SetNetVar("Accessories", src:GetNetVar("Accessories", "none")) -- шапки/очки - на голове
		dst:SetNetVar("Armor", {})
	end
end

-- голова отдельно: копия регдолла, видны только Head1 и потомки; остальные кости сжаты в ноль (на клиенте -
-- в одну точку у среза, cl_decap.lua) и каждый тик едут за головой
local function SpawnHead(rag, headBone, force)
	local e = ents.Create("prop_ragdoll")
	if not IsValid(e) then return nil end
	e:SetModel(rag:GetModel())
	e:SetPos(rag:GetPos())
	e:SetAngles(rag:GetAngles())
	e:Spawn()
	if e:GetPhysicsObjectCount() < 2 then e:Remove() return nil end
	e:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	CopyLook(rag, e)
	for i = 0, math.min(rag:GetPhysicsObjectCount(), e:GetPhysicsObjectCount()) - 1 do
		local a, b = rag:GetPhysicsObjectNum(i), e:GetPhysicsObjectNum(i)
		if IsValid(a) and IsValid(b) then
			b:SetPos(a:GetPos())
			b:SetAngles(a:GetAngles())
			b:SetVelocity(a:GetVelocity())
		end
	end
	local root = e:LookupBone("ValveBiped.Bip01_Head1")
	local rootPhys = root and e:TranslateBoneToPhysBone(root)
	if not rootPhys or rootPhys < 0 then e:Remove() return nil end
	local keep = {}
	Collect(e, root, keep)
	for b = 0, e:GetBoneCount() - 1 do
		if not keep[b] then e:ManipulateBoneScale(b, Vector(0, 0, 0)) end
	end
	local hidden = {}
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		if i ~= rootPhys then
			local phys = e:GetPhysicsObjectNum(i)
			if IsValid(phys) then
				phys:EnableCollisions(false)
				phys:SetMass(0.1)
				phys:EnableMotion(false)
				hidden[#hidden + 1] = i
			end
		end
	end
	e:RemoveInternalConstraint(rootPhys)
	local rp = e:GetPhysicsObjectNum(rootPhys)
	if IsValid(rp) then
		rp:Wake()
		rp:AddVelocity((force or vector_origin) * 0.6 + VectorRand(-40, 40) + Vector(0, 0, 80))
		rp:AddAngleVelocity(VectorRand(-300, 300))
	end
	-- срез снизу головы (bonemerge к голове)
	if util.IsValidModel(HEAD_CAP) then
		local cap = ents.Create("prop_dynamic")
		if IsValid(cap) then
			cap:SetModel(HEAD_CAP)
			cap:SetPos(e:GetPos())
			cap:SetParent(e)
			cap:Spawn()
			cap:SetSolid(SOLID_NONE)
			cap:AddEffects(EF_BONEMERGE)
			e:DeleteOnRemove(cap)
		end
	end
	e:SetNW2Bool("rem_head", true)
	e:SetNW2Int("rem_head_bone", root)
	e:SetNW2Float("rem_head_bleed", CurTime() + BLEED_TIME)
	e:AddCallback("PhysicsCollide", function(ent, data)
		if data.DeltaTime < 0.15 or data.Speed < 60 then return end
		ent:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 65, math.random(95, 110), 0.7)
		if ent:GetNW2Float("rem_head_bleed", 0) > CurTime() then
			util.Decal("Blood", data.HitPos + data.HitNormal * 2, data.HitPos - data.HitNormal * 4, ent)
		end
	end)
	SafeRemoveEntityDelayed(e, HEAD_LIFE)
	headsAlive[#headsAlive + 1] = {ent = e, rootPhys = rootPhys, hidden = hidden}
	while #headsAlive > 12 do
		local old = table.remove(headsAlive, 1)
		if IsValid(old.ent) then old.ent:Remove() end
	end
	return e
end

hook.Add("Think", "rem_decap_heads", function()
	for i = #headsAlive, 1, -1 do
		local h = headsAlive[i]
		if not IsValid(h.ent) then
			table.remove(headsAlive, i)
		else
			local rp = h.ent:GetPhysicsObjectNum(h.rootPhys)
			if IsValid(rp) and not rp:IsAsleep() then
				local pos, ang = rp:GetPos(), rp:GetAngles()
				for _, id in ipairs(h.hidden) do
					local phys = h.ent:GetPhysicsObjectNum(id)
					if IsValid(phys) then phys:SetPos(pos) phys:SetAngles(ang) end
				end
			end
		end
	end
end)

-- отрезать голову у регдолла
local function CutHead(rag, force)
	if not IsValid(rag) or not rag:IsRagdoll() or rag.noHead or rag.headexploded then return end
	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
	if not head or not neck then return end
	rag.noHead, rag.headexploded = true, true

	SpawnHead(rag, head, force)

	-- на теле голову убрать (Z-City: кость в ноль, без столкновений)
	if Gib_RemoveBone then Gib_RemoveBone(rag, head, rag:TranslateBoneToPhysBone(head)) end
	if rag.SetNetVar then rag:SetNetVar("Accessories", "none") end -- шапки ушли с головой

	-- обрубок на шее
	if util.IsValidModel(NECK_CAP) then
		local gap = ents.Create("prop_dynamic")
		if IsValid(gap) then
			gap:SetModel(NECK_CAP)
			gap:Spawn()
			gap:SetNotSolid(true)
			gap:DrawShadow(false)
			gap:FollowBone(rag, neck)
			gap:SetLocalAngles(NECK_ANG)
			gap:SetLocalPos((ThatPlyIsFemale and ThatPlyIsFemale(rag)) and NECK_POS_F or NECK_POS)
			rag:DeleteOnRemove(gap)
		end
	end

	-- шлем/маска падают (как у Z-City)
	local armors = rag.GetNetVar and rag:GetNetVar("Armor", {}) or {}
	local headPhys = rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(head))
	for _, slot in ipairs({"head", "face"}) do
		if armors[slot] and hg.armor and hg.armor[slot] and hg.armor[slot][armors[slot]] and not hg.armor[slot][armors[slot]].nodrop and hg.DropArmorForce then
			local a = hg.DropArmorForce(rag, armors[slot])
			if IsValid(a) and IsValid(headPhys) then a:SetPos(headPhys:GetPos()) end
		end
	end

	rag:SetNWString("PlayerName", "Beheaded body")
	rag:EmitSound("physics/body/body_medium_break" .. math.random(2, 4) .. ".wav", 75, math.random(90, 105))
	rag:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(4) .. ".wav", 75)

	-- фонтан крови из шеи (Z-City)
	if hg.fountains then
		net.Start("addfountain")
		net.WriteEntity(rag)
		net.WriteVector(force or vector_origin)
		net.Broadcast()
		hg.fountains[rag] = {bone = neck, lpos = (ThatPlyIsFemale and ThatPlyIsFemale(rag)) and Vector(4, 0, 0) or Vector(5, 0, 0), lang = Angle(0, 0, 0)}
		rag:CallOnRemove("removefountain", function()
			hg.fountains[rag] = nil
			SetNetVar("fountains", hg.fountains)
		end)
		SetNetVar("fountains", hg.fountains)
	end

	local org = rag.organism
	if org then
		org.headamputated = true
		if IsValid(org.owner) then
			org.owner.fullsend = true
			if hg.send_bareinfo then hg.send_bareinfo(org) end
		end
	end
end

-- отрезать голову: живого - убить и резать регдолл смерти (чуть позже - пусть встанет в позу, иначе обрубок съедет)
function hg.Decapitate(victim, force)
	if not IsValid(victim) or victim.noHead or victim.headexploded then return end
	if victim:IsPlayer() then
		if victim:Alive() then victim:Kill() end
		timer.Simple(0.15, function()
			if not IsValid(victim) then return end
			local rag = victim:GetNWEntity("RagdollDeath")
			if not IsValid(rag) then rag = victim.FakeRagdoll end
			CutHead(rag, force)
		end)
		return
	end
	if victim:IsRagdoll() then
		local ply = Owner(victim)
		if IsValid(ply) and ply:Alive() and ply.FakeRagdoll == victim then
			hg.Decapitate(ply, force)
			return
		end
		CutHead(victim, force)
	end
end

-- проверка (админ): rem_decap_test - отрезать голову тому, на кого смотришь
concommand.Add("rem_decap_test", function(ply)
	if not IsValid(ply) or not ply:IsAdmin() then return end
	local tr = util.TraceLine({start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 300, filter = {ply, ply.FakeRagdoll}, mask = MASK_SHOT})
	if IsValid(tr.Entity) and (tr.Entity:IsPlayer() or tr.Entity:IsRagdoll()) then
		hg.Decapitate(tr.Entity, ply:GetAimVector() * 300)
	else
		ply:ChatPrint("rem_decap_test: look at a player or a body")
	end
end)
