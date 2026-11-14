-- Звук хедшота (sound/rem_headshot.ogg): попадание пулей/дробью в голову, от которого человек умер сразу
-- (смерть в течение HEADSHOT_WINDOW после попадания). Звучит у головы для всех рядом и отдельно у стрелка,
-- если он далеко (снайпер не услышит точечный звук). Выкл. - rem_headshot_sound 0.
local SND = "rem_headshot.ogg"

if SERVER then
	resource.AddSingleFile("sound/" .. SND)
	util.AddNetworkString("rem_headshot")

	local cvOn = CreateConVar("rem_headshot_sound", "1", FCVAR_ARCHIVE, "headshot sound on instant kill", 0, 1)
	local HEADSHOT_WINDOW = 0.5
	local FAR_DIST = 600 -- дальше - стрелку отдельно, без точки в мире

	hook.Add("HomigradDamage", "rem_headshot", function(ply, dmg, hitgroup, ent)
		if hitgroup ~= HITGROUP_HEAD or not dmg:IsDamageType(DMG_BULLET + DMG_BUCKSHOT) then return end
		if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
		if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
		local pos = dmg:GetDamagePosition()
		if pos == vector_origin then pos = nil end
		ply.remHeadHit = {t = CurTime(), att = dmg:GetAttacker(), pos = pos, body = IsValid(ent) and ent or nil}
	end)

	hook.Add("PlayerDeath", "rem_headshot", function(ply)
		local hit = ply.remHeadHit
		ply.remHeadHit = nil
		if not cvOn:GetBool() or not hit or CurTime() - hit.t > HEADSHOT_WINDOW then return end

		local body = IsValid(hit.body) and hit.body or ply
		local bone = body:LookupBone("ValveBiped.Bip01_Head1")
		local pos = hit.pos or (bone and body:GetBonePosition(bone)) or ply:EyePos()
		sound.Play(SND, pos, 80, math.random(97, 103), 1)

		local att = hit.att
		if IsValid(att) and att:IsPlayer() and att ~= ply and att:EyePos():DistToSqr(pos) > FAR_DIST * FAR_DIST then
			net.Start("rem_headshot")
			net.Send(att)
		end
	end)

	hook.Add("PlayerSpawn", "rem_headshot", function(ply) ply.remHeadHit = nil end)
else
	net.Receive("rem_headshot", function()
		surface.PlaySound(SND)
	end)
end
