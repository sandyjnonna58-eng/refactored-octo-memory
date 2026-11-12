-- Отрубание головы режущим оружием (ножи, мачете, топоры, мечи, бензопила) - своё обезглавливание Z-City
-- (hg.ExplodeHead -> Gib_Input: голова убирается, на шее обрубок headpartial, фонтан крови, куски, тело "Beheaded body").
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
	timer.Simple(0, function()
		if IsValid(victim) and hg.ExplodeHead and not victim.headexploded then hg.ExplodeHead(victim, 200, true, force) end
	end)
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
