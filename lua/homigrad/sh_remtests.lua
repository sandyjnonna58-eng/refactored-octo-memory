-- Команды проверки недавних механик (админ). Цель: часть ника последним аргументом, иначе тот, на кого смотришь
-- (игрок или его регдолл), иначе ты сам. Список - rem_tests.
-- Звуки (только у себя, без прав): rem_test_deathsound [0|1], rem_test_roundsound, rem_test_police,
-- rem_test_headshotsound, rem_test_concsound, rem_test_stopsounds.

local HELP = {
	"--- Проверка механик (сервер, админ; [ник] - цель, без него - на кого смотришь или ты) ---",
	"rem_test_concussion [ник]   - заряженный удар в голову: сотрясение, падение, вспышки, без нокаута",
	"rem_test_ko [ник]           - то же с нокаутом (экран без сознания)",
	"rem_test_headshot [ник]     - звук хедшота у головы цели (не убивает); rem_headshot_sound 1 каждое / 2 только смерть",
	"rem_test_fall [ник]         - уронить в регдолл (реакции регдолла: держится за рану, пытается устоять)",
	"rem_test_epilepsy [ник]     - эпилептический припадок 20 с (как от тока)",
	"rem_test_fire [ник]         - поджечь на 5 с (регдолл катается)",
	"rem_test_clear [ник]        - сбросить сотрясение, нокаут, оглушение",
	"rem_reag_debug 1            - отладка реакций регдолла в консоль сервера",
	"rem_decap_test / rem_halve_test - отрезать голову / разрубить того, на кого смотришь",
	"rem_drug_set heroin|meth|lsd 1, rem_panic_set 0..1, rem_depression_set 0..1, selfharm, zb_lastbattle <ник>",
	"--- Звуки (у себя) ---",
	"rem_test_deathsound [0|1]   - звук смерти (0 brutal, 1 остановка сердца)",
	"rem_test_roundsound         - начало раунда Homicide",
	"rem_test_police             - прибытие полиции / SWAT",
	"rem_test_headshotsound      - хедшот",
	"rem_test_concsound          - случайный звук сотрясения",
	"rem_test_stopsounds         - остановить тестовые звуки",
	"rem_fadingmusic_test 0..1   - музыка при уходе сознания",
}

concommand.Add("rem_tests", function(ply)
	for _, line in ipairs(HELP) do
		if CLIENT or not IsValid(ply) then print(line) else ply:PrintMessage(HUD_PRINTCONSOLE, line) end
	end
end)

if SERVER then
	local function Target(ply, args)
		local name = args[1] and string.lower(table.concat(args, " ")) or nil
		if name and name ~= "" then
			for _, p in player.Iterator() do
				if string.find(string.lower(p:Nick()), name, 1, true) then return p end
			end
			ply:ChatPrint("rem_test: игрок не найден: " .. name)
			return nil
		end
		local tr = util.TraceLine({start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 1000,
			filter = {ply, ply.FakeRagdoll}, mask = MASK_SHOT})
		local ent = tr.Entity
		if IsValid(ent) and ent:IsRagdoll() and hg.RagdollOwner then ent = hg.RagdollOwner(ent) end
		if IsValid(ent) and ent:IsPlayer() then return ent end
		return ply
	end

	local function Cmd(name, fn)
		concommand.Add(name, function(ply, _, args)
			if not IsValid(ply) or not ply:IsAdmin() then return end
			local t = Target(ply, args)
			if not IsValid(t) then return end
			if not t:Alive() or not t.organism then ply:ChatPrint(name .. ": цель мертва или без организма") return end
			local msg = fn(t, t.organism, ply)
			ply:ChatPrint(name .. " -> " .. t:Nick() .. (msg and (": " .. msg) or ""))
		end)
	end

	local function HeadPos(t)
		local body = IsValid(t.FakeRagdoll) and t.FakeRagdoll or t
		local bone = body:LookupBone("ValveBiped.Bip01_Head1")
		return bone and body:GetBonePosition(bone) or t:EyePos()
	end

	Cmd("rem_test_concussion", function(t, org)
		if not hg.organism.PunchConcussion then return "нет sv_concussion" end
		hg.organism.PunchConcussion(t, org, HeadPos(t), false, false)
		return "сотрясение " .. math.Round(org.concussion or 0, 1)
	end)

	Cmd("rem_test_ko", function(t, org)
		if not hg.organism.PunchConcussion then return "нет sv_concussion" end
		hg.organism.PunchConcussion(t, org, HeadPos(t), false, true)
		return "нокаут до " .. math.Round((org.remKOEnd or CurTime()) - CurTime(), 1) .. " с"
	end)

	Cmd("rem_test_headshot", function(t, org, ply)
		local pos = HeadPos(t)
		sound.Play("rem_headshot.ogg", pos, 80, 100, 1)
		net.Start("rem_headshot") net.Send(ply)
	end)

	Cmd("rem_test_fall", function(t)
		hg.Fake(t, nil, nil, true)
	end)

	Cmd("rem_test_epilepsy", function(t, org)
		if not hg.organism.StartEpilepsy then return "нет StartEpilepsy" end
		return hg.organism.StartEpilepsy(t, org, 20) and "начался" or "не начался (уже идёт?)"
	end)

	Cmd("rem_test_fire", function(t)
		local body = IsValid(t.FakeRagdoll) and t.FakeRagdoll or t
		body:Ignite(5)
	end)

	Cmd("rem_test_clear", function(t, org)
		org.concussion = 0
		org.remKOEnd = nil
		org.stun = 0
		org.disorientation = 0
	end)
else
	local chans = {}
	local function Play(path)
		sound.PlayFile("sound/" .. path, "noplay", function(ch)
			if not IsValid(ch) then print("rem_test: не загрузился sound/" .. path) return end
			chans[#chans + 1] = ch
			ch:Play()
		end)
	end

	concommand.Add("rem_test_deathsound", function(_, _, args)
		Play(tonumber(args[1]) == 1 and "rem_heartstop.ogg" or "rem_brutaldeath.mp3")
	end)
	concommand.Add("rem_test_roundsound", function() Play("rem_homicide.mp3") end)
	concommand.Add("rem_test_police", function() Play("rem_hmcd_police.mp3") end)
	concommand.Add("rem_test_headshotsound", function() Play("rem_headshot.ogg") end)
	concommand.Add("rem_test_concsound", function() Play("rem_concussion/concussion" .. math.random(4) .. ".mp3") end)
	concommand.Add("rem_test_stopsounds", function()
		for _, ch in ipairs(chans) do if IsValid(ch) then ch:Stop() end end
		chans = {}
	end)
end
