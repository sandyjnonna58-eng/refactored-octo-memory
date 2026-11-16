-- Связка с отдельным аддоном «Artagdoll [WIP]» (активные регдоллы; в репозиторий не кладём - чужой код, анимации,
-- звуки; ставится отдельно - Мастерская или папка в addons). Реакции - самого мода, его кодом (держится за рану,
-- шатается с шагами, машет в полёте, цепляется за стены, горит, выстрел в голову, корчи, кувырок...): здесь только
-- подключение к телам Z-City.
--   тела           мод вешает себя на регдоллы движка (CreateEntityRagdoll у NPC, PLAYER:CreateRagdoll у игроков) -
--                  у Z-City тело смерти своё (ply.RagdollDeath), его мод не видит. Отдаём его моду сами:
--                  ActiveRagdollManager.Run(тело, точка урона) + DMS_Health.new (как мод делает со своими);
--   игроки         мод при загрузке всегда подменяет PLAYER:CreateRagdoll / GetRagdollEntity (второе тело при смерти) -
--                  возвращаем версии Z-City (hg.ZC_*) и держим; ar_enabled_players 0 - его PostPlayerDeath не трогает
--                  игроков, тела им даём мы; NPC мод берёт сам (ar_enabled_npcs);
--   шокер/припадок живого не отдаём моду (и ставим на паузу): трос шокера + силы мода крутили тело; массы костей,
--                  которые меняет контроллер мода, живому возвращаем (Z-City тянет тело под свои массы);
--   выстрел в голову  мод узнаёт его по ScalePlayerDamage, а пули Z-City идут мимо - метка из нашего HomigradDamage
--                  (ply.remHSHit, sv_reagdoll_extra.lua) -> тело.DMS_IsHeadshot;
--   живые         (rem_artag_alive 1) упал в регдолл Z-City (хук "Fake") - тело тоже моду. Чтобы не спорил с игроком
--                  и Z-City: пока жмёт кнопки управления (руки, движение, E, прыжок...) - мод на паузе (тело убрано из
--                  его цикла DMS.ActiveRagdolls, сила 0), отпустил - снова; своё здоровье мода (DMS_Health, 200)
--                  держим полным - иначе он «убил» бы тело и снял реакции; его метку выстрела в голову снимаем
--                  (PostEntityTakeDamage) - смерть решает Z-City; встал / тело больше не его - ar:Destroy().
--                  Умер в регдолле - то же тело переводится в посмертное: метка выстрела в голову, здоровье мода 30
--                  с кровотечением (доживает своё и умирает по-модовски).
--   наши реакции   на таком теле (тело.remArtag) наши (sv_reagdoll_extra: выстрел в голову, кувырок, вода, корчи,
--                  ползком, пальцы) молчат - иначе два набора тянут одно тело. Гримаса на лице - наша, остаётся.
-- Мёртвые тела по умолчанию моду НЕ отдаём (rem_artag_dead 0, по просьбе: умер - тело как у Z-City, не двигается);
-- живое тело при смерти снимается с мода (Take). rem_artag_dead 1 - старое поведение (доживает и обмякает).
-- Выкл. связки - rem_artag 0 (тогда тела игроков мод не трогает), только живые - rem_artag_alive 0. Без мода ничего не делает.
hg.Artag = hg.Artag or {}
local M = hg.Artag

function M.Present() return ActiveRagdollManager ~= nil and ActiveRagdollManager.Run ~= nil end

if SERVER then
	local cvOn = CreateConVar("rem_artag", "1", FCVAR_ARCHIVE, "Give Z-City death ragdolls to the Artagdoll addon (if installed)", 0, 1)
	local cvAlive = CreateConVar("rem_artag_alive", "1", FCVAR_ARCHIVE, "Also give living players' Z-City ragdolls to Artagdoll (paused while the player controls the body)", 0, 1)
	-- по просьбе: мёртвое тело - обычный регдолл Z-City (не «доживает», не двигается); 1 - мод и на телах погибших
	local cvDead = CreateConVar("rem_artag_dead", "0", FCVAR_ARCHIVE, "Artagdoll also on dead bodies (they keep moving for a while after death)", 0, 1)
	local Alive = {} -- [тело] = игрок: живые тела у мода
	-- кнопки, которыми игрок двигает тело в регдолле Z-City (руки, ноги, наклон, встать)
	local CONTROL = {IN_ATTACK, IN_ATTACK2, IN_USE, IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP, IN_DUCK, IN_SPEED, IN_RELOAD}
	local Pending = {} -- [тело] = игрок: упал, но моду пока нельзя (шокер, припадок, без сознания) - отдадим, когда пройдёт

	-- телу сейчас нельзя к моду: бьёт электрошокер (org.tasered: трос к телу + тряска Z-City), идёт припадок
	local function Busy(ply)
		local org = IsValid(ply) and ply.organism
		if not org then return false end
		if org.tasered and org.tasered > CurTime() then return true end
		if org.seizureActive then return true end
		return false
	end

	-- без сознания мод не работает (по просьбе): тело забираем у мода целиком - обмякает, как обычный регдолл Z-City;
	-- очнулся и всё ещё лежит - отдаём обратно
	local function Uncon(ply)
		local org = IsValid(ply) and ply.organism
		return org and (org.otrub or (org.remKOEnd and org.remKOEnd > CurTime())) and true or false
	end

	-- массы костей: контроллер мода (active_ragdoll_controller) при создании ставит свои массы/инерцию части костей -
	-- у живого Z-City тянет тело силами под свои массы, с лёгкими костями тело крутило и швыряло. Живому возвращаем
	local function SaveMasses(rag)
		local t = {}
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local p = rag:GetPhysicsObjectNum(i)
			if IsValid(p) then t[i] = {p:GetMass(), p:GetInertia()} end
		end
		return t
	end
	local function RestoreMasses(rag, t)
		if not IsValid(rag) or not t then return end
		for i, m in pairs(t) do
			local p = rag:GetPhysicsObjectNum(i)
			if IsValid(p) then p:SetMass(m[1]) p:SetInertia(m[2]) end
		end
	end

	local function ModOn()
		local cv = GetConVar("ar_enabled")
		return M.Present() and cvOn:GetBool() and (not cv or cv:GetBool())
	end

	-- его подмену тела игрока - выключить (мод сам возвращает движковую по смене ar_enabled_players)
	-- Мод при загрузке ВСЕГДА (не только при ar_enabled_players 1) ставит свои PLAYER:CreateRagdoll / GetRagdollEntity:
	-- его CreateRagdoll делает prop_ragdoll и переводит игрока в наблюдение за ним - при смерти второе тело поверх
	-- тела Z-City, а GetRagdollEntity перестаёт отдавать тело Z-City (экран смерти, дефибриллятор). У Z-City
	-- CreateRagdoll ничего не делает - возвращаем её версии (hg.ZC_*, fake/sv_tier_0.lua) и держим (проверка раз в 5 с).
	local function KeepZCityBodies()
		if not M.Present() then return end
		local P = FindMetaTable("Player")
		if hg.ZC_CreateRagdoll and P.CreateRagdoll ~= hg.ZC_CreateRagdoll then
			P.CreateRagdoll = hg.ZC_CreateRagdoll
			print("[rem_artag] PLAYER:CreateRagdoll Artagdoll -> Z-City (второе тело при смерти)")
		end
		if hg.ZC_GetRagdollEntity and P.GetRagdollEntity ~= hg.ZC_GetRagdollEntity then
			P.GetRagdollEntity = hg.ZC_GetRagdollEntity
		end
	end

	-- голос мода (SoundManager: крики/стоны по поведению, если у мода есть озвучка) - не для живого: у живого голос
	-- Z-City (фразы, крики боли). Оборачиваем его функцию проигрывания (сам код мода не трогаем)
	local function MuteAliveVoice()
		if not SoundManager or SoundManager.remWrapped or not SoundManager.Play then return end
		local orig = SoundManager.Play
		SoundManager.Play = function(self, ent, ...)
			if IsValid(ent) and ent.remArtagAlive then return end
			return orig(self, ent, ...)
		end
		SoundManager.remWrapped = true
	end

	local function NoEngineRagdolls()
		if not M.Present() then return end
		KeepZCityBodies()
		MuteAliveVoice()
		if not cvOn:GetBool() then return end
		local cv = GetConVar("ar_enabled_players")
		if cv and cv:GetBool() then
			RunConsoleCommand("ar_enabled_players", "0") -- и его PostPlayerDeath не трогает игроков
			print("[rem_artag] ar_enabled_players 0: тела игроков Artagdoll получает от Z-City (compat/sh_artagdoll.lua)")
			timer.Simple(0.5, KeepZCityBodies) -- его колбэк квара вернёт «старые» - а старыми могли быть движковые
		end
	end
	hook.Add("InitPostEntity", "rem_artag", function()
		timer.Simple(0, KeepZCityBodies)
		timer.Simple(6, NoEngineRagdolls) -- мод ставит хуки через 5 с
		timer.Create("rem_artag_keep", 5, 0, KeepZCityBodies)
	end)
	-- и сразу перед смертью (если мод перезагрузился между проверками)
	hook.Add("DoPlayerDeath", "rem_artag_keep", function() KeepZCityBodies() end)
	cvars.AddChangeCallback("rem_artag", function(_, _, new) if new == "1" then NoEngineRagdolls() end end, "rem_artag")

	local function HealthData(rag) return DMS_Health and DMS_Health.Active and DMS_Health.Active[rag] end

	-- пауза: тело вне цикла поведений мода и без силы; снова - обратно
	local function SetPaused(rag, paused)
		if (rag.remArtagPaused or false) == paused then return end
		local ar = ActiveRagdoll and ActiveRagdoll.Get and ActiveRagdoll.Get(rag)
		if not ar then return end
		rag.remArtagPaused = paused
		local idx = rag:EntIndex()
		if paused then
			if DMS and DMS.ActiveRagdolls then DMS.ActiveRagdolls[idx] = nil end
			ar:SetStrength(0)
		else
			if DMS and DMS.ActiveRagdolls then DMS.ActiveRagdolls[idx] = ar end
			ar:SetStrength(ActiveRagdollManager.Config and ActiveRagdollManager.Config.DefaultStrength or 2.5)
		end
	end

	local function Take(rag)
		Alive[rag] = nil
		if not IsValid(rag) then return end
		local ar = ActiveRagdoll and ActiveRagdoll.Get and ActiveRagdoll.Get(rag)
		if ar and ar.Destroy then pcall(ar.Destroy, ar) end
		RestoreMasses(rag, rag.remArtagMasses)
		rag.remArtag, rag.remArtagAlive, rag.remArtagPaused, rag.remArtagMasses = nil, nil, nil, nil
	end

	-- живое тело умерло: дальше посмертно, как у мода
	local function ToDead(rag, ply)
		Alive[rag] = nil
		rag.remArtagAlive = nil
		SetPaused(rag, false)
		local hit = IsValid(ply) and ply.remHSHit
		if hit and CurTime() - hit.t < 0.7 then rag.DMS_IsHeadshot = true end
		local d = HealthData(rag)
		if d then
			d.currentHP = math.min(d.currentHP or 30, 30)
			d.isBleeding = true
			d.nextBleedTick = 0
		end
	end

	function M.Give(rag, ply, alive)
		if not ModOn() or not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" then return false end
		if rag.remArtag then
			if not alive and rag.remArtagAlive then ToDead(rag, ply) return true end
			return false
		end
		if rag:GetPhysicsObjectCount() < 2 or not rag:LookupBone("ValveBiped.Bip01_Pelvis") then return false end
		local now = CurTime()
		local hit = IsValid(ply) and ply.remHSHit
		if not alive and hit and now - hit.t < 0.7 then rag.DMS_IsHeadshot = true end
		if IsValid(ply) and ply:IsOnFire() and not rag:IsOnFire() then rag:Ignite(math.Rand(8, 15)) end
		rag.remArtag = true
		if alive then
			rag.remArtagAlive = true
			Alive[rag] = ply
			-- контроллер мода появится через ~0.05 с и поменяет массы - вернуть после
			local masses = SaveMasses(rag)
			rag.remArtagMasses = masses
			timer.Simple(0.3, function() if IsValid(rag) and rag.remArtagAlive then RestoreMasses(rag, masses) end end)
		end
		local ok, err = pcall(ActiveRagdollManager.Run, rag, IsValid(ply) and ply.DMS_LastDmgPos or nil)
		if not ok then
			rag.remArtag = nil
			ErrorNoHalt("[rem_artag] ActiveRagdollManager.Run: " .. tostring(err) .. "\n")
			return false
		end
		rag.DMS_Initialized = true
		-- у живого здоровье мода (200 от ActiveRagdoll.new) держим полным в Think ниже; посмертному - как мод своим
		if not alive and DMS_Health and DMS_Health.new then pcall(DMS_Health.new, rag, 100) end
		return true
	end

	-- по просьбе: живое тело - моду только от настоящего урона (пуля, удар, нож, взрыв, огонь...). Просто упал
	-- (сам, споткнулся, от падения/удара о предмет) - обычный регдолл Z-City: иначе держится за рану, которой нет
	local HURT = DMG_BULLET + DMG_BUCKSHOT + DMG_SLASH + DMG_CLUB + DMG_BLAST + DMG_BURN + DMG_SHOCK + DMG_SONIC + DMG_DIRECT
	local HURT_FRESH = 1.5 -- упал не позже стольких секунд после удара - от удара
	local function RealHurt(dmg)
		return dmg:IsDamageType(HURT) and not dmg:IsDamageType(DMG_FALL) and dmg:GetDamage() > 0
	end

	local function TryGive(ply, rag)
		if not (IsValid(ply) and IsValid(rag) and ply:Alive() and ply.FakeRagdoll == rag) then return end
		if rag.remArtag or Pending[rag] then return end
		if Busy(ply) or Uncon(ply) or rag.remArtagPose then Pending[rag] = ply return end
		M.Give(rag, ply, true)
	end

	hook.Add("HomigradDamage", "rem_artag_hurt", function(ply, dmg, hitgroup, ent)
		if not ModOn() or not cvAlive:GetBool() or not RealHurt(dmg) then return end
		if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
		if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
		ply.remArtagHurtT = CurTime()
		-- уже лежит в регдолле и получил удар - отдаём телу сейчас (контроллер мода - через 0.1 с)
		local rag = ply.FakeRagdoll
		if IsValid(rag) and not rag.remArtag then
			timer.Simple(0.1, function() TryGive(ply, rag) end)
		end
	end)

	hook.Add("Fake", "rem_artag", function(ply, rag)
		if not ModOn() or not cvAlive:GetBool() or not IsValid(ply) or not IsValid(rag) or ply:InVehicle() then return end
		-- упал без свежего удара - мод не нужен (включится, если ударят уже лёжа - HomigradDamage выше)
		if CurTime() - (ply.remArtagHurtT or -100) > HURT_FRESH then return end
		-- мод сам ставит контроллер через 0.05 с; тело должно уже стоять. Шокер/припадок - позже (Think)
		timer.Simple(0.1, function() TryGive(ply, rag) end)
	end)

	-- живой: мод не решает, что выстрел в голову смертелен (это делает Z-City) - метку снимаем после всех хуков урона
	hook.Add("PostEntityTakeDamage", "rem_artag", function(target)
		if IsValid(target) and target.remArtagAlive then target.DMS_IsHeadshot = nil end
	end)

	-- ТОЛЬКО РЕАЛИЗМ (по просьбе; все 27 анимаций мода просмотрены покадрово): на живом теле остаются поведения,
	-- которые так и выглядят в жизни - держится за рану (woundgrab), шатается и ловит равновесие (stumble: StumbleV2,
	-- Cower, Balance), упирается руками в стену (wallstunt), хватается за край в полёте (holdenv), размахивает руками в
	-- падении (falling - так и бывает при падении с высоты), корчится от боли лёжа (injured: Dying1-6), бьётся и сбивает
	-- пламя (burning). Убраны на живых: tumble - мод сам закручивает тело моментом (5000) и поджимает - в жизни тело
	-- катится пассивно (ar.Bravery огромная - порог кувырка не достигается; уже начался - назад в injured);
	-- crawling - тело само ползёт (5% лёжа на животе), а ползёт игрок - не даём; drowning - «киношное» утопание (руки
	-- вверх, ноги бьют; в жизни тонущий почти неподвижен, руки давят на воду) - в воде мод на паузе, тело Z-City.
	-- Мёртвые тела мод не получает (rem_artag_dead 0), его выстрел в голову на живых снят. Выкл. - rem_artag_realism 0.
	local cvReal = CreateConVar("rem_artag_realism", "1", FCVAR_ARCHIVE, "Only realistic Artagdoll behaviours on living players (no self-spinning tumble, no self-crawling, no movie drowning)", 0, 1)
	local function Unreal(rag)
		if rag:WaterLevel() >= 1 then return true end -- утопание мода - пауза, пока в воде
		local ar = ActiveRagdoll and ActiveRagdoll.Get and ActiveRagdoll.Get(rag)
		if not ar then return false end
		if ar.PersonalityInitialized then ar.Bravery = 1e6 end -- порог кувырка = ar_TumbleSpeed * Bravery
		ar.TumbleLockTime = nil
		ar.CrawlChanceRolled, ar.WantsToCrawl = true, false -- сам не ползёт
		local cur = ar.CurrentBehavior
		if (cur == "tumble" or cur == "crawling") and DMS and DMS.Switch then DMS:Switch(ar, "injured") end
		return false
	end

	local nextThink = 0
	hook.Add("Think", "rem_artag", function()
		if not next(Alive) and not next(Pending) then return end
		local now = CurTime()
		if now < nextThink then return end
		nextThink = now + 0.1
		for rag, ply in pairs(Pending) do
			if not (IsValid(rag) and IsValid(ply) and ply:Alive() and ply.FakeRagdoll == rag) or not ModOn() or not cvAlive:GetBool() then
				Pending[rag] = nil
			elseif not Busy(ply) and not Uncon(ply) and not rag.remArtagPose then
				Pending[rag] = nil
				M.Give(rag, ply, true)
			end
		end
		for rag, ply in pairs(Alive) do
			if not IsValid(rag) then Alive[rag] = nil continue end
			if not IsValid(ply) or not ModOn() or not cvAlive:GetBool() or (ply:Alive() and ply.FakeRagdoll ~= rag) then
				Take(rag) -- встал / тело не его / связку выключили
				continue
			end
			if not ply:Alive() then continue end -- умер: DoPlayerDeath переведёт в посмертное
			if Uncon(ply) then
				Take(rag) -- отключился: мод снимаем, очнётся лёжа - Pending вернёт
				Pending[rag] = ply
				continue
			end
			rag.DMS_IsHeadshot = nil
			local d = HealthData(rag)
			if d and not d.dead then d.currentHP = d.maxHP or d.currentHP d.isBleeding = false end
			local ctrl = Busy(ply) -- шокер / припадок - тоже пауза
			if not ctrl then for _, k in ipairs(CONTROL) do if ply:KeyDown(k) then ctrl = true break end end end
			if not ctrl and cvReal:GetBool() then ctrl = Unreal(rag) end
			SetPaused(rag, ctrl)
		end
	end)

	hook.Add("DoPlayerDeath", "rem_artag", function(ply)
		if not ModOn() then return end
		-- тело смерти Z-City появляется в этом же DoPlayerDeath (как в sv_reagdoll.lua - через тик)
		timer.Simple(0, function()
			if not IsValid(ply) then return end
			local rag = IsValid(ply.RagdollDeath) and ply.RagdollDeath or ply:GetNWEntity("RagdollDeath")
			-- умер лёжа в регдолле, тело было у мода как живое: без rem_artag_dead - снять мод (тело как у Z-City)
			for body in pairs(Alive) do
				if Alive[body] == ply and (not cvDead:GetBool() or body ~= rag) then Take(body) end
			end
			if IsValid(rag) and cvDead:GetBool() then M.Give(rag, ply) end
		end)
	end)
	-- ПОЗЫ без сознания / на грани (по просьбе, только реалистичные; анимации самого мода, models/AREAnims/model_anim.mdl):
	--   decorticate  без сознания при ТЯЖЁЛОЙ травме мозга (повреждение мозга, кровоизлияние, сотрясение >= 7, пережитый
	--                выстрел в голову; после обычного нокаута кулаком такого в жизни нет). Анимация мода зовётся
	--                Decerebrate, но по кадрам это ДЕКОРТИКАЦИОННАЯ поза: руки согнуты и прижаты к груди, кисти у плеч,
	--                ноги вытянуты, стопы оттянуты (децеребрационная - руки вытянуты вдоль тела; обе бывают при тяжёлой
	--                травме мозга). 3..6 с, потом обмякает. Шанс rem_artag_decorticate_chance при отключке и при новом
	--                ударе лёжа без сознания, не чаще раза в 10 с;
	--   cower        на грани отключки: в сознании, но сознание < 0.55 и боль >= 70 (~58%) - сжимается (по кадрам: бёдра
	--                к животу, спина согнута, кисти у лица/головы), пока так, до 8 с, потом откат 15 с; жмёт кнопки /
	--                отключился / полегчало - конец.
	-- Только поза: контроллер мода (ActiveRagdoll.new + PlayAnimation) без его поведений (DMS:Setup не зовём - не держится
	-- за рану и т.п.); массы костей возвращаем через 0.3 с; в конце сила плавно в 0 и ar:Destroy(). Голос мода молчит
	-- (remArtagAlive). Если тело было у мода (живое после урона) - на время позы снимаем, потом Pending вернёт.
	local cvPoses = CreateConVar("rem_artag_poses", "1", FCVAR_ARCHIVE, "Realistic Artagdoll poses: decorticate when unconscious with a severe brain injury, cower on the edge of passing out", 0, 1)
	local cvDecChance = CreateConVar("rem_artag_decorticate_chance", "50", FCVAR_ARCHIVE, "Chance (%) of the decorticate posture when unconscious with a severe brain injury", 0, 100)
	local ANIM_MODEL = "models/AREAnims/model_anim.mdl"
	local POSE = {
		decorticate = {anim = "Decerebrate", rate = 0.5, str = 4, min = 3, max = 6, cooldown = 10}, -- так зовётся у мода
		cower = {anim = "Cower", rate = 0.5, str = 2.5, min = 8, max = 8, cooldown = 15},
		-- от ударов (по просьбе; кулаки, пинки, дубинки - DMG_CLUB): держится за голову - анимации мода HeadshotLeft /
		-- HeadshotRight (обе руки к голове и обратно, 31 кадр; 0.65x - один раз за ~1.4 с); закрывается лёжа - Cower
		headclutch = {anims = {"HeadshotLeft", "HeadshotRight"}, rate = 0.65, str = 3, min = 1.35, max = 1.35, cooldown = 4, fade = 0.3},
		guard = {anim = "Cower", rate = 0.5, str = 3, min = 2, max = 3.5, cooldown = 0, fade = 0.6},
	}
	local POSE_FADE = 0.8 -- у позы без своего fade
	local Posed = {} -- [тело] = игрок

	local function BrainSevere(ply, org)
		if (org.brain or 0) >= 0.15 or (org.brainHemorrhage or 0) >= 0.1 or (org.concussion or 0) >= 7 then return true end
		local hs = ply.remHSHit
		return hs and CurTime() - hs.t < 5 or false
	end

	local function OnEdge(org)
		return not org.otrub and (org.consciousness or 1) < 0.55 and (org.pain or 0) >= 70
	end

	local function Controlling(ply)
		for _, k in ipairs(CONTROL) do if ply:KeyDown(k) then return true end end
		return false
	end

	local function EndPose(rag)
		local st = rag.remArtagPose
		Posed[rag] = nil
		if not IsValid(rag) or not st then return end
		local ar = ActiveRagdoll and ActiveRagdoll.Get and ActiveRagdoll.Get(rag)
		if ar and ar.Destroy then pcall(ar.Destroy, ar) end
		RestoreMasses(rag, st.masses)
		rag.remArtagPose, rag.remArtagAlive = nil, nil
		-- до позы тело было у мода (урон) - вернётся, когда можно (Pending)
		local ply = st.ply
		if st.wasGiven and IsValid(ply) and ply:Alive() and ply.FakeRagdoll == rag then Pending[rag] = ply end
	end

	function M.Pose(rag, ply, kind, dur, forced) -- forced - тест: держать всё время dur, без проверки условий
		local def = POSE[kind]
		if not def or not ModOn() or not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" then return false end
		if not (ActiveRagdoll and ActiveRagdoll.new) or rag:GetPhysicsObjectCount() < 2 then return false end
		local now = CurTime()
		if rag.remArtagPose then
			if rag.remArtagPose.kind == kind then rag.remArtagPose.untilT = math.max(rag.remArtagPose.untilT, now + (dur or def.min)) return true end
			EndPose(rag)
		end
		-- было у мода (или ждало возврата после отключки) - после позы вернём
		local wasGiven = (rag.remArtag or Pending[rag]) and true or false
		if wasGiven then Take(rag) end
		Pending[rag] = nil
		local masses = SaveMasses(rag)
		local ok, ar = pcall(ActiveRagdoll.new, rag, ANIM_MODEL, nil)
		if not ok or not ar then RestoreMasses(rag, masses) return false end
		local cfg = ActiveRagdollManager.Config
		if cfg and cfg.BoneList then ar:ApplyBoneList(cfg.BoneList) end
		ar:SetStrength(def.str)
		ar:PlayAnimation(def.anims and def.anims[math.random(#def.anims)] or def.anim, def.rate, ANIM_MODEL)
		rag.remArtagPose = {kind = kind, ply = ply, untilT = now + (dur or math.Rand(def.min, def.max)), masses = masses, wasGiven = wasGiven, forced = forced}
		rag.remArtagAlive = true -- голос мода молчит, рывки позы - не падение (sv_input velocityDamage)
		Posed[rag] = ply
		timer.Simple(0.3, function() if IsValid(rag) and rag.remArtagPose then RestoreMasses(rag, masses) end end)
		ply["remPoseNext_" .. kind] = now + (rag.remArtagPose.untilT - now) + def.cooldown
		return true
	end

	local function TryDecorticate(ply, rag, org)
		if not cvPoses:GetBool() or rag.remArtagPose or CurTime() < (ply.remPoseNext_decorticate or 0) then return end
		if not BrainSevere(ply, org) then return end
		if math.random(100) > cvDecChance:GetFloat() then
			ply.remPoseNext_decorticate = CurTime() + 10 -- не повезло - следующий бросок не раньше
			return
		end
		M.Pose(rag, ply, "decorticate")
	end

	-- новый удар лёжа без сознания - ещё бросок
	-- удар пришёлся в голову: hitgroup или точка ближе 14 к Head1 (как sh_headshot.lua)
	local function HeadHit(ply, dmg, hitgroup)
		if hitgroup == HITGROUP_HEAD then return true end
		local body = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or ply
		local b = body:LookupBone("ValveBiped.Bip01_Head1")
		local hp = b and body:GetBonePosition(b)
		return hp and hp:DistToSqr(dmg:GetDamagePosition()) < 14 * 14 or false
	end

	-- ОТ УДАРОВ (по просьбе): кулаки, пинки, дубинки (DMG_CLUB), человек в сознании.
	--   headclutch  стоял, получил по голове и упал от удара (через 0.3 с лежит в регдолле) - хватается обеими руками за
	--               голову ~1.4 с и отпускает (так делают после сильного удара по голове); не чаще раза в 4 с;
	--   guard       бьют уже лежащего - руки к голове, колени к груди; каждый удар продлевает (2..3.5 с от последнего);
	--               перестали бить / жмёт кнопки / отключился - отпускает.
	local cvGuard = CreateConVar("rem_artag_guard", "1", FCVAR_ARCHIVE, "Cover up (hands to head, knees to chest) when beaten while lying (Artagdoll Cower)", 0, 1)
	local cvClutch = CreateConVar("rem_artag_headclutch", "1", FCVAR_ARCHIVE, "Clutch the head after a strong blow to the head knocks you down (Artagdoll HeadshotLeft/Right)", 0, 1)

	hook.Add("HomigradDamage", "rem_artag_pose", function(ply, dmg, hitgroup)
		if not cvPoses:GetBool() or not ModOn() then return end
		if IsValid(ply) and ply:IsRagdoll() then ply = hg.RagdollOwner and hg.RagdollOwner(ply) or nil end
		if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() or not RealHurt(dmg) then return end
		local rag, org = ply.FakeRagdoll, ply.organism
		if not org then return end
		-- без сознания: новый удар - ещё бросок декортикационной позы
		if IsValid(rag) and org.otrub then
			timer.Simple(0.15, function()
				if IsValid(ply) and ply:Alive() and ply.FakeRagdoll == rag and ply.organism and ply.organism.otrub then TryDecorticate(ply, rag, ply.organism) end
			end)
			return
		end
		if not dmg:IsDamageType(DMG_CLUB) then return end
		local lying = IsValid(rag)
		local head = HeadHit(ply, dmg, hitgroup)
		-- нокаут/отключка ставятся тем же уроном чуть позже (sv_concussion) - решаем через 0.3 с
		timer.Simple(0.3, function()
			if not IsValid(ply) or not ply:Alive() or not ModOn() then return end
			local body = ply.FakeRagdoll
			if not IsValid(body) or Uncon(ply) or Busy(ply) then return end
			if lying then
				if cvGuard:GetBool() and not Controlling(ply) then M.Pose(body, ply, "guard", math.Rand(2, 3.5)) end
			elseif head and cvClutch:GetBool() and CurTime() >= (ply.remPoseNext_headclutch or 0) then
				M.Pose(body, ply, "headclutch")
			end
		end)
	end)

	-- умер в позе - снять сразу (раньше, чем тело смерти получит мод при rem_artag_dead 1)
	hook.Add("DoPlayerDeath", "rem_artag_pose", function(ply)
		for body, p in pairs(Posed) do if p == ply then EndPose(body) end end
	end)

	local nextPoseThink = 0
	hook.Add("Think", "rem_artag_pose", function()
		local now = CurTime()
		if now < nextPoseThink then return end
		nextPoseThink = now + 0.1
		-- идущие позы: конец по времени / встал / умер / условие ушло; в конце сила плавно в 0
		for rag, ply in pairs(Posed) do
			local st = IsValid(rag) and rag.remArtagPose
			if not st then Posed[rag] = nil continue end
			local org = IsValid(ply) and ply.organism
			local stop = not org or not ply:Alive() or ply.FakeRagdoll ~= rag or not ModOn() or not cvPoses:GetBool()
			if st.forced then -- тест
			elseif not stop and st.kind == "cower" then
				if not OnEdge(org) or Controlling(ply) or Busy(ply) then st.untilT = math.min(st.untilT, now) end
			elseif not stop and st.kind == "guard" then
				-- перестали бить (время), жмёт кнопки, отключился (обмякает) - конец
				if Controlling(ply) or Busy(ply) or Uncon(ply) then st.untilT = math.min(st.untilT, now) end
			elseif not stop and st.kind == "headclutch" then
				if Uncon(ply) then st.untilT = math.min(st.untilT, now) end
			elseif not stop and st.kind == "decorticate" then
				if not org.otrub then st.untilT = math.min(st.untilT, now) end -- очнулся
			end
			local d = not stop and HealthData(rag)
			if d and not d.dead then d.currentHP = d.maxHP or d.currentHP d.isBleeding = false end -- здоровье мода не наше
			local fade = POSE[st.kind].fade or POSE_FADE
			if stop or now >= st.untilT + fade then
				EndPose(rag)
			elseif now >= st.untilT then
				local ar = ActiveRagdoll.Get(rag)
				if ar then ar:SetStrength(POSE[st.kind].str * (1 - (now - st.untilT) / fade)) end
			end
		end
		if not cvPoses:GetBool() or not ModOn() or now < (M.nextPoseScan or 0) then return end
		M.nextPoseScan = now + 0.25
		-- новые: отключился с тяжёлой травмой мозга / на грани отключки от боли
		for _, ply in player.Iterator() do
			local rag, org = ply.FakeRagdoll, ply.organism
			if not ply:Alive() or not IsValid(rag) or not org or rag.remArtagPose then
				ply.remPoseOtrub = org and org.otrub or false
				continue
			end
			local otrub = org.otrub and true or false
			if otrub and not ply.remPoseOtrub then TryDecorticate(ply, rag, org) end
			ply.remPoseOtrub = otrub
			if not otrub and OnEdge(org) and now >= (ply.remPoseNext_cower or 0) and not Controlling(ply) and not Busy(ply) then
				M.Pose(rag, ply, "cower")
			end
		end
	end)
end
