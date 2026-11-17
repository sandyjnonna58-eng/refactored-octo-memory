-- Команды проверки недавних механик (админ). Цель: часть ника последним аргументом, иначе тот, на кого смотришь
-- (игрок или его регдолл), иначе ты сам. Список - rem_tests.
-- Звуки (только у себя, без прав): rem_test_deathsound [0|1], rem_test_roundsound, rem_test_police,
-- rem_test_headshotsound, rem_test_concsound, rem_test_heartstopsound, rem_test_stopsounds.

local HELP = {
	"--- Проверка механик (сервер, админ; [ник] - цель, без него - на кого смотришь или ты) ---",
	"rem_test_concussion [ник]   - заряженный удар в голову: сотрясение, падение, вспышки, без нокаута",
	"rem_test_ko [ник]           - то же с нокаутом (экран без сознания)",
	"rem_test_headshot [ник]     - звук хедшота у головы цели (не убивает); rem_headshot_sound 1 каждое / 2 только смерть",
	"rem_test_fall [ник]         - уронить в регдолл (реакции регдолла: держится за рану, пытается устоять)",
	"rem_test_epilepsy [ник]     - эпилептический припадок 20 с (как от тока)",
	"rem_test_fire [ник]         - поджечь на 5 с (регдолл катается)",
	"rem_test_clear [ник]        - сбросить сотрясение, нокаут, оглушение",
	"rem_test_heartstop [ник]    - остановить сердце (звук остановки; умрёт, если не завести дефибриллятором)",
	"rem_test_spine [ник]        - сломать поясницу и уронить: ноги парализованы, реакции/Artagdoll их не крутят",
	"rem_reag_debug 1            - отладка реакций регдолла в консоль сервера",
	"rem_reag_headshot_kind decerebrate|stiffen|limp|drop - какой будет реакция на смертельный выстрел в голову (пусто - случайно)",
	"  (реакции Artagdoll: кувырок - бросить тело взрывом/машиной; вода; корчи - боль > 50% лёжа; ползком - на животе + W)",
	"rem_decap_test / rem_halve_test - отрезать голову / разрубить того, на кого смотришь",
	"rem_drug_set heroin|meth|lsd 1, rem_panic_set 0..1, rem_depression_set 0..1, selfharm, zb_lastbattle <ник>",
	"rem_test_vac                - состояние совместимости с V.A.C. (аддон найден, сидишь в его технике, чья камера)",
	"rem_test_rvb                - то же для Realistic Vehicles Base (RVB)",
	"rem_debug_vehexit 1         - сервер: кто и когда высадил из техники (карта, сиденье, стек вызова) - в консоль сервера",
	"rem_debug_dmg 1             - сервер: кто гасит/меняет урон пуль по игрокам (хуки, hitgroup, мозг/кровь до и после)",
	"rem_debug_bend 1            - сервер: тело сложилось пополам / шею вывернуло - кто тянул (Artagdoll, реакции, кости)",
	"rem_test_artag              - мод Artagdoll найден / связка включена (тела погибших игроков отдаются ему)",
	"rem_test_pose decorticate|cower [ник] - поза Artagdoll (уронит в регдолл): decorticate - без сознания при тяжёлой",
	"                              травме мозга (руки к груди, ноги вытянуты; 4 с), cower - сжался от боли на грани (5 с)",
	"rem_test_pose headclutch|guard [ник] - держится за голову после удара (~1.4 с) / закрывается лёжа от ударов (5 с)",
	"rem_artag_realism 0         - вернуть на живых нереалистичное мода (сам кувыркается, сам ползёт, «киношно» тонет)",
	"--- Звуки (у себя) ---",
	"rem_test_deathsound [0|1]   - звук смерти (0 brutal, 1 остановка сердца)",
	"rem_test_roundsound         - начало раунда Homicide",
	"rem_test_police             - прибытие полиции / SWAT",
	"rem_test_headshotsound      - хедшот",
	"rem_test_concsound          - случайный звук сотрясения",
	"rem_test_heartstopsound [0|1] - звук остановки сердца (1 - без сознания, по умолчанию; 0 - в сознании)",
	"rem_test_stopsounds         - остановить тестовые звуки",
	"rem_fadingmusic_test 0..1   - музыка при уходе сознания",
	"rem_test_vortex [скорость]  - предпросмотр: вихрь смерти (84 с / скорость, по умолч. 4), потом",
	"                              экран Deceased со сводкой (время, причина, настроение); ещё раз - стоп",
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

	-- связка с модом Artagdoll (compat/sh_artagdoll.lua): мод серверный - проверяем здесь
	concommand.Add("rem_test_artag", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end
		local function cv(n) local c = GetConVar(n) return c and c:GetString() or "-" end
		local msg = "rem_test_artag: мод Artagdoll " .. (ActiveRagdollManager and "найден" or "НЕ найден (поставь аддон)") ..
			"; rem_artag " .. cv("rem_artag") .. "; ar_enabled " .. cv("ar_enabled") ..
			"; ar_enabled_players (должно быть 0) " .. cv("ar_enabled_players") .. "; живые rem_artag_alive " .. cv("rem_artag_alive")
		if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
	end)

	-- поза Artagdoll (compat/sh_artagdoll.lua M.Pose): первый аргумент - вид, дальше ник
	concommand.Add("rem_test_pose", function(ply, _, args)
		if not IsValid(ply) or not ply:IsAdmin() then return end
		local KINDS = {cower = true, guard = true, headclutch = true}
		local kind = KINDS[args[1]] and args[1] or "decorticate" -- и старое имя decerebrate
		local t = Target(ply, {select(2, unpack(args))})
		if not IsValid(t) or not t:Alive() then return end
		if not (hg.Artag and hg.Artag.Present() and hg.Artag.Pose) then ply:ChatPrint("rem_test_pose: мод Artagdoll не найден") return end
		if not IsValid(t.FakeRagdoll) then hg.Fake(t, nil, nil, true) end
		timer.Simple(0.3, function()
			if not IsValid(t) or not IsValid(t.FakeRagdoll) then return end
			local ok = hg.Artag.Pose(t.FakeRagdoll, t, kind, kind == "headclutch" and 1.35 or (kind == "decorticate" and 4 or 5), true)
			if IsValid(ply) then ply:ChatPrint("rem_test_pose " .. kind .. " -> " .. t:Nick() .. (ok and "" or ": не вышло (мод выключен?)")) end
		end)
	end)

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

	Cmd("rem_test_heartstop", function(t, org)
		org.heartstop = true
		return org.otrub and "без сознания - rem_heartstopuncon.wav" or "в сознании - rem_heartstop.wav"
	end)

	-- сломать поясничный отдел и уронить: ноги должны лежать без движения (кувырок/корчи/Artagdoll их не тянут)
	Cmd("rem_test_spine", function(t, org)
		org.spine1 = math.max(org.spine1 or 0, 1)
		if not IsValid(t.FakeRagdoll) and hg.Fake then hg.Fake(t, nil, true, true) end
		return "позвоночник сломан, SpineCut = " .. tostring(hg.SpineCut and hg.SpineCut(org) or "?") .. " (снять - Reset organism)"
	end)

	Cmd("rem_test_clear", function(t, org)
		org.concussion = 0
		org.remKOEnd = nil
		org.stun = 0
		org.disorientation = 0
	end)
else
	concommand.Add("rem_test_vac", function()
		local ply = LocalPlayer()
		if not (hg.VAC and hg.VAC.Present()) then print("rem_test_vac: аддон V.A.C. не найден (VAC.ZCity нет)") return end
		print("rem_test_vac: V.A.C. найден; в его технике: " .. tostring(hg.VAC.Seated(ply)) ..
			"; камера у V.A.C.: " .. tostring(hg.VAC.HasView()) ..
			"; hg.CameraYield: " .. tostring(hg.CameraYield and hg.CameraYield(ply)))
	end)

	concommand.Add("rem_test_rvb", function()
		local ply = LocalPlayer()
		if not (hg.RVB and hg.RVB.Present()) then print("rem_test_rvb: аддон RVB не найден") return end
		print("rem_test_rvb: RVB найден; в его машине: " .. tostring(hg.RVB.Seated(ply)) ..
			"; без регдолла/мыши Z-City: " .. tostring(hg.InSpecialVehicle(ply)) ..
			"; камера уступлена: " .. tostring(hg.CameraYield(ply)))
	end)

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
	concommand.Add("rem_test_heartstopsound", function(_, _, args)
		Play(tonumber(args[1]) == 0 and "rem_heartstop.wav" or "rem_heartstopuncon.wav")
	end)
	concommand.Add("rem_test_concsound", function() Play("rem_concussion/concussion" .. math.random(4) .. ".mp3") end)
	concommand.Add("rem_test_stopsounds", function()
		for _, ch in ipairs(chans) do if IsValid(ch) then ch:Stop() end end
		chans = {}
	end)
end
