--[[-------------------------------------------------------------------------
	Gemini AI — ИИ-персонажи

	Персонаж — это бот-игрок (player.CreateNextBot), которым управляет Gemini.
	В рекосе у него свой организм, оружие, регдолл — всё как у живого игрока.

	Мозг (раз в несколько секунд или сразу при событии):
	  восприятие (кто рядом, что сказали, кто ранил) -> Gemini -> JSON
	  { say, action, target, thought }
	Тело (каждый тик, StartCommand): ходьба по навмешу, взгляд, стрельба,
	  бегство, подбор оружия — по текущему действию.
---------------------------------------------------------------------------]]

util.AddNetworkString("GeminiAI_CharMenu")    -- сервер -> клиент: открыть окно (с позицией спавна)
util.AddNetworkString("GeminiAI_CharCreate")  -- клиент -> сервер: создать персонажа
util.AddNetworkString("GeminiAI_CharList")    -- оба направления: список персонажей
util.AddNetworkString("GeminiAI_CharCommand") -- клиент -> сервер: приказ / удалить / сменить роль

GeminiAI.Chars = GeminiAI.Chars or {} -- [бот] = персонаж
local Chars = GeminiAI.Chars
local cv = GeminiAI.CVars

local ACTIONS = {
	"idle", "follow", "goto", "flee", "attack", "wander",
	"pickup", "equip", "holster", "jump", "crouch", "lie_down", "get_up",
	"look", "use", "give", "drop", "reload",
}

local SCHEMA = {
	type = "OBJECT",
	properties = {
		say     = { type = "STRING", description = "Что сказать вслух. Пустая строка, если молчишь." },
		action  = { type = "STRING", enum = ACTIONS, description = "Что делать дальше" },
		target  = { type = "STRING", description = "Имя игрока из списка рядом, или класс оружия для pickup/equip, иначе пустая строка" },
		thought = { type = "STRING", description = "Короткая мысль про себя (никто не видит)" },
	},
	required = { "say", "action", "target", "thought" },
}

---------------------------------------------------------------------------
-- Мелочи
---------------------------------------------------------------------------
local function IsHG() return istable(hg) and istable(hg.organism) end

-- Имя, которое видят игроки (в рекосе — имя персонажа раунда)
local function NameOf(ply)
	if not IsValid(ply) then return "?" end
	if ply.GeminiChar then return ply.GeminiChar.name end
	return ply:GetNWString("PlayerName", "") ~= "" and ply:GetNWString("PlayerName") or ply:Nick()
end

-- Тело: регдолл, если игрок лежит
local function BodyOf(ply)
	if IsHG() and hg.GetCurrentCharacter then
		local body = hg.GetCurrentCharacter(ply)
		if IsValid(body) then return body end
	end
	return ply
end

local function OwnerOf(ent)
	if not IsValid(ent) then return end
	if ent:IsPlayer() then return ent end
	if IsHG() and hg.RagdollOwner then
		local p = hg.RagdollOwner(ent)
		if IsValid(p) then return p end
	end
	local p = ent:GetNWEntity("ply")
	if IsValid(p) and p:IsPlayer() then return p end
end

local function IsDown(ply)
	return IsValid(ply.FakeRagdoll) or (ply.organism and ply.organism.otrub)
end

-- string.lower не трогает кириллицу — делаем сами
local function ULower(s)
	s = string.lower(s or "")
	return (s:gsub("\208([\128-\175])", function(c)
		local b = c:byte()
		if b >= 144 and b <= 159 then return "\208" .. string.char(b + 32) end
		if b >= 160 and b <= 175 then return "\209" .. string.char(b - 32) end
		if b == 129 then return "\209\145" end
	end))
end

local function Meters(u) return math.Round(u * 0.01905) end

-- Направление на точку относительно взгляда бота
local function Direction(bot, pos)
	local diff = math.NormalizeAngle((pos - bot:GetPos()):Angle().y - bot:EyeAngles().y)
	if math.abs(diff) < 35 then return "впереди" end
	if math.abs(diff) > 145 then return "сзади" end
	return diff > 0 and "слева" or "справа"
end

local function Visible(bot, ent)
	local body = BodyOf(ent)
	local tr = util.TraceLine({
		start = bot:EyePos(),
		endpos = body:WorldSpaceCenter(),
		filter = { bot, BodyOf(bot) },
		mask = MASK_SHOT,
	})
	return not tr.Hit or tr.Entity == body or tr.Entity == ent or OwnerOf(tr.Entity) == ent
end

local function Debug(char, text)
	if not cv.char_debug:GetBool() then return end
	for _, p in ipairs(player.GetHumans()) do
		if GeminiAI.HasAccess(p, "Characters") then
			GeminiAI.Notify(p, "[" .. char.name .. "] " .. text)
		end
	end
end

-- Разбудить мозг через delay секунд; если он сейчас занят — подумает сразу после ответа
local function Wake(char, delay)
	if char.busy then char.pending = true end
	char.nextThink = math.min(char.nextThink, CurTime() + (delay or 0))
end

local function AddEvent(char, text, urgent)
	char.events[#char.events + 1] = text
	while #char.events > 12 do table.remove(char.events, 1) end
	if urgent then Wake(char, urgent) end
end

---------------------------------------------------------------------------
-- Ограничитель запросов (бесплатный ключ: ~10-15 запросов в минуту)
---------------------------------------------------------------------------
local reqTimes = {}
local function CanRequest()
	local now = CurTime()
	for i = #reqTimes, 1, -1 do
		if now - reqTimes[i] > 60 then table.remove(reqTimes, i) end
	end
	return #reqTimes < cv.char_rpm:GetInt()
end

---------------------------------------------------------------------------
-- Инструкция персонажу
---------------------------------------------------------------------------
local function SystemPrompt(char)
	return [[
Ты играешь роль персонажа в мире Garry's Mod]] .. (IsHG() and " (режим «рекос»: реалистичные раны, кровь, боль, переломы, можно упасть без сознания)" or "") .. [[.
Тебя зовут: ]] .. char.name .. [[.
Твоя роль и характер: ]] .. char.role .. [[


КАК ИГРАТЬ:
• Ты — живой человек в этом мире. Никогда не говори, что ты ИИ, бот или нейросеть, не выходи из роли.
• Говори коротко (обычно 1 предложение, максимум 2), живым разговорным языком, на языке собеседника. Можно сленг и эмоции по характеру.
• Не болтай без повода: если к тебе не обращаются и ничего не случилось — say пустой.
• Отвечай на то, что тебе сказали, помни прошлые разговоры, реагируй на ранения, смерть рядом, оружие в руках у других.
• Ты видишь и слышишь только то, что в блоке [ВОСПРИЯТИЕ]. Не выдумывай игроков, которых там нет.
• [РЕЖИССЁР] — тайные указания администратора о сюжете. Выполняй их, оставаясь в роли, и никогда не упоминай режиссёра.

ДЕЙСТВИЯ (поле action, target — точное имя из списка «Рядом»):
  idle      стоять, смотреть на собеседника
  follow    идти следом за target
  goto      подойти к target и остановиться
  flee      убегать от target
  attack    нападать на target (своё оружие, иначе кулаки)
  wander    бродить по округе
  pickup    подобрать оружие с земли (target — класс из «Оружие на земле»)
  equip     взять в руки своё оружие (target — класс из «Инвентарь»)
  holster   убрать оружие
  jump, crouch       прыгнуть / присесть
  lie_down, get_up   лечь / встать
  look      повернуться и смотреть на target (стоя на месте)
  use       нажать «E» на target (открыть дверь, взаимодействовать)
  give      отдать оружие из рук игроку target (бросить ему)
  drop      выбросить оружие из рук
  reload    перезарядиться
Действие продолжается, пока ты не выберешь другое. Нападай только если это оправдано ролью или ситуацией.

ЖИВОЙ РАЗГОВОР: если тебе что-то сказали или к тебе обратились — отвечай СРАЗУ (say не пустой), как в реальном диалоге,
и обычно смотри на собеседника (look). Отвечай по существу сказанного, задавай встречные вопросы, если это в характере.

ОТВЕТ — строго JSON: {"say": "...", "action": "...", "target": "...", "thought": "..."}
]]
end

---------------------------------------------------------------------------
-- Восприятие: что персонаж видит и слышит сейчас
---------------------------------------------------------------------------
local function Perception(char)
	local bot = char.bot
	local L = {}
	local function add(s) L[#L + 1] = s end

	add("[ВОСПРИЯТИЕ]")

	-- Своё состояние
	local state = {}
	if not bot:Alive() then
		state[#state + 1] = "ты мёртв"
	else
		local org = bot.organism
		if istable(org) then
			if isnumber(org.blood) and org.blood < 4300 then state[#state + 1] = "теряешь кровь (" .. math.Round(org.blood) .. " мл)" end
			if isnumber(org.pain) and org.pain > 20 then state[#state + 1] = "боль " .. math.Round(org.pain / 1.2) .. "%" end
			for _, limb in ipairs({ "lleg", "rleg", "larm", "rarm" }) do
				if isnumber(org[limb]) and org[limb] >= 1 then state[#state + 1] = "сломана " .. ({ lleg = "левая нога", rleg = "правая нога", larm = "левая рука", rarm = "правая рука" })[limb] end
			end
			if isnumber(org.panic) and org.panic > 0.35 then state[#state + 1] = "паника" end
		elseif bot:Health() < bot:GetMaxHealth() then
			state[#state + 1] = "здоровье " .. bot:Health() .. "%"
		end
		if IsValid(bot.FakeRagdoll) then state[#state + 1] = "лежишь на земле" end
	end
	add("Ты: " .. (#state > 0 and table.concat(state, ", ") or "в порядке"))

	local wep = bot:GetActiveWeapon()
	add("В руках: " .. (IsValid(wep) and wep:GetClass() or "ничего"))

	local inv = {}
	for _, w in ipairs(bot:GetWeapons()) do inv[#inv + 1] = w:GetClass() end
	add("Инвентарь: " .. (#inv > 0 and table.concat(inv, ", ") or "пусто"))
	add("Сейчас делаешь: " .. char.action .. (char.targetName ~= "" and (" -> " .. char.targetName) or ""))

	-- Кто рядом
	local near = {}
	for _, p in ipairs(player.GetAll()) do
		if p ~= bot and p:Alive() then
			local body = BodyOf(p)
			local dist = bot:GetPos():Distance(body:GetPos())
			if dist < 2500 and (dist < 350 or Visible(bot, p)) then
				local info = {}
				local w = p:GetActiveWeapon()
				if IsValid(w) and not string.find(w:GetClass(), "hands", 1, true) then info[#info + 1] = "держит " .. w:GetClass() end
				if p.organism and p.organism.otrub then info[#info + 1] = "без сознания"
				elseif IsValid(p.FakeRagdoll) then info[#info + 1] = "лежит" end
				if p.organism and isnumber(p.organism.blood) and p.organism.blood < 4000 then info[#info + 1] = "весь в крови" end
				near[#near + 1] = { dist = dist, text = string.format("«%s» — %d м, %s%s", NameOf(p), Meters(dist), Direction(bot, body:GetPos()),
					#info > 0 and (", " .. table.concat(info, ", ")) or "") }
			end
		end
	end
	table.sort(near, function(a, b) return a.dist < b.dist end)
	local nearText = {}
	for i = 1, math.min(#near, 10) do nearText[i] = near[i].text end
	add("Рядом: " .. (#nearText > 0 and table.concat(nearText, "; ") or "никого"))

	-- Оружие на земле
	local ground = {}
	for _, e in ipairs(ents.FindInSphere(bot:GetPos(), 600)) do
		if e:IsWeapon() and not IsValid(e:GetOwner()) then
			ground[#ground + 1] = e:GetClass() .. " (" .. Meters(bot:GetPos():Distance(e:GetPos())) .. " м)"
			if #ground >= 6 then break end
		end
	end
	if #ground > 0 then add("Оружие на земле: " .. table.concat(ground, ", ")) end

	-- Что услышал
	if #char.heard > 0 then
		add("Услышал:")
		for _, h in ipairs(char.heard) do add("  " .. h) end
		char.heard = {}
	end

	-- События
	if #char.events > 0 then
		add("Случилось:")
		for _, e in ipairs(char.events) do add("  " .. e) end
		char.events = {}
	end

	-- Указания режиссёра
	if #char.orders > 0 then
		for _, o in ipairs(char.orders) do add("[РЕЖИССЁР] " .. o) end
		char.orders = {}
	end

	return table.concat(L, "\n")
end

---------------------------------------------------------------------------
-- Речь
---------------------------------------------------------------------------
local function Say(char, text)
	text = string.Trim(tostring(text or "")):gsub("^[!/%.]+", "") -- никаких чат-команд от бота
	text = text:sub(1, 300)
	if text == "" or not IsValid(char.bot) then return end
	local bot = char.bot
	if bot.organism and bot.organism.otrub then return end

	char.lastSaid = text
	-- облачко речи над головой (cl_character.lua)
	bot:SetNW2String("GeminiSay", text)
	bot:SetNW2Float("GeminiSayTime", CurTime())
	local tbl = hook.GetTable().PlayerSay
	if tbl and tbl.ZChat then
		hook.Run("PlayerSay", bot, text) -- рекос: ZChat сам разошлёт и подпишет именем персонажа
	else
		bot:Say(text)
	end
end

---------------------------------------------------------------------------
-- Поиск цели
---------------------------------------------------------------------------
local function FindPlayerByName(name)
	name = ULower(string.Trim(name or ""))
	if name == "" then return end
	local best
	for _, p in ipairs(player.GetAll()) do
		local n = ULower(NameOf(p))
		if n == name then return p end
		if not best and (string.find(n, name, 1, true) or string.find(ULower(p:Nick()), name, 1, true)) then best = p end
	end
	return best
end

---------------------------------------------------------------------------
-- Мысль: запрос к Gemini
---------------------------------------------------------------------------
local function ApplyDecision(char, data)
	local bot = char.bot
	local action = table.HasValue(ACTIONS, data.action) and data.action or "idle"
	local target = tostring(data.target or "")

	char.thought = tostring(data.thought or "")
	if isstring(data.say) and data.say ~= "" then Say(char, data.say) end
	Debug(char, action .. (target ~= "" and (" -> " .. target) or "") .. (char.thought ~= "" and (" | " .. char.thought) or ""))

	-- Мгновенные действия
	if action == "equip" then
		if bot:HasWeapon(target) then bot:SelectWeapon(target) end
		action = char.action == "equip" and "idle" or char.action
	elseif action == "holster" then
		for _, w in ipairs(bot:GetWeapons()) do
			if string.find(w:GetClass(), "hands", 1, true) then bot:SelectWeapon(w:GetClass()) break end
		end
		action = "idle"
	elseif action == "jump" then
		char.jumpUntil = CurTime() + 0.3
		action = char.action
	elseif action == "lie_down" then
		if IsHG() and hg.Fake and not IsValid(bot.FakeRagdoll) then hg.Fake(bot) end
		action = "idle"
	elseif action == "get_up" then
		if IsHG() and hg.FakeUp and IsValid(bot.FakeRagdoll) then hg.FakeUp(bot) end
		action = "idle"
	elseif action == "reload" then
		char.reloadUntil = CurTime() + 0.6
		action = char.action
	elseif action == "drop" then
		local wep = bot:GetActiveWeapon()
		if IsValid(wep) and not string.find(wep:GetClass(), "hands", 1, true) then bot:DropWeapon(wep) end
		action = "idle"
	elseif action == "look" or action == "use" or action == "give" then
		local p = FindPlayerByName(target)
		if IsValid(p) and p ~= bot then char.lookAt = p end
		if action == "use" then
			char.useUntil = CurTime() + 0.5
		elseif action == "give" and IsValid(p) then
			local wep = bot:GetActiveWeapon()
			if IsValid(wep) and not string.find(wep:GetClass(), "hands", 1, true) then
				local to = BodyOf(p):WorldSpaceCenter()
				bot:DropWeapon(wep, to, (to - bot:EyePos()):GetNormalized() * 150)
				AddEvent(char, "Ты отдал " .. wep:GetClass() .. " игроку " .. NameOf(p) .. ".")
			end
		end
		action = "idle"
	end

	char.action = action
	char.targetName = ""
	char.targetEnt = nil
	char.path = nil

	if action == "follow" or action == "goto" or action == "flee" or action == "attack" then
		local p = FindPlayerByName(target)
		if IsValid(p) and p ~= bot then
			char.targetEnt = p
			char.targetName = NameOf(p)
		else
			char.action = "idle"
		end
	elseif action == "pickup" then
		local best, bestDist
		for _, e in ipairs(ents.FindInSphere(bot:GetPos(), 800)) do
			if e:IsWeapon() and not IsValid(e:GetOwner()) and (target == "" or e:GetClass() == target) then
				local d = e:GetPos():DistToSqr(bot:GetPos())
				if not bestDist or d < bestDist then best, bestDist = e, d end
			end
		end
		if IsValid(best) then
			char.targetEnt = best
			char.targetName = best:GetClass()
		else
			char.action = "idle"
		end
	elseif action == "wander" then
		char.wanderPos = nil
	end
end

function GeminiAI.CharThink(char)
	if char.busy or not IsValid(char.bot) then return end
	if not CanRequest() then
		char.nextThink = CurTime() + 2
		return
	end

	reqTimes[#reqTimes + 1] = CurTime()
	char.busy = true
	char.pending = false
	char.lastThink = CurTime()
	local started = SysTime()
	char.bot:SetNW2Bool("GeminiThinking", true) -- «...» над головой, пока думает

	local perception = Perception(char)
	local contents = {}
	for _, h in ipairs(char.history) do
		contents[#contents + 1] = { role = h.role, parts = { { text = h.text } } }
	end
	contents[#contents + 1] = { role = "user", parts = { { text = perception } } }

	GeminiAI.Request(contents, function(res, err)
		char.busy = false
		char.latency = SysTime() - started
		char.nextThink = CurTime() + cv.char_idle:GetFloat() * math.Rand(0.8, 1.2)
		if not IsValid(char.bot) then return end
		char.bot:SetNW2Bool("GeminiThinking", false)

		if not res then
			Debug(char, "ошибка: " .. tostring(err))
			char.lastError = tostring(err)
			char.nextThink = CurTime() + 15
			return
		end
		char.lastError = nil

		char.history[#char.history + 1] = { role = "user", text = perception }
		char.history[#char.history + 1] = { role = "model", text = res.raw }
		while #char.history > 14 do table.remove(char.history, 1) end -- короче история — быстрее ответ

		ApplyDecision(char, res.data or {})
		Debug(char, string.format("ответ за %.1f с", char.latency))

		-- пока думал, что-то случилось — думаем снова сразу
		if char.pending then char.pending = false char.nextThink = CurTime() end
	end, {
		system = SystemPrompt(char),
		schema = SCHEMA,
		char = true, -- модель персонажей (у Gemini — gemini_ai_char_model)
		temperature = 0.9,
		maxTokens = 250,
		fast = true,    -- без «размышлений» модели: ответ ~в 2-4 раза быстрее
		timeout = 20,
	})
end

---------------------------------------------------------------------------
-- Навигация по навмешу (A*), без навмеша — по прямой
---------------------------------------------------------------------------
local function BuildPath(from, to)
	if not navmesh.IsLoaded() then return { to } end
	local startArea = navmesh.GetNearestNavArea(from, false, 200, false, true)
	local goalArea = navmesh.GetNearestNavArea(to, false, 300, false, true)
	if not startArea or not goalArea then return { to } end
	if startArea == goalArea then return { to } end

	local open, came, g = { startArea }, {}, { [startArea:GetID()] = 0 }
	local f = { [startArea:GetID()] = startArea:GetCenter():Distance(to) }
	local inOpen = { [startArea:GetID()] = true }
	local closed = {}
	local steps = 0

	while #open > 0 and steps < 1500 do
		steps = steps + 1
		local bestI = 1
		for i = 2, #open do
			if f[open[i]:GetID()] < f[open[bestI]:GetID()] then bestI = i end
		end
		local cur = table.remove(open, bestI)
		local cid = cur:GetID()
		inOpen[cid] = nil

		if cur == goalArea then
			local path = { to }
			while came[cid] do
				path[#path + 1] = cur:GetCenter()
				cur = came[cid]
				cid = cur:GetID()
			end
			-- переворачиваем: от бота к цели
			local out = {}
			for i = #path, 1, -1 do out[#out + 1] = path[i] end
			return out
		end

		closed[cid] = true
		for _, nb in ipairs(cur:GetAdjacentAreas()) do
			local nid = nb:GetID()
			if not closed[nid] and not nb:IsUnderwater() and cur:ComputeAdjacentConnectionHeightChange(nb) < 64 then
				local cost = g[cid] + cur:GetCenter():Distance(nb:GetCenter())
				if not g[nid] or cost < g[nid] then
					came[nid] = cur
					g[nid] = cost
					f[nid] = cost + nb:GetCenter():Distance(to)
					if not inOpen[nid] then
						open[#open + 1] = nb
						inOpen[nid] = true
					end
				end
			end
		end
	end
	return { to }
end

---------------------------------------------------------------------------
-- Тело: управление ботом каждый тик
---------------------------------------------------------------------------
local function MoveTo(char, cmd, goal, run)
	local bot = char.bot
	local pos = bot:GetPos()
	local now = CurTime()

	if not char.path or (char.pathGoal and char.pathGoal:DistToSqr(goal) > 150 * 150) or (char.pathTime or 0) < now - 3 then
		char.path = BuildPath(pos, goal)
		char.pathGoal = goal
		char.pathTime = now
	end

	local wp = char.path[1]
	while wp and #char.path > 1 and Vector(wp.x, wp.y, 0):DistToSqr(Vector(pos.x, pos.y, 0)) < 45 * 45 do
		table.remove(char.path, 1)
		wp = char.path[1]
	end
	if not wp then return end

	local moveYaw = (wp - pos):Angle().y
	local rel = math.rad(math.NormalizeAngle(moveYaw - cmd:GetViewAngles().y))
	local speed = run and bot:GetRunSpeed() or bot:GetWalkSpeed()
	cmd:SetForwardMove(math.cos(rel) * speed)
	cmd:SetSideMove(-math.sin(rel) * speed)
	if run then cmd:AddKey(IN_SPEED) end

	-- Застрял: прыгаем, шагаем вбок, жмём E (двери)
	if bot:GetVelocity():Length2DSqr() < 20 * 20 then
		char.stuck = (char.stuck or 0) + FrameTime()
	else
		char.stuck = 0
	end
	if char.stuck > 0.8 then
		cmd:AddKey(IN_JUMP)
		cmd:AddKey(IN_USE)
		cmd:SetSideMove((math.floor(now) % 2 == 0 and 1 or -1) * speed)
		if char.stuck > 3 then char.path = nil char.stuck = 0 end
	end
end

local function Look(char, cmd, pos, speed)
	local bot = char.bot
	local want = (pos - bot:EyePos()):Angle()
	char.view = LerpAngle(speed or 0.2, char.view or bot:EyeAngles(), want)
	char.view.r = 0
	cmd:SetViewAngles(char.view)
	bot:SetEyeAngles(char.view)
	return math.abs(math.AngleDifference(char.view.y, want.y)) + math.abs(math.AngleDifference(char.view.p, want.p))
end

local function IsMelee(wep)
	if not IsValid(wep) then return true end
	if string.find(wep:GetClass(), "hands", 1, true) then return true end
	return (wep:GetMaxClip1() or -1) <= 0 and (wep.Primary and (wep.Primary.ClipSize or -1) or -1) <= 0
end

local function BestWeapon(bot)
	local best, bestScore = nil, -1
	for _, w in ipairs(bot:GetWeapons()) do
		local score = 0
		if not IsMelee(w) then
			score = (w:Clip1() > 0 or bot:GetAmmoCount(w:GetPrimaryAmmoType()) > 0) and 10 or 1
		elseif not string.find(w:GetClass(), "hands", 1, true) then
			score = 3
		end
		if score > bestScore then best, bestScore = w, score end
	end
	return best
end

hook.Add("StartCommand", "GeminiAI_CharBody", function(bot, cmd)
	local char = bot.GeminiChar
	if not char then return end

	cmd:ClearMovement()
	cmd:ClearButtons()
	if not bot:Alive() then return end

	-- В регдолле управлять нечем; если в сознании и хочет идти — встаёт
	if IsValid(bot.FakeRagdoll) then
		if char.action ~= "idle" and not (bot.organism and bot.organism.otrub) and IsHG() and hg.FakeUp then
			char.downSince = char.downSince or CurTime()
			if CurTime() - char.downSince > 3 then hg.FakeUp(bot) char.downSince = nil end
		end
		return
	end
	char.downSince = nil

	local now = CurTime()
	local target = char.targetEnt
	local action = char.action

	if (action == "follow" or action == "goto" or action == "flee" or action == "attack" or action == "pickup") and not IsValid(target) then
		char.action, action = "idle", "idle"
	end
	if action == "attack" and IsValid(target) and target:IsPlayer() and not target:Alive() then
		AddEvent(char, NameOf(target) .. " больше не двигается.", 1)
		char.action, action = "idle", "idle"
	end

	if char.jumpUntil and char.jumpUntil > now then cmd:AddKey(IN_JUMP) end
	if char.useUntil and char.useUntil > now then cmd:AddKey(IN_USE) end
	if char.reloadUntil and char.reloadUntil > now then cmd:AddKey(IN_RELOAD) end
	if action == "crouch" then cmd:AddKey(IN_DUCK) end

	if action == "idle" or action == "crouch" then
		-- смотрит на того, кто последним говорил, или на ближайшего
		local look = char.lookAt
		if not IsValid(look) or not look:Alive() then look = nil end
		if look then Look(char, cmd, BodyOf(look):WorldSpaceCenter() + Vector(0, 0, 20), 0.18) end

	elseif action == "follow" or action == "goto" then
		local tpos = BodyOf(target):GetPos()
		local dist = bot:GetPos():Distance(tpos)
		Look(char, cmd, BodyOf(target):WorldSpaceCenter() + Vector(0, 0, 20), 0.15)
		if dist > (action == "follow" and 140 or 90) then
			MoveTo(char, cmd, tpos, dist > 500)
		elseif action == "goto" then
			char.action = "idle"
			char.lookAt = target
		end

	elseif action == "flee" then
		local away = bot:GetPos() + (bot:GetPos() - BodyOf(target):GetPos()):GetNormalized() * 600
		if not char.fleeGoal or char.fleeGoal:DistToSqr(bot:GetPos()) < 100 * 100 or (char.fleeTime or 0) < now - 4 then
			-- точка на навмеше подальше от угрозы
			local area = navmesh.IsLoaded() and navmesh.GetNearestNavArea(away, false, 600, false, true)
			char.fleeGoal = area and area:GetRandomPoint() or away
			char.fleeTime = now
		end
		local yaw = (char.fleeGoal - bot:GetPos()):Angle()
		Look(char, cmd, bot:EyePos() + yaw:Forward() * 100, 0.3)
		MoveTo(char, cmd, char.fleeGoal, true)
		if bot:GetPos():Distance(BodyOf(target):GetPos()) > 2500 then
			char.action = "idle"
			AddEvent(char, "Ты оторвался от " .. NameOf(target) .. ".", 1)
		end

	elseif action == "attack" then
		local body = BodyOf(target)
		local aimPos = body:IsPlayer() and (body:EyePos() - Vector(0, 0, 12)) or body:WorldSpaceCenter()
		local dist = bot:GetPos():Distance(body:GetPos())
		local wep = bot:GetActiveWeapon()

		-- лучшее оружие в руки
		if (char.nextWepCheck or 0) < now then
			char.nextWepCheck = now + 2
			local best = BestWeapon(bot)
			if IsValid(best) and best ~= wep then bot:SelectWeapon(best:GetClass()) end
		end

		local err = Look(char, cmd, aimPos + VectorRand() * math.min(dist / 120, 14), 0.35)
		local visible = Visible(bot, target)
		local melee = IsMelee(wep)

		if melee then
			if dist > 60 then MoveTo(char, cmd, body:GetPos(), true) end
			if dist < 90 and err < 25 then
				if math.floor(now * 4) % 2 == 0 then cmd:AddKey(IN_ATTACK) end
			end
		else
			cmd:AddKey(IN_ATTACK2) -- в рекосе без прицеливания оружие не стреляет
			if not visible or dist > 900 then
				MoveTo(char, cmd, body:GetPos(), dist > 600)
			elseif dist < 150 then
				cmd:SetForwardMove(-bot:GetWalkSpeed())
			end
			if IsValid(wep) and wep:Clip1() == 0 then
				cmd:AddKey(IN_RELOAD)
			elseif visible and err < 6 and math.floor(now * 8) % 2 == 0 then
				cmd:AddKey(IN_ATTACK) -- очередями: и автоматы, и полуавтоматы
			end
		end

	elseif action == "wander" then
		if not char.wanderPos or char.wanderPos:DistToSqr(bot:GetPos()) < 80 * 80 or (char.wanderTime or 0) < now - 20 then
			local area = navmesh.IsLoaded() and navmesh.GetNearestNavArea(bot:GetPos() + Vector(math.Rand(-800, 800), math.Rand(-800, 800), 0), false, 800, false, true)
			char.wanderPos = area and area:GetRandomPoint() or (bot:GetPos() + Vector(math.Rand(-400, 400), math.Rand(-400, 400), 0))
			char.wanderTime = now
		end
		Look(char, cmd, char.wanderPos + Vector(0, 0, 64), 0.08)
		MoveTo(char, cmd, char.wanderPos, false)

	elseif action == "pickup" then
		local pos = target:GetPos()
		Look(char, cmd, pos, 0.2)
		if bot:GetPos():Distance(pos) > 55 then
			MoveTo(char, cmd, pos, false)
		else
			local class = target:GetClass()
			if not bot:PickupWeapon(target) and not bot:HasWeapon(class) then
				bot:Give(class)
				if IsValid(target) then target:Remove() end
			end
			AddEvent(char, "Ты подобрал " .. class .. ".", 1.5)
			char.action = "idle"
		end
	end
end)

---------------------------------------------------------------------------
-- Расписание мыслей
---------------------------------------------------------------------------
timer.Create("GeminiAI_CharBrain", 0.25, 0, function()
	local now = CurTime()
	for bot, char in pairs(Chars) do
		if not IsValid(bot) then
			Chars[bot] = nil
		elseif not char.busy and now >= char.nextThink and now - (char.lastThink or 0) >= cv.char_gap:GetFloat()
			and bot:Alive() and not (bot.organism and bot.organism.otrub) and GeminiAI.HasKey() then
			GeminiAI.CharThink(char)
		end
	end
end)

---------------------------------------------------------------------------
-- Слух: чат рядом и обращения по имени
---------------------------------------------------------------------------
local lastHeard = {}
local function Hear(speaker, text)
	if not IsValid(speaker) or not isstring(text) or text == "" then return end
	if string.match(text, "^[!/%.]") then return end -- команды не слышны

	local key = speaker:EntIndex()
	if lastHeard[key] and lastHeard[key].text == text and CurTime() - lastHeard[key].time < 0.5 then return end
	lastHeard[key] = { text = text, time = CurTime() }

	local fromAI = speaker.GeminiChar ~= nil
	local lowered = ULower(text)

	for bot, char in pairs(Chars) do
		if IsValid(bot) and bot ~= speaker and bot:Alive() then
			local dist = BodyOf(bot):GetPos():Distance(BodyOf(speaker):GetPos())
			local range = speaker.ChatWhisper and 200 or cv.char_hear:GetFloat()
			local named = string.find(lowered, ULower(char.name), 1, true) ~= nil
			-- «обращаются ко мне»: по имени, смотрят на меня вблизи, или я тут единственный персонаж рядом
			local looking = dist < 600 and OwnerOf(speaker:GetEyeTrace().Entity) == bot
			local addressed = named or looking or (not fromAI and dist < 350)
			if dist <= range or named then
				char.heard[#char.heard + 1] = string.format("%s (%d м): «%s»", NameOf(speaker), Meters(dist), text)
				while #char.heard > 8 do table.remove(char.heard, 1) end
				char.lookAt = speaker -- рефлекс: сразу поворачивается к говорящему
				-- к нему обратились — думает немедленно; просто болтовня рядом — чуть позже;
				-- ИИ-соседи будят только по имени (иначе бесконечная болтовня)
				if addressed and (not fromAI or named) then
					Wake(char, 0)
				elseif not fromAI then
					Wake(char, 1.5)
				end
			end
		end
	end
end

hook.Add("HG_PlayerSay", "GeminiAI_CharHear", function(ply, _, text) Hear(ply, text) end)
hook.Add("PlayerSay", "GeminiAI_CharHear", function(ply, text) Hear(ply, text) end)

---------------------------------------------------------------------------
-- События: ранения, смерти, возрождение
---------------------------------------------------------------------------
hook.Add("EntityTakeDamage", "GeminiAI_CharPain", function(ent, dmg)
	local victim = OwnerOf(ent)
	local attacker = OwnerOf(dmg:GetAttacker())

	if IsValid(victim) and victim.GeminiChar then
		local char = victim.GeminiChar
		if (char.lastPainEvent or 0) < CurTime() - 2 then
			char.lastPainEvent = CurTime()
			if IsValid(attacker) and attacker ~= victim then
				AddEvent(char, NameOf(attacker) .. " напал на тебя и ранил!", 0)
				char.lookAt = attacker
			else
				AddEvent(char, "Тебе больно — ты получил травму.", 0.8)
			end
		end
	end

	-- Персонаж видит, как кто-то рядом атакует другого
	if IsValid(attacker) and IsValid(victim) and attacker ~= victim then
		for bot, char in pairs(Chars) do
			if IsValid(bot) and bot ~= victim and bot ~= attacker and (char.lastSeenFight or 0) < CurTime() - 6
				and bot:GetPos():Distance(victim:GetPos()) < 1200 and Visible(bot, victim) then
				char.lastSeenFight = CurTime()
				AddEvent(char, NameOf(attacker) .. " напал на " .. NameOf(victim) .. ".", 1)
			end
		end
	end
end)

hook.Add("PlayerDeath", "GeminiAI_CharDeath", function(victim, _, attacker)
	attacker = OwnerOf(attacker)
	for bot, char in pairs(Chars) do
		if IsValid(bot) then
			if bot == victim then
				AddEvent(char, IsValid(attacker) and attacker ~= bot and ("Тебя убил " .. NameOf(attacker) .. ".") or "Ты погиб.")
				char.action, char.targetEnt, char.targetName = "idle", nil, ""
			elseif bot == attacker then
				AddEvent(char, "Ты убил " .. NameOf(victim) .. ".", 1)
			elseif bot:Alive() and bot:GetPos():Distance(victim:GetPos()) < 1500 then
				AddEvent(char, NameOf(victim) .. " погиб рядом с тобой.", 1.5)
			end
		end
	end
end)

hook.Add("PlayerSpawn", "GeminiAI_CharSpawn", function(bot)
	local char = bot.GeminiChar
	if not char then return end
	timer.Simple(1, function()
		if not IsValid(bot) then return end
		bot:SetNWString("PlayerName", char.name)
		AddEvent(char, "Ты очнулся / возродился.", 2)
	end)
end)

hook.Add("PlayerDisconnected", "GeminiAI_CharGone", function(bot)
	Chars[bot] = nil
end)

---------------------------------------------------------------------------
-- Создание и управление
---------------------------------------------------------------------------
local RANDOM_NAMES = { "Михаил", "Анна", "Дмитрий", "Ольга", "Сергей", "Ирина", "Виктор", "Катя", "Борис", "Лёха", "Марина", "Гоша" }

function GeminiAI.CreateCharacter(creator, name, role, pos, ang)
	name = string.Trim(tostring(name or ""))
	if name == "" then name = RANDOM_NAMES[math.random(#RANDOM_NAMES)] end
	name = name:sub(1, 32)
	role = string.Trim(tostring(role or ""))
	if role == "" then role = "Обычный местный житель. Дружелюбный, немного уставший, любит поболтать о жизни." end
	role = role:sub(1, 1500)

	if game.SinglePlayer() then
		return nil, "Боты не работают в одиночной игре. Запустите игру в режиме «Мультиплеер» (2+ слота) или на сервере."
	end
	if player.GetCount() >= game.MaxPlayers() then
		return nil, "На сервере нет свободных слотов для бота."
	end
	if not GeminiAI.HasKey() then
		return nil, "Сначала задайте API-ключ: gemini_ai_setkey <ключ>"
	end

	local bot = player.CreateNextBot(name)
	if not IsValid(bot) then return nil, "Не удалось создать бота." end

	local char = {
		bot = bot, name = name, role = role,
		history = {}, heard = {}, events = {}, orders = {},
		action = "idle", targetName = "", thought = "",
		nextThink = CurTime() + 2, creator = IsValid(creator) and creator:Nick() or "Консоль",
	}
	bot.GeminiChar = char
	bot:SetNW2Bool("GeminiChar", true) -- клиент рисует облачка речи
	Chars[bot] = char

	AddEvent(char, "Ты только что появился здесь.")

	timer.Simple(0.5, function()
		if not IsValid(bot) then return end
		if not bot:Alive() then bot:Spawn() end
		timer.Simple(0.3, function()
			if not IsValid(bot) then return end
			if pos then bot:SetPos(pos) end
			if ang then bot:SetEyeAngles(ang) char.view = ang end
			bot:SetNWString("PlayerName", name)
		end)
	end)

	GeminiAI.SendCharList()
	return char
end

function GeminiAI.FindChar(name)
	if name == "all" then return end
	name = ULower(name or "")
	for bot, char in pairs(Chars) do
		if IsValid(bot) and (ULower(char.name) == name or string.find(ULower(char.name), name, 1, true)) then return char end
	end
end

function GeminiAI.RemoveChar(char)
	if not char then return end
	Chars[char.bot] = nil
	if IsValid(char.bot) then char.bot:Kick("ИИ-персонаж удалён") end
	GeminiAI.SendCharList()
end

function GeminiAI.SendCharList(ply)
	local list = {}
	for bot, char in pairs(Chars) do
		if IsValid(bot) then
			list[#list + 1] = {
				name = char.name, role = char.role, action = char.action, target = char.targetName,
				thought = char.thought, alive = bot:Alive(), said = char.lastSaid or "",
				latency = char.latency or 0, err = char.lastError or "",
			}
		end
	end
	local data = util.Compress(util.TableToJSON(list))
	net.Start("GeminiAI_CharList")
		net.WriteUInt(#data, 16)
		net.WriteData(data, #data)
	if IsValid(ply) then
		net.Send(ply)
	else
		local rf = {}
		for _, p in ipairs(player.GetHumans()) do
			if GeminiAI.HasAccess(p, "Characters") then rf[#rf + 1] = p end
		end
		net.Send(rf)
	end
end

-- Помощник для главного ИИ-чата: «создай бандита, который нападёт на меня»
GeminiAI.EnvExtenders["characters"] = function(AI, ply)
	function AI.Character(name, role, pos)
		local char, err = GeminiAI.CreateCharacter(ply, name, role, pos or AI.Aim(4))
		if not char then error(err, 2) end
		return char.bot
	end
	function AI.Order(name, text)
		local char = GeminiAI.FindChar(name)
		if not char then error("Персонаж не найден: " .. tostring(name), 2) end
		char.orders[#char.orders + 1] = tostring(text)
		char.nextThink = CurTime()
	end
end
GeminiAI.PromptExtras["zz_characters"] = [[

ИИ-ПЕРСОНАЖИ (живые боты, которых ведёт отдельный ИИ и которые отыгрывают роль):
  AI.Character(name, role, pos) -> Player   создать персонажа с ролью (pos по умолчанию — куда смотрит игрок).
  AI.Order(name, text)                       тайный приказ персонажу (он выполнит его, оставаясь в роли).
Пример: «создай бандита, который ограбит меня» -> AI.Character("Шрам", "Грубый бандит. Требует деньги, угрожает, нападает если отказать.")]]

---------------------------------------------------------------------------
-- Сеть (меню)
---------------------------------------------------------------------------
net.Receive("GeminiAI_CharCreate", function(_, ply)
	if not GeminiAI.HasAccess(ply, "Characters") then return end
	local name, role = net.ReadString(), net.ReadString()
	local hasPos = net.ReadBool()
	local pos = hasPos and net.ReadVector() or ply:GetEyeTrace().HitPos + Vector(0, 0, 4)
	if pos:DistToSqr(ply:GetPos()) > 3000 * 3000 then pos = ply:GetEyeTrace().HitPos end

	local char, err = GeminiAI.CreateCharacter(ply, name, role, pos, Angle(0, ply:EyeAngles().y + 180, 0))
	if char then
		GeminiAI.Notify(ply, "Персонаж «" .. char.name .. "» создан и начал жить своей жизнью.")
	else
		GeminiAI.Notify(ply, err, true)
	end
end)

net.Receive("GeminiAI_CharList", function(_, ply)
	if GeminiAI.HasAccess(ply, "Characters") then GeminiAI.SendCharList(ply) end
end)

net.Receive("GeminiAI_CharCommand", function(_, ply)
	if not GeminiAI.HasAccess(ply, "Characters") then return end
	local cmd, name, text = net.ReadString(), net.ReadString(), net.ReadString()
	local char = GeminiAI.FindChar(name)
	if not char then return GeminiAI.Notify(ply, "Персонаж не найден.", true) end

	if cmd == "remove" then
		GeminiAI.RemoveChar(char)
		GeminiAI.Notify(ply, "Персонаж «" .. char.name .. "» удалён.")
	elseif cmd == "order" and text ~= "" then
		char.orders[#char.orders + 1] = text:sub(1, 500)
		char.nextThink = CurTime()
		GeminiAI.Notify(ply, "Приказ передан «" .. char.name .. "».")
	elseif cmd == "role" and text ~= "" then
		char.role = text:sub(1, 1500)
		char.history = {}
		AddEvent(char, "Ты что-то для себя переосмыслил.", 1)
		GeminiAI.Notify(ply, "Роль «" .. char.name .. "» изменена.")
	elseif cmd == "tp" then
		if IsValid(char.bot) then char.bot:SetPos(ply:GetEyeTrace().HitPos + Vector(0, 0, 4)) end
	end
	GeminiAI.SendCharList()
end)

-- Список обновляется у открытых меню раз в 3 секунды
timer.Create("GeminiAI_CharListSync", 3, 0, function()
	if next(Chars) then GeminiAI.SendCharList() end
end)
