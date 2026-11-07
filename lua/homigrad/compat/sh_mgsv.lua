-- Совместимость с отдельным аддоном "Metal Gear Solid V: Gameplay SWEP" (таблица MGSVSnake, оружие weapon_mgsv_*).
-- Самого аддона в репозитории нет (модели и звуки MGSV чужие) - он ставится отдельной папкой в garrysmod/addons.
-- Пока у игрока в руках SWEP Снейка, homigrad уступает:
--   камера - работает камера аддона из-за плеча (от 3-го лица) вместо камеры homigrad от 1-го лица (cl_camera.lua);
--   тело - homigrad не рисует своё тело и аксессуары, аддон рисует Снейка (sh_utility.lua, hg.renderOverride);
--   движение - инерция homigrad выключена, у аддона своё движение: ползком, перекаты, укрытия (movement/sh_inertia.lua).
-- Если игрок упал регдоллом homigrad (FakeRagdoll) или без сознания - Снейк выключается, дальше работает homigrad.
-- Того, кого Снейк схватил (CQC), аддон рисует сам по анимации захвата - homigrad его тело не рисует и свою камеру
-- ему не навязывает (у схваченного камера аддона).
-- Транквилизатор Снейка (и бионическая рука) по игрокам и NPC с организмом действует как дротик Z-city
-- (weapon_tranquilizer): удар DMG_CLUB на 5 и +5 к org.tranquilizer - сознание уходит постепенно (sv_pain.lua).
-- Приёмы CQC по игрокам с организмом (вместо сна из аддона):
--   броски и удар об землю - НЕ вырубают, только больно;
--   нож после захвата - перерезано горло, как у тейкдауна (TD.CriticalInjuries: сонная артерия хлещет, падает);
--   удушение после захвата - без сознания ненадолго, всего не больше 2 минут.
hg.MGSV = hg.MGSV or {}

function hg.MGSV.Active(ply)
	-- только игроки: homigrad зовёт отрисовку и для регдоллов, а у них нет InVehicle и т.п.
	if not MGSVSnake or not MGSVSnake.Active or not IsValid(ply) or not ply:IsPlayer() then return false end
	return MGSVSnake.Active(ply) and true or false
end

-- его схватили приёмом CQC (аддон двигает и рисует его сам)
function hg.MGSV.Held(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	if MGSVCQC and MGSVCQC.Held and MGSVCQC.Held(ply) then return true end
	return CLIENT and MGSVSnake and MGSVSnake.CQCHeld and MGSVSnake.CQCHeld(ply) or false
end

-- регдолл аддона (вырублен приёмом CQC или усыплён): его рисует движок, а не отрисовка homigrad
function hg.MGSV.IsRag(ent)
	if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return false end
	return ent:GetNW2Bool("MGSVCQC_KO", false) or ent:GetNW2Float("MGSV_Sleep", 0) > 0 or ent:GetNW2String("MGSV_RagModel", "") ~= ""
end

-- камера и тело - за аддоном (Снейк в руках или схвачен)
function hg.MGSV.Owns(ply)
	return hg.MGSV.Active(ply) or hg.MGSV.Held(ply)
end

-- дротик как у Z-city: tranquilizerdarts в sh_ammostuff.lua (BulletSettings.Damage = 5, DMG_CLUB, tranquilizer = true)
local DART_DAMAGE = 5
local function ZCityDart(victim, attacker)
	local org = victim.organism
	if not org or org.alive == false then return false end
	local d = DamageInfo()
	d:SetDamage(DART_DAMAGE)
	d:SetDamageType(DMG_CLUB)
	d:SetAttacker(IsValid(attacker) and attacker or victim)
	d:SetInflictor(IsValid(attacker) and attacker or victim)
	d:SetDamagePosition(victim:WorldSpaceCenter())
	victim:TakeDamageInfo(d)
	org.tranquilizer = (org.tranquilizer or 0) + DART_DAMAGE
	return true
end

-- аддон грузится сам (autorun), поэтому оборачиваем его проверку, когда всё загружено
local function Wrap()
	local S = MGSVSnake
	if not S then return end

	if S.Active and not S.RemWrappedActive then
		S.RemWrappedActive = true
		local orig = S.Active
		S.Active = function(ply)
			if not IsValid(ply) or not ply:IsPlayer() then return false end
			if IsValid(ply.FakeRagdoll) or (ply.organism and ply.organism.otrub) then return false end
			return orig(ply)
		end
	end

	-- конец броска/удушения/ножа: аддон хочет усыпить игрока и создаёт свой регдолл - для организмов это делаем сами
	if SERVER and S.KnockOutPlayer and not S.RemWrappedKO then
		S.RemWrappedKO = true
		local orig = S.KnockOutPlayer
		S.KnockOutPlayer = function(victim, rag)
			if IsValid(victim) and victim:IsPlayer() and victim.organism then
				if IsValid(rag) then rag:Remove() end
				return true -- что именно было - смотрит Think ниже (последняя фаза приёма у жертвы)
			end
			return orig(victim, rag)
		end
	end

	if SERVER and S.TranqPlayer and not S.RemWrappedTranqPly then
		S.RemWrappedTranqPly = true
		local orig = S.TranqPlayer
		S.TranqPlayer = function(victim, attacker, head)
			if IsValid(victim) and victim:IsPlayer() and victim:Alive() and victim.organism then return ZCityDart(victim, attacker) end
			return orig(victim, attacker, head)
		end
	end
	if SERVER and S.TranqNPC and not S.RemWrappedTranqNPC then
		S.RemWrappedTranqNPC = true
		local orig = S.TranqNPC
		S.TranqNPC = function(npc, attacker, head)
			if IsValid(npc) and npc.organism then return ZCityDart(npc, attacker) end
			return orig(npc, attacker, head)
		end
	end
end
Wrap()
timer.Simple(0, Wrap)
hook.Add("InitPostEntity", "rem_mgsv_compat", Wrap)

if SERVER then
	-- zcity построен на sandbox: его PlayerShouldTakeDamage даёт false при sbox_godmode / sbox_playershurtplayers 0,
	-- а аддон Снейка этим хуком решает, можно ли хватать (CQC) и усыплять игрока. Урон у нас идёт через организм homigrad,
	-- поэтому для Снейка этот запрет не нужен: приёмы и дротики по игрокам работают всегда.
	hook.Add("PlayerShouldTakeDamage", "rem_mgsv_cqc", function(victim, attacker)
		if IsValid(attacker) and attacker:IsPlayer() and attacker ~= victim and hg.MGSV.Active(attacker) then return true end
	end)

	-- rem_mgsv_debug: почему сервер не начинает захват (печатает в консоль того, кто вызвал)
	concommand.Add("rem_mgsv_debug", function(ply)
		if not IsValid(ply) then return end
		local S, C = MGSVSnake, MGSVCQC
		local out = {}
		local function p(...) out[#out + 1] = table.concat({...}, " ") end
		if not S then p("MGSVSnake нет - аддон Снейка не загружен") ply:PrintMessage(HUD_PRINTCONSOLE, out[1]) return end
		p("Active:", tostring(S.Active(ply)), "OnGround:", tostring(ply:IsOnGround()), "State:", tostring(S.State and S.State(ply)),
			"Aiming:", tostring(S.Aiming and S.Aiming(ply)), "Busy:", tostring(C and C.Busy and C.Busy(ply)))
		p("Cig:", tostring(S.CigState and S.CigState(ply)), "Throw:", tostring(S.Throwing and S.Throwing(ply)),
			"Reload:", tostring(S.ReloadPhase and S.ReloadPhase(ply)), "Dance:", tostring(S.Dancing and S.Dancing(ply)))
		p("CQCReady (сервер):", tostring(S.CQCReady and S.CQCReady(ply)), "cqc_players:", tostring(S.cvCQCPlayers and S.cvCQCPlayers:GetBool()))
		for _, e in ipairs(ents.FindInSphere(ply:GetPos(), 120)) do
			if e ~= ply and (e:IsPlayer() or e:IsNPC()) then
				local d = e:GetPos() - ply:GetPos()
				p(tostring(e), "dist:", math.Round(d:Length2D()), "dz:", math.Round(d.z), "alive/hp:", tostring(e:IsPlayer() and e:Alive() or e:Health()),
					"ground:", tostring(e:IsOnGround()), "nodraw:", tostring(e:GetNoDraw()), "cqcFlag:", tostring(e.mgsvCQC), "sleep:", tostring(e.mgsvSleepEnd),
					"pelvis:", tostring(e:LookupBone("ValveBiped.Bip01_Pelvis")),
					"ShouldTakeDamage:", tostring(e:IsPlayer() and hook.Run("PlayerShouldTakeDamage", e, ply)))
			end
		end
		for _, l in ipairs(out) do ply:PrintMessage(HUD_PRINTCONSOLE, l) end
	end)
end

if SERVER then
	local CQC = {
		throwPain = 50,                 -- боль за бросок / удар об землю (100% = 120), добавляется постепенно
		chokeMin = 30, chokeMax = 110,  -- сколько держит без сознания после удушения; ещё ~6 с просыпается - итого до 2 минут
	}
	hg.MGSV.CQC = CQC

	local function baseKey(k)
		if not k then return end
		if string.sub(k, 1, 2) == "q_" then k = string.sub(k, 3) end
		return k
	end

	local function Finish(ply, k)
		local org = ply.organism
		if not org or not ply:Alive() then return end
		if k == "knf_kil" then
			-- перерезано горло (нож дошёл до конца)
			local TD = hg.Takedown
			if TD and TD.CriticalInjuries and TD.CriticalInjuries(ply) then
				if hg.Fake then hg.Fake(ply, nil, nil, true) end
			end
		elseif k == "choke_ed" then -- удушение доведено до конца (прерванное - не вырубает)
			ply.remMgsvChokeUntil = CurTime() + math.Rand(CQC.chokeMin, CQC.chokeMax)
			org.consciousness = 0
			org.needotrub = true
			org.needfake = true
		elseif string.sub(k, 1, 4) == "thw_" or k == "slam" then
			org.painadd = (org.painadd or 0) + CQC.throwPain
		end
	end

	hook.Add("Think", "rem_mgsv_cqc", function()
		local C = MGSVCQC
		if not C or not C.Info then return end
		local now = CurTime()

		-- нож по игроку с организмом: аддон убил бы его (Kill) - снимаем флаг, горло режем сами в конце приёма
		if C.BusyTable then
			for snake, rec in pairs(C.BusyTable) do
				local v = rec and rec.npc
				if rec.kill and IsValid(v) and v:IsPlayer() and v.organism then rec.kill = false end
			end
		end

		for _, ply in player.Iterator() do
			-- последняя фаза приёма у жертвы; фаза пропала - приём закончился
			local k = C.Info(ply, true)
			if k then
				ply.remMgsvLastK = baseKey(k)
			elseif ply.remMgsvLastK then
				local last = ply.remMgsvLastK
				ply.remMgsvLastK = nil
				Finish(ply, last)
			end

			-- после удушения держим без сознания
			local untilT = ply.remMgsvChokeUntil
			if untilT then
				local org = ply.organism
				if now >= untilT or not ply:Alive() or not org then
					ply.remMgsvChokeUntil = nil
				else
					org.consciousness = 0
					org.needotrub = true
					org.needfake = true
				end
			end
		end
	end)

	hook.Add("PlayerSpawn", "rem_mgsv_cqc", function(ply)
		ply.remMgsvChokeUntil, ply.remMgsvLastK = nil, nil
	end)
end
