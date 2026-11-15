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
	local Pending = {} -- [тело] = игрок: упал, но моду пока нельзя (шокер, припадок) - отдадим, когда пройдёт

	-- телу сейчас нельзя к моду: бьёт электрошокер (org.tasered: трос к телу + тряска Z-City), идёт припадок
	local function Busy(ply)
		local org = IsValid(ply) and ply.organism
		if not org then return false end
		if org.tasered and org.tasered > CurTime() then return true end
		if org.seizureActive then return true end
		return false
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
		if Busy(ply) then Pending[rag] = ply return end
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

	local nextThink = 0
	hook.Add("Think", "rem_artag", function()
		if not next(Alive) and not next(Pending) then return end
		local now = CurTime()
		if now < nextThink then return end
		nextThink = now + 0.1
		for rag, ply in pairs(Pending) do
			if not (IsValid(rag) and IsValid(ply) and ply:Alive() and ply.FakeRagdoll == rag) or not ModOn() or not cvAlive:GetBool() then
				Pending[rag] = nil
			elseif not Busy(ply) then
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
			rag.DMS_IsHeadshot = nil
			local d = HealthData(rag)
			if d and not d.dead then d.currentHP = d.maxHP or d.currentHP d.isBleeding = false end
			local ctrl = Busy(ply) -- шокер / припадок - тоже пауза
			if not ctrl then for _, k in ipairs(CONTROL) do if ply:KeyDown(k) then ctrl = true break end end end
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
end
