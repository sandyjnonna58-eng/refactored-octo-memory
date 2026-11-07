-- OctoCamo для Снейка (аддон "Metal Gear Solid V: Gameplay SWEP", см. sh_mgsv.lua) - свой вариант механики, без чужих моделей
-- и текстур: в меню CAMO (кнопка контекстного меню) появляется строка "OCTOCAMO". Костюм перенимает рисунок поверхности,
-- к которой Снейк прижат: стоишь/сидишь/лежишь неподвижно у стены или на земле ~1 с - за пару секунд костюм "перетекает"
-- в бетон, кирпич, траву, дерево... и держит рисунок, пока не прижмёшься к другой поверхности. На ходу рисунок не меняется.
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
	stillSpeed = 12,   -- быстрее этого - "двигается", рисунок не перенимает
	stillTime = 0.8,   -- сколько стоять неподвижно до начала смены
	fadeOut = 3,       -- старый рисунок уходит (в секунду)
	fadeIn = 0.7,      -- новый проступает (в секунду)
	poll = 0.2,        -- как часто смотреть на поверхность
	scale = 2,         -- рисунок поверхности мельче на костюме (плотнее)
	wallDist = 34,     -- насколько близко стена, чтобы "прижаться"
}

-- материал костюма из текстуры поверхности (VertexLitGeneric, иначе на модели мировой материал не рисуется)
local mats, matCount = {}, 0
local function SurfaceMat(name)
	if not name or name == "" or string.find(name, "^TOOLS/") or name == "**studio**" or name == "**displacement**" then return end
	local cached = mats[name]
	if cached ~= nil then return cached or nil end
	local m = Material(name)
	local tex = not m:IsError() and m:GetTexture("$basetexture")
	if not tex or tex:IsError() then mats[name] = false return end
	matCount = matCount + 1
	local cm = CreateMaterial("rem_octo_" .. matCount, "VertexLitGeneric", {
		["$basetexture"] = tex:GetName(),
		["$basetexturetransform"] = "center .5 .5 scale " .. C.scale .. " " .. C.scale .. " rotate 0 translate 0 0",
		["$model"] = 1,
	})
	cm:SetTexture("$basetexture", tex)
	mats[name] = cm
	return cm
end

-- к чему прижат: лежит/сидит - пол под ним, стоит у стены - ближайшая стена, иначе пол
local dirs = {Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0)}
local function Surface(ply)
	local S = MGSVSnake
	local st = S.State and S.State(ply)
	local pos = ply:GetPos()
	local low = st == S.ST_PRONE or st == S.ST_CROUCH or st == S.ST_TO_PRONE
	if not low then
		local from = pos + Vector(0, 0, 40)
		local best
		for _, d in ipairs(dirs) do
			local tr = util.TraceLine({start = from, endpos = from + d * C.wallDist, filter = ply, mask = MASK_SOLID_BRUSHONLY})
			if tr.Hit and (not best or tr.Fraction < best.Fraction) then best = tr end
		end
		if best then return best.HitTexture end
	end
	local tr = util.TraceLine({start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 32), filter = ply, mask = MASK_SOLID_BRUSHONLY})
	return tr.Hit and tr.HitTexture or nil
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

		if ply:GetVelocity():Length2D() < C.stillSpeed and ply:OnGround() then s.still = s.still + dt else s.still = 0 end

		if s.still >= C.stillTime and now >= s.nextPoll then
			s.nextPoll = now + C.poll
			local m = SurfaceMat(Surface(ply))
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
