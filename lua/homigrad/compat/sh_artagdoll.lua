-- Связка с отдельным аддоном «Artagdoll [WIP]» (активные регдоллы; в репозиторий не кладём - чужой код, анимации,
-- звуки; ставится отдельно - Мастерская или папка в addons). Реакции - самого мода, его кодом (держится за рану,
-- шатается с шагами, машет в полёте, цепляется за стены, горит, выстрел в голову, корчи, кувырок...): здесь только
-- подключение к телам Z-City.
--   тела           мод вешает себя на регдоллы движка (CreateEntityRagdoll у NPC, PLAYER:CreateRagdoll у игроков) -
--                  у Z-City тело смерти своё (ply.RagdollDeath), его мод не видит. Отдаём его моду сами:
--                  ActiveRagdollManager.Run(тело, точка урона) + DMS_Health.new (как мод делает со своими);
--   игроки         его подмена PLAYER:CreateRagdoll (ar_enabled_players 1) сделала бы второе тело поверх тела Z-City -
--                  выключаем её (ar_enabled_players 0), тела игрокам даём мы; NPC мод берёт сам (ar_enabled_npcs);
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
-- Выкл. связки - rem_artag 0 (тогда тела игроков мод не трогает), только живые - rem_artag_alive 0. Без мода ничего не делает.
hg.Artag = hg.Artag or {}
local M = hg.Artag

function M.Present() return ActiveRagdollManager ~= nil and ActiveRagdollManager.Run ~= nil end

if SERVER then
	local cvOn = CreateConVar("rem_artag", "1", FCVAR_ARCHIVE, "Give Z-City death ragdolls to the Artagdoll addon (if installed)", 0, 1)
	local cvAlive = CreateConVar("rem_artag_alive", "1", FCVAR_ARCHIVE, "Also give living players' Z-City ragdolls to Artagdoll (paused while the player controls the body)", 0, 1)
	local Alive = {} -- [тело] = игрок: живые тела у мода
	-- кнопки, которыми игрок двигает тело в регдолле Z-City (руки, ноги, наклон, встать)
	local CONTROL = {IN_ATTACK, IN_ATTACK2, IN_USE, IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP, IN_DUCK, IN_SPEED, IN_RELOAD}

	local function ModOn()
		local cv = GetConVar("ar_enabled")
		return M.Present() and cvOn:GetBool() and (not cv or cv:GetBool())
	end

	-- его подмену тела игрока - выключить (мод сам возвращает движковую по смене ar_enabled_players)
	local function NoEngineRagdolls()
		if not M.Present() or not cvOn:GetBool() then return end
		local cv = GetConVar("ar_enabled_players")
		if cv and cv:GetBool() then
			RunConsoleCommand("ar_enabled_players", "0")
			print("[rem_artag] ar_enabled_players 0: тела игроков Artagdoll получает от Z-City (compat/sh_artagdoll.lua)")
		end
	end
	hook.Add("InitPostEntity", "rem_artag", function() timer.Simple(6, NoEngineRagdolls) end) -- мод ставит хуки через 5 с
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
		rag.remArtag, rag.remArtagAlive, rag.remArtagPaused = nil, nil, nil
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

	hook.Add("Fake", "rem_artag", function(ply, rag)
		if not ModOn() or not cvAlive:GetBool() or not IsValid(ply) or not IsValid(rag) or ply:InVehicle() then return end
		-- мод сам ставит контроллер через 0.05 с; тело должно уже стоять
		timer.Simple(0.1, function()
			if IsValid(ply) and IsValid(rag) and ply:Alive() and ply.FakeRagdoll == rag then M.Give(rag, ply, true) end
		end)
	end)

	-- живой: мод не решает, что выстрел в голову смертелен (это делает Z-City) - метку снимаем после всех хуков урона
	hook.Add("PostEntityTakeDamage", "rem_artag", function(target)
		if IsValid(target) and target.remArtagAlive then target.DMS_IsHeadshot = nil end
	end)

	local nextThink = 0
	hook.Add("Think", "rem_artag", function()
		if not next(Alive) then return end
		local now = CurTime()
		if now < nextThink then return end
		nextThink = now + 0.1
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
			local ctrl = false
			for _, k in ipairs(CONTROL) do if ply:KeyDown(k) then ctrl = true break end end
			SetPaused(rag, ctrl)
		end
	end)

	hook.Add("DoPlayerDeath", "rem_artag", function(ply)
		if not ModOn() then return end
		-- тело смерти Z-City появляется в этом же DoPlayerDeath (как в sv_reagdoll.lua - через тик)
		timer.Simple(0, function()
			if not IsValid(ply) then return end
			local rag = IsValid(ply.RagdollDeath) and ply.RagdollDeath or ply:GetNWEntity("RagdollDeath")
			if IsValid(rag) then M.Give(rag, ply) end
		end)
	end)
end
