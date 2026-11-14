-- Звук хедшота (sound/rem_headshot.ogg): попадание в голову пулей/дробью или оружием ближнего боя (нож, топор,
-- бита и т.п.; кулаки и пинки - нет). rem_headshot_sound: 1 - при каждом попадании в голову (по умолчанию),
-- 2 - только если человек от него сразу умер (за HEADSHOT_WINDOW), 0 - выкл. Звучит у головы для всех рядом и
-- отдельно у стрелка, если он далеко (снайпер не услышит точечный звук).
local SND = "rem_headshot.ogg"

if SERVER then
	resource.AddSingleFile("sound/" .. SND)
	util.AddNetworkString("rem_headshot")

	local cvMode = CreateConVar("rem_headshot_sound", "1", FCVAR_ARCHIVE, "headshot sound: 0 off, 1 every head hit, 2 only instant kill", 0, 2)
	local HEADSHOT_WINDOW = 0.5
	local FAR_DIST = 600 -- дальше - стрелку отдельно, без точки в мире
	local GAP = 0.25     -- не чаще раза в 0.25 с на человека (дробь, многотиковые удары ближнего боя)
	local FISTS = {weapon_hands_sh = true, weapon_hg_coolhands = true}

	local function HeadPos(body)
		local bone = body:LookupBone("ValveBiped.Bip01_Head1")
		if not bone then return end
		if body:IsRagdoll() then
			local phys = body:GetPhysicsObjectNum(body:TranslateBoneToPhysBone(bone))
			if IsValid(phys) then return phys:GetPos() end
		end
		return body:GetBonePosition(bone)
	end

	-- оружие ближнего боя: урон рубящий/тупой, инфликтор - оружие (не руки и не сам игрок - пинок)
	local function IsMelee(dmg)
		if not dmg:IsDamageType(DMG_SLASH + DMG_CLUB) then return false end
		local wep = dmg:GetInflictor()
		return IsValid(wep) and wep:IsWeapon() and not FISTS[wep:GetClass()]
	end

	local function Play(ply, hit)
		if CurTime() - (ply.remHeadshotSnd or 0) < GAP then return end
		ply.remHeadshotSnd = CurTime()
		local body = IsValid(hit.body) and hit.body or ply
		local pos = hit.pos or HeadPos(body) or ply:EyePos()
		sound.Play(SND, pos, 80, math.random(97, 103), 1)

		local att = hit.att
		if IsValid(att) and att:IsPlayer() and att ~= ply and att:EyePos():DistToSqr(pos) > FAR_DIST * FAR_DIST then
			net.Start("rem_headshot")
			net.Send(att)
		end
	end

	hook.Add("HomigradDamage", "rem_headshot", function(ply, dmg, hitgroup, ent)
		local mode = cvMode:GetInt()
		if mode == 0 then return end
		local bullet = dmg:IsDamageType(DMG_BULLET + DMG_BUCKSHOT)
		if not bullet and not IsMelee(dmg) then return end
		if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
		if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end

		local pos = dmg:GetDamagePosition()
		if pos == vector_origin then pos = nil end
		local body = IsValid(ent) and ent or (IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or ply)
		local head = hitgroup == HITGROUP_HEAD
		if not head and pos then
			-- у ближнего боя hitgroup бывает не головой - проверяем по точке удара
			local hp = HeadPos(body)
			head = hp and hp:DistToSqr(pos) < 12 * 12 or false
		end
		if not head then return end

		local hit = {t = CurTime(), att = dmg:GetAttacker(), pos = pos, body = body}
		if mode == 1 then
			Play(ply, hit)
		else
			ply.remHeadHit = hit -- режим 2: ждём смерть
		end
	end)

	hook.Add("PlayerDeath", "rem_headshot", function(ply)
		local hit = ply.remHeadHit
		ply.remHeadHit = nil
		if cvMode:GetInt() ~= 2 or not hit or CurTime() - hit.t > HEADSHOT_WINDOW then return end
		Play(ply, hit)
	end)

	hook.Add("PlayerSpawn", "rem_headshot", function(ply) ply.remHeadHit = nil end)
else
	net.Receive("rem_headshot", function()
		surface.PlaySound(SND)
	end)
end
