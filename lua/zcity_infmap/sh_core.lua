-- Общие функции слоя совместимости и обёртка hook.Call.
--
-- Координаты в InfMap:
--   * "сырые" (локальные) координаты движка лежат в пределах одного чанка (±chunk_size);
--   * мировые = сырые + CHUNK_OFFSET * chunk_size * 2 (это возвращают GetPos, TraceLine и т.п. на сервере);
--   * на клиенте GetPos возвращает координаты относительно чанка LocalPlayer'а.

local ZCInf = ZCInf
ZCInf.Version = "1.0"
ZCInf.Installed = ZCInf.Installed or {}

local ZERO = Vector(0, 0, 0)
ZCInf.ZERO = ZERO

function ZCInf.Print(...)
	MsgC(Color(120, 200, 255), "[Z-City/InfMap] ", color_white, string.format(...), "\n")
end

function ZCInf.Mark(part)
	ZCInf.Installed[part] = true
end

local function cs2()
	return InfMap.chunk_size * 2
end
ZCInf.ChunkSpan = cs2

function ZCInf.IsZero(c)
	return c == nil or (c[1] == 0 and c[2] == 0 and c[3] == 0)
end
local IsZero = ZCInf.IsZero

-- одинаковый ли чанк (nil считается нулевым чанком)
function ZCInf.SameChunk(a, b)
	local za, zb = IsZero(a), IsZero(b)
	if za or zb then return za and zb end
	return a == b
end

-- локальная позиция чанка c -> мировая
function ZCInf.ToWorld(pos, c)
	if IsZero(c) then return Vector(pos) end
	return pos + c * cs2()
end

-- мировая позиция -> локальная относительно чанка c
function ZCInf.ToLocal(pos, c)
	if IsZero(c) then return Vector(pos) end
	return pos - c * cs2()
end

-- запас до границы мира Source, где движок начинает обрезать координаты
ZCInf.Bound = InfMap.source_bounds[1] - 64

function ZCInf.InBounds(v, b)
	b = b or ZCInf.Bound
	return v[1] > -b and v[1] < b and v[2] > -b and v[2] < b and v[3] > -b and v[3] < b
end

function ZCInf.Clamp(v)
	local b = ZCInf.Bound
	return Vector(math.Clamp(v[1], -b, b), math.Clamp(v[2], -b, b), math.Clamp(v[3], -b, b))
end

-- Заменить функция tbl[name] обёрткой make(orig).
-- Оригинал запоминается один раз в tbl["ZCInf_" .. name], чтобы при перезагрузке
-- файла (lua refresh) не оборачивать уже обёрнутое.
function ZCInf.Detour(tbl, name, make)
	local key = "ZCInf_" .. name
	if tbl[key] == nil then tbl[key] = tbl[name] end
	local orig = tbl[key]
	if orig == nil then return false end
	tbl[name] = make(orig)
	return true
end

-- Есть ли хоть один игрок не в нулевом чанке (кэш на тик).
-- Пока все в чанке 0, сырые и мировые координаты совпадают, и многие обёртки
-- идут по быстрому пути, ничего не меняя.
local offTick, offVal = -1, false
function ZCInf.AnyOffChunk()
	local t = engine.TickCount()
	if t ~= offTick then
		offTick = t
		offVal = false
		for _, ply in player.Iterator() do
			if not IsZero(ply.CHUNK_OFFSET) then
				offVal = true
				break
			end
		end
	end
	return offVal
end

if CLIENT then
	function ZCInf.LPChunk()
		local lp = LocalPlayer()
		return IsValid(lp) and lp.CHUNK_OFFSET or nil
	end

	-- мировая позиция (с сервера) -> координаты клиента (относительно чанка LocalPlayer)
	function ZCInf.WorldToClient(pos)
		return ZCInf.ToLocal(pos, ZCInf.LPChunk())
	end
end

--[[-------------------------------------------------------------------------
	Обёртка hook.Call.

	Часть событий нужно обработать ДО всех хуков (порядок хуков в GMod не
	гарантирован, а хуки InfMap и Z-City мешают друг другу). Движок вызывает
	события через глобальный hook.Call, поэтому оборачиваем его.

	ZCInf.HookWraps[event] = function(call, name, gm, ...) ... end
	где call - оригинальный hook.Call.
---------------------------------------------------------------------------]]
ZCInf.HookWraps = ZCInf.HookWraps or {}
local wraps = ZCInf.HookWraps

function ZCInf.InstallHookCall()
	local cur = hook.Call
	if cur == ZCInf.HookCallWrapper then return false end

	local orig = cur
	local function wrapper(name, gm, ...)
		local w = wraps[name]
		if w ~= nil then return w(orig, name, gm, ...) end
		return orig(name, gm, ...)
	end

	ZCInf.HookCallWrapper = wrapper
	hook.Call = wrapper
	return true
end

ZCInf.InstallHookCall()
ZCInf.Mark("hook.Call")

-- ULib и подобные аддоны заменяют библиотеку hook при своей загрузке:
-- ставим обёртку заново после загрузки всех аддонов и следим, чтобы её не сняли.
hook.Add("Initialize", "ZCInf_HookCall", function()
	ZCInf.InstallHookCall()
end)

hook.Add("InitPostEntity", "ZCInf_HookCall", function()
	ZCInf.InstallHookCall()
end)

timer.Create("ZCInf_HookCallWatch", 5, 0, function()
	if ZCInf.InstallHookCall() then
		ZCInf.Print("hook.Call был заменён другим аддоном - обёртка установлена заново")
	end
end)

--[[-------------------------------------------------------------------------
	Столкновения между чанками.
	InfMap запрещает столкновения сущностей из разных чанков своим хуком,
	но если какой-то хук Z-City вернёт true раньше, сущности из разных чанков,
	стоящие в одних и тех же сырых координатах, начнут сталкиваться.
	Проверяем до всех хуков.
---------------------------------------------------------------------------]]
wraps.ShouldCollide = function(call, name, gm, e1, e2)
	if e1 ~= nil and e2 ~= nil then
		local c1, c2 = e1.CHUNK_OFFSET, e2.CHUNK_OFFSET
		if c1 ~= c2 and not e1:IsWorld() and not e2:IsWorld() then
			return false
		end
	end
	return call(name, gm, e1, e2)
end
ZCInf.Mark("ShouldCollide")
