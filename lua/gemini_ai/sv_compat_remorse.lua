--[[-------------------------------------------------------------------------
	Gemini AI — совместимость с рекосом (remorseism / Z-City / Homigrad)

	Что делает:
	• рассказывает ИИ про организм Homigrad (кровь, боль, пульс, отключка,
	  регдолл) и даёт ему готовые помощники AI.Heal / AI.Ragdoll / AI.GetUp ...;
	• добавляет в контекст состояние организма игрока и текущий режим раунда;
	• чат-команды !ai работают через ZChat (хук HG_PlayerSay) — это в sv_commands.lua.
	Без Homigrad модуль ничего не делает.
---------------------------------------------------------------------------]]

local function IsHomigrad()
	return istable(hg) and istable(hg.organism)
end
GeminiAI.IsHomigrad = IsHomigrad

-- Игрок или его регдолл -> игрок
local function OwnerOf(ent)
	if not IsValid(ent) then return end
	if ent:IsPlayer() then return ent end
	if hg and hg.RagdollOwner then
		local ply = hg.RagdollOwner(ent)
		if IsValid(ply) then return ply end
	end
	local ply = ent:GetNWEntity("ply")
	if IsValid(ply) and ply:IsPlayer() then return ply end
end

local function Num(v, mul, dec)
	if not isnumber(v) then return "?" end
	return tostring(math.Round(v * (mul or 1), dec or 0))
end

---------------------------------------------------------------------------
-- Инструкция для ИИ
---------------------------------------------------------------------------
GeminiAI.PromptExtras["remorse"] = function()
	if not IsHomigrad() then return end
	return [[

СЕРВЕР РАБОТАЕТ НА РЕЖИМЕ «РЕКОС» (remorseism, основа Z-City / Homigrad). Здоровье тут — не ply:Health(), а ОРГАНИЗМ:
• ply.organism — таблица: blood (мл, норма 5000, смерть ~2500), pain (120 = 100% боли), pulse (уд/мин, норма 70),
  consciousness (0..1), otrub (true — без сознания), stamina, adrenaline, analgesia, panic (0..1),
  lleg/rleg/larm/rarm (0 — цела, 1 — сломана), brain (0..1 повреждение мозга), bleed (кровотечение).
• Лежащий игрок — это регдолл (hg.GetCurrentCharacter(ply) вернёт регдолл или самого игрока; hg.RagdollOwner(rag) — игрок регдолла).
• Оружие и предметы режима: классы weapon_hg_*, weapon_rem_*, энтити ent_hg_* (см. каталог ниже). Обычные HL2-пушки тут почти не нужны.
• Спавн через Q у обычных игроков запрещён режимом — поэтому создавай всё через AI.Spawn / AI.Prop / AI.NPC (они обходят запрет).

ДОПОЛНИТЕЛЬНЫЕ ПОМОЩНИКИ ДЛЯ РЕКОСА:
  AI.Heal(ply)              полностью вылечить организм (кровь, боль, переломы, наркотики, паника) и поднять с земли.
  AI.Ragdoll(ply)           уронить игрока в регдолл.      AI.GetUp(ply) — поднять из регдолла.
  AI.Stun(ply, sec)         оглушить на sec секунд.
  AI.Vomit(ply)             вызвать рвоту.
  AI.Org(ply)               получить ply.organism (или nil). Меняй поля осторожно: org.blood = 5000, org.pain = 0, org.adrenaline = 1 и т.п.
  AI.Give(ply, class)       выдать предмет режима (ply:Give).
Если просят «вылечи» — используй AI.Heal, а не SetHealth. Не меняй ply:SetHealth в рекосе — организм перезапишет.
]]
end

---------------------------------------------------------------------------
-- Состояние игрока в контексте
---------------------------------------------------------------------------
GeminiAI.ContextProviders["remorse"] = function(ply, add)
	if not IsHomigrad() then return end

	if zb and isstring(zb.CROUND) and zb.CROUND ~= "" then
		add("Режим раунда (zb.CROUND): " .. zb.CROUND)
	end

	if not IsValid(ply) then return end
	local org = ply.organism
	if not istable(org) then return end

	add(string.format("Организм %s: кровь %s мл, боль %s%%, пульс %s, сознание %s%%, %s, в регдолле: %s, паника %s%%",
		ply:Nick(), Num(org.blood), Num(isnumber(org.pain) and org.pain / 1.2 or nil), Num(org.pulse),
		Num(org.consciousness, 100), org.otrub and "БЕЗ СОЗНАНИЯ" or "в сознании",
		IsValid(ply.FakeRagdoll) and "да" or "нет", Num(org.panic, 100)))

	local broken = {}
	for _, limb in ipairs({ "larm", "rarm", "lleg", "rleg" }) do
		if isnumber(org[limb]) and org[limb] >= 1 then broken[#broken + 1] = limb end
	end
	if #broken > 0 then add("Сломано: " .. table.concat(broken, ", ")) end

	-- На кого смотрит игрок — его организм тоже полезен ИИ
	local target = OwnerOf(ply:GetEyeTrace().Entity)
	if IsValid(target) and target ~= ply and istable(target.organism) then
		local o = target.organism
		add(string.format("Цель взгляда — игрок %s: кровь %s мл, боль %s%%, пульс %s, %s",
			target:Nick(), Num(o.blood), Num(isnumber(o.pain) and o.pain / 1.2 or nil), Num(o.pulse),
			o.otrub and "без сознания" or "в сознании"))
	end
end

---------------------------------------------------------------------------
-- Помощники в окружении кода ИИ
---------------------------------------------------------------------------
GeminiAI.EnvExtenders["remorse"] = function(AI, ply)
	if not IsHomigrad() then return end

	local function target(p)
		p = OwnerOf(p) or p
		if not (IsValid(p) and p:IsPlayer()) then error("Нужен игрок", 3) end
		return p
	end

	function AI.Org(p)
		p = OwnerOf(p) or p
		return IsValid(p) and p.organism or nil
	end

	function AI.Ragdoll(p)
		p = target(p)
		if not IsValid(p.FakeRagdoll) and hg.Fake then hg.Fake(p) end
	end

	function AI.GetUp(p)
		p = target(p)
		if IsValid(p.FakeRagdoll) and hg.FakeUp then hg.FakeUp(p, true) end
	end

	function AI.Stun(p, sec)
		p = target(p)
		if hg.LightStunPlayer then hg.LightStunPlayer(p, sec or 3) end
	end

	function AI.Vomit(p)
		p = target(p)
		if hg.organism.Vomit then hg.organism.Vomit(p) end
	end

	function AI.Heal(p)
		p = target(p)
		if not p:Alive() then p:Spawn() return end
		-- Тот же путь, что «Reset organism» в контекстном меню: хук "Org Clear"
		-- сбрасывает организм, панику, наркотики, тошноту и ломку
		if p.organism then hg.organism.Clear(p.organism) end
		p:SetHealth(p:GetMaxHealth())
		if IsValid(p.FakeRagdoll) and hg.FakeUp then
			timer.Simple(0.2, function() if IsValid(p) and IsValid(p.FakeRagdoll) then hg.FakeUp(p, true) end end)
		end
	end

	function AI.Give(p, class)
		p = target(p)
		return p:Give(class)
	end
end

-- Homigrad грузится позже нашего autorun, поэтому проверяем уже после загрузки карты
hook.Add("InitPostEntity", "GeminiAI_RemorseCompat", function()
	if IsHomigrad() then
		MsgC(Color(130, 120, 255), "[Gemini AI] ", color_white, "Включена совместимость с рекосом (Homigrad / Z-City)\n")
	end
end)
