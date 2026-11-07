-- OctoCamo для Снейка (аддон "Metal Gear Solid V: Gameplay SWEP", см. sh_mgsv.lua) - свой вариант механики, без чужих моделей
-- и текстур: в меню CAMO (кнопка контекстного меню) появляется строка "OCTOCAMO". Костюм перенимает рисунок поверхности
-- только в двух случаях (3 с неподвижно на одном месте):
--   1) лежит - рисунок пола под ним;
--   2) упёрся в стену (вплотную или в укрытии аддона), стоя или на корточках - рисунок стены.
-- Просто стоя/сидя не у стены и на ходу рисунок не меняется; держится, пока не сменишь поверхность.
-- Трава/земля/песок/снег на дисплейсментах: движок не отдаёт их материал, поэтому по типу поверхности берётся
-- текстура игры, а если её нет - своя (materials/rem_octo/*.png, tools/octocamo/make.py).
-- Видно всем: выбор синхронизирует сервер (NW2 "rem_octo"), рисунок каждый клиент берёт сам по той же поверхности.
-- Картинка для меню - tools/octocamo/make.py.
local OCTO_SKIN = 90 -- номер "камуфляжа" в mgsv_snake_drab; у модели такого скина нет - базой остаётся обычный (0)

local function OctoOn(ply)
	if not IsValid(ply) or not MGSVSnake or not MGSVSnake.HasDrabs or not MGSVSnake.HasDrabs(ply) then return false end
	if CLIENT and ply == LocalPlayer() then
		local cv = GetConVar("mgsv_snake_drab")
		return cv and cv:GetInt() == OCTO_SKIN or false
	end
	return ply:GetNW2Bool("rem_octo", false)
end
hg.MGSV = hg.MGSV or {}
hg.MGSV.OctoOn = OctoOn

-- строка в меню CAMO аддона
local function AddToMenu()
	local S = MGSVSnake
	if not S or not S.DRABS or S.RemOctoAdded then return end
	S.RemOctoAdded = true
	table.insert(S.DRABS, {skin = OCTO_SKIN, art = "rem_octo", name = "OCTOCAMO"})
end
AddToMenu()
timer.Simple(0, AddToMenu)
hook.Add("InitPostEntity", "rem_mgsv_octo_menu", AddToMenu)

if SERVER then
	resource.AddSingleFile("materials/mgsv_snake/loadout/drabs/rem_octo.png")
	for _, n in ipairs({"grass", "dirt", "sand", "snow"}) do resource.AddSingleFile("materials/rem_octo/" .. n .. ".png") end
	-- аддон сам сбрасывает неизвестный номер камуфляжа в 0 для других игроков - выбор OctoCamo передаём отдельно
	timer.Create("rem_mgsv_octo", 0.5, 0, function()
		for _, p in ipairs(player.GetHumans()) do
			local on = math.floor(p:GetInfoNum("mgsv_snake_drab", 0)) == OCTO_SKIN
			if p:GetNW2Bool("rem_octo", false) ~= on then p:SetNW2Bool("rem_octo", on) end
		end
	end)
	return
end

local C = {
	stillSpeed = 6,    -- быстрее этого - "двигается"
	stillTime = 3,     -- сколько неподвижно на одном месте до смены рисунка
	stillDrift = 8,    -- сдвинулся дальше этого от точки, где замер, - отсчёт заново
	fadeOut = 3,       -- старый рисунок уходит (в секунду)
	fadeIn = 0.7,      -- новый проступает (в секунду)
	poll = 0.2,        -- как часто смотреть на поверхность
	scale = 2,         -- рисунок поверхности мельче на костюме (плотнее)
	wallDist = 24,     -- от центра до стены: вплотную (полуширина игрока 16)
}

-- материал костюма из текстуры (VertexLitGeneric, иначе на модели мировой материал не рисуется)
local mats, matCount = {}, 0
local function MatFromTexture(tex)
	if not tex or tex:IsError() then return end
	local key = tex:GetName()
	if mats[key] then return mats[key] end
	matCount = matCount + 1
	local cm = CreateMaterial("rem_octo_" .. matCount, "VertexLitGeneric", {
		["$basetexture"] = key,
		["$basetexturetransform"] = "center .5 .5 scale " .. C.scale .. " " .. C.scale .. " rotate 0 translate 0 0",
		["$model"] = 1,
	})
	cm:SetTexture("$basetexture", tex)
	mats[key] = cm
	return cm
end

local function TexOf(matName, wantGrass)
	local m = Material(matName)
	if m:IsError() then return end
	local t1, t2 = m:GetTexture("$basetexture"), m:GetTexture("$basetexture2")
	-- смешанный материал (земля+трава): для травы берём ту половину, где трава
	if wantGrass and t2 and not t2:IsError() and string.find(string.lower(t2:GetName()), "grass", 1, true) then return t2 end
	if t1 and not t1:IsError() then return t1 end
end

-- по типу поверхности: сначала текстуры игры, потом свои
local BY_TYPE = {
	[MAT_GRASS] = {"nature/grassfloor002a", "nature/grassfloor001a", "rem_octo/grass.png"},
	[MAT_FOLIAGE] = {"nature/grassfloor002a", "rem_octo/grass.png"},
	[MAT_DIRT] = {"nature/dirtfloor003a", "nature/dirtfloor005c", "rem_octo/dirt.png"},
	[MAT_SAND] = {"nature/sandfloor010a", "nature/sandfloor009a", "rem_octo/sand.png"},
	[MAT_SNOW] = {"nature/snowfloor001a", "rem_octo/snow.png"},
}
local typeTex = {}
local function TexForType(mt)
	if typeTex[mt] ~= nil then return typeTex[mt] or nil end
	for _, name in ipairs(BY_TYPE[mt] or {}) do
		local t = TexOf(name)
		if t then typeTex[mt] = t return t end
	end
	typeTex[mt] = false
end

-- материал костюма по результату трассировки
local function MatFromTrace(tr)
	if not tr or not tr.Hit or tr.HitSky then return end
	local name = tr.HitTexture or ""
	local grassy = tr.MatType == MAT_GRASS or tr.MatType == MAT_FOLIAGE
	local tex
	if name ~= "" and name ~= "**displacement**" and name ~= "**studio**" and not string.find(name, "^TOOLS/") then
		tex = TexOf(name, grassy)
	end
	-- дисплейсмент (трава, земля...) или материал без текстуры - по типу поверхности
	if not tex or (grassy and not string.find(string.lower(tex:GetName()), "grass", 1, true)) then
		tex = TexForType(tr.MatType) or tex
	end
	return MatFromTexture(tex)
end

-- к чему прижат: лежит - пол под ним; стоит/сидит - стена вплотную (или укрытие аддона); иначе ни к чему
local dirs = {Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0),
	Vector(0.707, 0.707, 0), Vector(-0.707, 0.707, 0), Vector(0.707, -0.707, 0), Vector(-0.707, -0.707, 0)}
local function Surface(ply)
	local S = MGSVSnake
	local st = S.State and S.State(ply)
	local pos = ply:GetPos()
	if st == S.ST_PRONE then
		return util.TraceLine({start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 32), filter = ply, mask = MASK_SOLID_BRUSHONLY})
	end
	if st ~= S.ST_STAND and st ~= S.ST_CROUCH and st ~= S.ST_COVER then return end
	local dist = st == S.ST_COVER and C.wallDist + 16 or C.wallDist
	local from = pos + Vector(0, 0, st == S.ST_CROUCH and 20 or 36)
	local best
	for _, d in ipairs(dirs) do
		local tr = util.TraceLine({start = from, endpos = from + d * dist, filter = ply, mask = MASK_SOLID_BRUSHONLY})
		if tr.Hit and not tr.HitSky and math.abs(tr.HitNormal.z) < 0.5 and (not best or tr.Fraction < best.Fraction) then best = tr end
	end
	return best
end

local state = setmetatable({}, {__mode = "k"}) -- игрок -> {mat, want, k, still, nextPoll}

hook.Add("Think", "rem_mgsv_octo", function()
	if not MGSVSnake then return end
	local now, dt = CurTime(), FrameTime()
	for _, ply in ipairs(player.GetAll()) do
		if not OctoOn(ply) or ply:IsDormant() then
			state[ply] = nil
			continue
		end
		local s = state[ply]
		if not s then s = {k = 0, still = 0, nextPoll = 0} state[ply] = s end

		-- неподвижно на одном месте: скорость маленькая и не уехал от точки, где замер
		local pos = ply:GetPos()
		if ply:GetVelocity():Length2D() < C.stillSpeed and ply:OnGround()
			and s.stillAt and pos:DistToSqr(s.stillAt) < C.stillDrift * C.stillDrift then
			s.still = s.still + dt
		else
			s.still, s.stillAt = 0, pos
		end

		if s.still >= C.stillTime and now >= s.nextPoll then
			s.nextPoll = now + C.poll
			local m = MatFromTrace(Surface(ply))
			if m and m ~= s.mat then s.want = m end
		end

		-- смена рисунка: старый уходит, потом проступает новый
		if s.want and s.want ~= s.mat then
			s.k = math.Approach(s.k, 0, dt * C.fadeOut)
			if s.k <= 0 or not s.mat then s.mat, s.k = s.want, 0 end
		elseif s.mat then
			s.k = math.Approach(s.k, 1, dt * C.fadeIn)
		end
	end
end)

-- рисуем модель Снейка: обычный костюм, поверх - рисунок поверхности с нужной прозрачностью
local function Install()
	local S = MGSVSnake
	if not S or S.RemOctoDraw then return end
	S.RemOctoDraw = true
	local prev = S.DrawBody
	S.DrawBody = function(ent, r, ply)
		local s = state[ply]
		if not s or not s.mat or s.k <= 0.01 then
			return prev and prev(ent, r, ply) or false
		end
		if not (prev and prev(ent, r, ply)) then ent:DrawModel() end
		render.MaterialOverride(s.mat)
		render.SetBlend(s.k * 0.92)
		ent:DrawModel()
		render.SetBlend(1)
		render.MaterialOverride()
		return true
	end
end
Install()
timer.Simple(0, Install)
hook.Add("InitPostEntity", "rem_mgsv_octo_draw", Install)
