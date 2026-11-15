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
--   наши реакции   на таком теле наши посмертные (sv_reagdoll_extra: выстрел в голову, кувырок, пальцы) молчат
--                  (тело.remArtag) - иначе два набора тянут одно тело. Живой в регдолле Z-City - наши реакции
--                  (мод рассчитан на умирающее тело со своим здоровьем, с управлением игрока он бы спорил).
-- Выкл. связки - rem_artag 0 (тогда тела игроков мод не трогает). Без мода ничего не делает.
hg.Artag = hg.Artag or {}
local M = hg.Artag

function M.Present() return ActiveRagdollManager ~= nil and ActiveRagdollManager.Run ~= nil end

if SERVER then
	local cvOn = CreateConVar("rem_artag", "1", FCVAR_ARCHIVE, "Give Z-City death ragdolls to the Artagdoll addon (if installed)", 0, 1)

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

	function M.Give(rag, ply)
		if not ModOn() or not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" or rag.remArtag then return false end
		if rag:GetPhysicsObjectCount() < 2 or not rag:LookupBone("ValveBiped.Bip01_Pelvis") then return false end
		local now = CurTime()
		local hit = IsValid(ply) and ply.remHSHit
		if hit and now - hit.t < 0.7 then rag.DMS_IsHeadshot = true end
		if IsValid(ply) and ply:IsOnFire() and not rag:IsOnFire() then rag:Ignite(math.Rand(8, 15)) end
		rag.remArtag = true
		local ok, err = pcall(ActiveRagdollManager.Run, rag, IsValid(ply) and ply.DMS_LastDmgPos or nil)
		if not ok then
			rag.remArtag = nil
			ErrorNoHalt("[rem_artag] ActiveRagdollManager.Run: " .. tostring(err) .. "\n")
			return false
		end
		rag.DMS_Initialized = true
		if DMS_Health and DMS_Health.new then pcall(DMS_Health.new, rag, 100) end
		return true
	end

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
