-- Отрезание головы режущим оружием (ножи, мачете, топоры, мечи, бензопила) - модели Zippy's Gore Mod Enhanced:
-- голова отваливается целиком - копия тела, где видна только голова, снизу кусок мяса debris_goredebris02,
-- на шее тела чистый срез headpartial5, из шеи фонтан крови (как у Z-City).
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
-- голова - отрезок от шеи до макушки вдоль кости головы (x кости смотрит к макушке); у регдолла - по физике
-- (матрицы костей регдолла на сервере бывают старые), у стоящего игрока - по матрице кости
local function HeadHit(body, pos)
	if not IsValid(body) or not pos then return false end
	local hb = body:LookupBone("ValveBiped.Bip01_Head1")
	if not hb then return false end
	local hpos, hang
	if body:IsRagdoll() then
		local phys = body:GetPhysicsObjectNum(body:TranslateBoneToPhysBone(hb))
		if IsValid(phys) then hpos, hang = phys:GetPos(), phys:GetAngles() end
	end
	if not hpos then
		body:SetupBones()
		local m = body:GetBoneMatrix(hb)
		if m then hpos, hang = m:GetTranslation(), m:GetAngles() end
	end
	if not hpos then return false end
	local up = hang:Forward()
	local a, b = hpos - up * 6, hpos + up * 9 -- шея .. макушка
	local ab = b - a
	local t = math.Clamp((pos - a):Dot(ab) / ab:LengthSqr(), 0, 1)
	return pos:DistToSqr(a + ab * t) < 8 * 8
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
	if hits < MIN_HITS then
		print(("[rem_decap] head hit %d/%d (%s)"):format(hits, MIN_HITS, kind))
		return
	end
	if math.random() >= KIND_CHANCE[kind] then
		print(("[rem_decap] head hit %d, chance %d%% - not this time"):format(hits, KIND_CHANCE[kind] * 100))
		return
	end

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
-- модели и расстановка - из Zippy's Gore Mod Enhanced (dismemberment.lua): на шее тела чистый срез headpartial5,
-- снизу у головы кусок мяса debris_goredebris02 (масштаб 3x3x2)
local NECK_CAP = "models/headpartial/headpartial5.mdl"
-- второй вариант обрубка на шее (разнообразие, выбор случайный): срез шеи из Fallout NV - тот же, что ставит Lambda Gore
-- Mod; модель привязана к кости Neck1, поэтому встаёт сама (bonemerge)
local NECK_CAP_FNV = "models/mosi/fnv/props/character/headcap.mdl"
local USE_FNV_NECK = false
local HEAD_CAP = "models/gore/debris_goredebris02.mdl"
-- второй вариант среза под головой - из Lambda Gore Mod (срез Fallout NV, перепривязанный к Head1, ставится сам -
-- bonemerge). Его .vvd в присланном архиве был битый: вариант включается, только если файлы модели целые лежат в игре
local HEAD_CAP_LAMBDA = "models/noob_dev2323/gib/l4d/headcap.mdl"
local function LambdaHeadCapOk()
	return file.Exists("models/noob_dev2323/gib/l4d/headcap.vvd", "GAME") and util.IsValidModel(HEAD_CAP_LAMBDA)
end
local HEAD_LIFE = 300 -- голова лежит столько секунд
local BLEED_TIME = 40
-- срез шеи: угол и сдвиг по типу модели (у Zippy - по имени модели)
local function NeckCapPlace(rag)
	local mdl = string.lower(rag:GetModel() or "")
	if string.find(mdl, "alyx", 1, true) or string.find(mdl, "mossman", 1, true) then return Angle(0, -60, -90), Vector(1, -1, 0) end
	if (ThatPlyIsFemale and ThatPlyIsFemale(rag)) or string.find(mdl, "female", 1, true) then return Angle(0, -60, -90), Vector(1, -2, 0) end
	return Angle(0, -70, -90), Vector(2.2, -2, 0)
end
for _, f in ipairs({
	"models/headpartial/headpartial5.mdl", "models/headpartial/headpartial5.vvd",
	"models/headpartial/headpartial5.dx80.vtx", "models/headpartial/headpartial5.dx90.vtx",
	"materials/models/headpartial/headvar1.vmt", "materials/models/headpartial/headvar1_basecolor.vtf",
	"materials/models/headpartial/headvar1_bump.vtf", "materials/models/headpartial/headvar1_phongexp.vtf",
	"materials/models/headpartial/headvar5.vmt", "materials/models/headpartial/headvar5_basecolor.vtf",
	"materials/models/headpartial/headvar5_bump.vtf", "materials/models/headpartial/headvar5_phongexp.vtf",
	"models/gore/debris_goredebris02.mdl", "models/gore/debris_goredebris02.vvd", "models/gore/debris_goredebris02.phy",
	"models/gore/debris_goredebris02.dx80.vtx", "models/gore/debris_goredebris02.dx90.vtx",
	"materials/models/gore/gorehumanhead.vmt", "materials/models/gore/gorehumanhead_d.vtf",
	"materials/models/gore/gorehumanhead_n.vtf", "materials/models/gore/gorehumanhead_exp.vtf",
	"models/mosi/fnv/props/character/headcap.mdl", "models/mosi/fnv/props/character/headcap.vvd",
	"models/mosi/fnv/props/character/headcap.phy", "models/mosi/fnv/props/character/headcap.dx80.vtx",
	"models/mosi/fnv/props/character/headcap.dx90.vtx",
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

-- модель, прилипающая костями к телу (bonemerge). Как у Lambda (gore_mod_bonemerge_prop) и Z-City (кишки):
-- родитель + точка крепления, иначе модель встаёт в корень тела (таз)
local function BonemergeProp(parent, model)
	local att
	for _, a in pairs(parent:GetAttachments() or {}) do att = a.name end
	if not att then return nil end
	local p = ents.Create("prop_dynamic")
	if not IsValid(p) then return nil end
	p:SetModel(model)
	p:SetPos(parent:GetPos())
	p:SetParent(parent)
	p:Fire("SetParentAttachment", att)
	p:Spawn()
	p:Activate()
	p:SetSolid(SOLID_NONE)
	p:DrawShadow(false)
	p:AddEffects(EF_BONEMERGE)
	parent:DeleteOnRemove(p)
	return p
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
	-- лишние кости: в ноль, а кости без физики ещё и сдвигаем в начало родителя (их местное смещение - обратно).
	-- Физические кости каждый тик стоят в начале головы (Think ниже), значит всё тело собирается в одну точку у
	-- среза - даже если клиентское сжатие (cl_decap.lua) не сработало. Иначе воротник и плечи торчат вокруг головы
	e:SetupBones()
	for b = 0, e:GetBoneCount() - 1 do
		if not keep[b] then
			e:ManipulateBoneScale(b, Vector(0, 0, 0))
			local physB = e:TranslateBoneToPhysBone(b)
			local isPhys = physB and physB >= 0 and e:TranslatePhysBoneToBone(physB) == b
			local parent = e:GetBoneParent(b)
			if not isPhys and parent and parent >= 0 then
				local mb, mp = e:GetBoneMatrix(b), e:GetBoneMatrix(parent)
				if mb and mp then
					local lpos = WorldToLocal(mb:GetTranslation(), mb:GetAngles(), mp:GetTranslation(), mp:GetAngles())
					e:ManipulateBonePosition(b, -lpos)
				end
			end
		end
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
	-- срез снизу головы: случайно - кусок мяса Zippy на кости головы или срез Lambda (bonemerge, если есть)
	if LambdaHeadCapOk() and math.random(2) == 1 then
		BonemergeProp(e, HEAD_CAP_LAMBDA)
	elseif util.IsValidModel(HEAD_CAP) then
		local cap = ents.Create("prop_dynamic")
		if IsValid(cap) then
			cap:SetModel(HEAD_CAP)
			cap:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
			cap:SetNotSolid(true)
			cap:DrawShadow(false)
			cap:Spawn()
			cap:ManipulateBoneScale(0, Vector(3, 3, 2))
			cap:FollowBone(e, root)
			cap:SetLocalPos(Vector(2, -2, 0))
			cap:SetLocalAngles(Angle(0, 0, 0))
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
	if not IsValid(rag) or not rag:IsRagdoll() then print("[rem_decap] not a ragdoll: " .. tostring(rag)) return end
	if rag.noHead or rag.headexploded then print("[rem_decap] ragdoll already headless: " .. tostring(rag)) return end
	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
	if not head or not neck then print("[rem_decap] no head/neck bone on " .. tostring(rag:GetModel())) return end
	rag.noHead, rag.headexploded = true, true

	SpawnHead(rag, head, force)

	-- на теле голову убрать (Z-City: кость в ноль, без столкновений)
	if Gib_RemoveBone then Gib_RemoveBone(rag, head, rag:TranslateBoneToPhysBone(head)) end
	if rag.SetNetVar then rag:SetNetVar("Accessories", "none") end -- шапки ушли с головой

	-- обрубок на шее: случайно - срез Zippy (headpartial5, ставим по кости шеи) или срез Fallout NV (bonemerge)
	-- срез Fallout NV на шее: у модели свой скелет, к шее Z-City встаёт боком на плечо - отключён (USE_FNV_NECK)
	local useFNV = USE_FNV_NECK and util.IsValidModel(NECK_CAP_FNV) and (math.random(2) == 1 or not util.IsValidModel(NECK_CAP))
	if useFNV then
		BonemergeProp(rag, NECK_CAP_FNV)
	elseif util.IsValidModel(NECK_CAP) then
		local gap = ents.Create("prop_dynamic")
		if IsValid(gap) then
			gap:SetModel(NECK_CAP)
			gap:Spawn()
			gap:SetNotSolid(true)
			gap:DrawShadow(false)
			gap:FollowBone(rag, neck)
			local ang, pos = NeckCapPlace(rag)
			gap:SetLocalAngles(ang)
			gap:SetLocalPos(pos)
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

	print("[rem_decap] head cut off: " .. tostring(rag))
	local org = rag.organism
	if org then
		org.headamputated = true
		if IsValid(org.owner) then
			org.owner.fullsend = true
			if hg.send_bareinfo then hg.send_bareinfo(org) end
		end
	end
end

local function Log(msg) print("[rem_decap] " .. msg) end

-- регдолл смерти игрока: так же ищет Z-City (sv_torsohalve.lua FindDeathRagdoll) + запасной поиск рядом
local function DeathRagdoll(ply)
	if IsValid(ply.RagdollDeath) then return ply.RagdollDeath end
	local nw = ply:GetNWEntity("RagdollDeath")
	if IsValid(nw) then return nw end
	if IsValid(ply.FakeRagdoll) then return ply.FakeRagdoll end
	for _, e in ipairs(ents.FindInSphere(ply:GetPos(), 200)) do
		if e:IsRagdoll() and (e:GetNWEntity("ply") == ply or (hg.RagdollOwner and hg.RagdollOwner(e) == ply)) then return e end
	end
	return nil
end

-- отрезать голову: живого - убить, найти регдолл смерти (ждём до 2 с) и резать чуть позже - пусть встанет в позу,
-- иначе обрубок съедет
function hg.Decapitate(victim, force)
	if not IsValid(victim) then return end
	if victim.noHead or victim.headexploded then Log("already headless: " .. tostring(victim)) return end
	if victim:IsPlayer() then
		if victim:Alive() then victim:Kill() end
		local tries = 0
		local name = "rem_decap_" .. victim:EntIndex()
		timer.Create(name, 0.1, 20, function()
			tries = tries + 1
			if not IsValid(victim) then timer.Remove(name) return end
			local rag = DeathRagdoll(victim)
			if not IsValid(rag) then
				if tries >= 20 then Log("no death ragdoll for " .. victim:Nick()) end
				return
			end
			timer.Remove(name)
			timer.Simple(0.15, function()
				if IsValid(rag) then CutHead(rag, force) end
			end)
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
