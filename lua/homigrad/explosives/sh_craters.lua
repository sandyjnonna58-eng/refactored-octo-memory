-- Пробоины и воронки от взрывов. Стену карты по-настоящему не пробить (столкновения карты не меняются), поэтому
-- это картинка: на ближайших к взрыву стенах / полу - большая рваная пробоина (чёрная дыра, разбитый край, трещины,
-- копоть), на мягкой земле - воронка, на металле - только копоть; от места взрыва летят обломки.
-- Размер - от силы взрыва (power: граната ~0.5, СВУ ~0.9, РПГ 1). Текстуры - tools/craters/make.py -> materials/rem_crater.
-- Выключить: rem_craters 0 (сервер). Обломки у игрока: rem_craters_debris 0..2 (0 - нет, 1 - как есть, 2 - вдвое больше).
-- Сквозные пробоины: в тонкой стене (до portal_max_thick) дыра видна насквозь - перед кадром мир за стеной рисуется
-- той же камерой в текстуру (обрезанный по задней стороне стены), и она показывается только внутри отверстия
-- (трафарет: что стоит перед дырой, её закрывает). Тяжело для FPS, поэтому только rem_crater_portals ближайших
-- в поле зрения (0 - выкл.), не дальше portal_max_dist, текстура в долю экрана rem_crater_portal_res.
-- Камера Z-City рисует кадр сама - отрисовку дыр зовёт она (cl_camera.lua), иначе картинка съехала бы.
hg.Craters = hg.Craters or {}

local CRATER_MATS = {"crater_wall", "crater_wall2", "crater_ground", "scorch_metal"}

if SERVER then
	util.AddNetworkString("rem_crater")
	for _, n in ipairs(CRATER_MATS) do
		resource.AddSingleFile("materials/rem_crater/" .. n .. ".vmt")
		resource.AddSingleFile("materials/rem_crater/" .. n .. ".vtf")
	end

	local cv = CreateConVar("rem_craters", 1, FCVAR_ARCHIVE + FCVAR_REPLICATED, "Explosion holes and craters on walls and floors", 0, 1)

	function hg.ExplosionCrater(pos, power)
		if not cv:GetBool() or not isvector(pos) then return end
		net.Start("rem_crater")
			net.WriteVector(pos)
			net.WriteFloat(math.Clamp(power or 0.5, 0.1, 1.5))
		net.SendPVS(pos)
	end
	return
end

local cvDebris = CreateClientConVar("rem_craters_debris", 1, true, false, "Explosion debris amount (0 - none, 2 - double)", 0, 2)
local cvPortals = CreateClientConVar("rem_crater_portals", 2, true, false, "See-through explosion holes drawn at once (0 - off)", 0, 4)
local cvPortalRes = CreateClientConVar("rem_crater_portal_res", 0.5, true, false, "See-through hole picture resolution (share of the screen)", 0.25, 1)
local portal_max_thick = 40   -- юнитов: стена тоньше - дыра сквозная
local portal_max_dist = 1200
local portal_hole_k = 0.13    -- радиус отверстия от размера пробоины (как чёрная дыра на текстуре)
local max_portals = 16

local mats
local function Mats()
	if mats then return mats end
	local function M(n) local m = Material("rem_crater/" .. n) return not m:IsError() and m or nil end
	mats = {
		wall = {M("crater_wall"), M("crater_wall2")},
		ground = {M("crater_ground")},
		metal = {M("scorch_metal")},
	}
	return mats
end

local SOFT = {[MAT_DIRT] = true, [MAT_GRASS] = true, [MAT_SAND] = true, [MAT_SNOW] = true, [MAT_FOLIAGE] = true, [MAT_SLOSH] = true}
local METAL = {[MAT_METAL] = true, [MAT_GRATE] = true, [MAT_VENT] = true, [MAT_COMPUTER] = true}

-- куда ищем поверхности: 6 осей и 8 диагоналей
local DIRS = {}
for _, v in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) do DIRS[#DIRS + 1] = Vector(v[1], v[2], v[3]) end
for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do DIRS[#DIRS + 1] = Vector(x, y, z):GetNormalized() end end end

-- обломки из стандартного контента HL2; неверные модели отсеиваются при первом взрыве
local DEBRIS = {
	concrete = {"models/props_debris/concrete_chunk02a.mdl", "models/props_debris/concrete_chunk02b.mdl", "models/props_debris/concrete_chunk03a.mdl",
		"models/props_debris/concrete_chunk04a.mdl", "models/props_debris/concrete_chunk05g.mdl", "models/props_debris/concrete_chunk07a.mdl",
		"models/props_debris/concrete_chunk08a.mdl", "models/props_debris/concrete_chunk09a.mdl"},
	wood = {"models/props_debris/wood_chunk03a.mdl", "models/props_debris/wood_chunk03b.mdl", "models/props_debris/wood_chunk04a.mdl",
		"models/props_debris/wood_chunk06a.mdl", "models/props_debris/wood_splinters01a.mdl"},
	dirt = {"models/props_debris/concrete_chunk02a.mdl", "models/props_debris/concrete_chunk03a.mdl"},
}
local checked = {}
local function DebrisModels(kind)
	local list = DEBRIS[kind] or DEBRIS.concrete
	if not checked[kind] then
		checked[kind] = true
		for i = #list, 1, -1 do
			if not util.IsValidModel(list[i]) then table.remove(list, i) end
		end
	end
	return list
end

local debrisAlive = {}
local max_debris = 60

local function SpawnDebris(pos, normal, kind, power)
	local models = DebrisModels(kind)
	local count = math.floor((3 + power * 7) * cvDebris:GetFloat())
	if #models == 0 or count <= 0 then return end
	for i = 1, count do
		local prop = ents.CreateClientProp(models[math.random(#models)])
		if not IsValid(prop) then continue end
		prop:SetPos(pos + normal * 4 + VectorRand() * 6)
		prop:SetAngles(AngleRand())
		prop:SetModelScale(math.Rand(0.45, 1) * (kind == "dirt" and 0.6 or 1))
		if kind == "dirt" then prop:SetColor(Color(70, 55, 40)) end
		prop:Spawn()
		local phys = prop:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:SetVelocity(normal * math.Rand(150, 420) * (0.5 + power * 0.5) + VectorRand() * 160)
			phys:AddAngleVelocity(VectorRand() * 600)
		end
		debrisAlive[#debrisAlive + 1] = prop
		SafeRemoveEntityDelayed(prop, math.Rand(18, 28))
	end
	for i = #debrisAlive, 1, -1 do
		if not IsValid(debrisAlive[i]) then table.remove(debrisAlive, i) end
	end
	while #debrisAlive > max_debris do
		local old = table.remove(debrisAlive, 1)
		if IsValid(old) then old:Remove() end
	end
end

local portals = {}

-- стена тонкая? тогда отверстие сквозное: запоминаем обе стороны и рисуем пробоину и на обратной стороне
local function TryPortal(tr, size)
	if not tr.HitWorld then return end
	local n = tr.HitNormal
	local back = util.TraceLine({start = tr.HitPos - n * (portal_max_thick + 8), endpos = tr.HitPos - n * 0.5, mask = MASK_SOLID_BRUSHONLY})
	if back.StartSolid or not back.Hit or back.HitSky or back.HitNormal:Dot(-n) < 0.9 then return end
	local thick = (tr.HitPos - back.HitPos):Dot(n)
	if thick <= 0.5 or thick > portal_max_thick then return end
	-- рваный край отверстия: 28 точек с разным радиусом
	local radius = size * portal_hole_k
	local ring = {}
	local seed = math.random(1, 1000)
	for i = 1, 28 do
		local a = (i - 1) / 28 * math.pi * 2
		local k = 0.85 + 0.15 * math.sin(a * 3 + seed) + math.Rand(-0.12, 0.12)
		ring[i] = {math.cos(a) * radius * k, math.sin(a) * radius * k}
	end
	local right = n:Angle():Right()
	local up = n:Angle():Up()
	portals[#portals + 1] = {pos = tr.HitPos, back = back.HitPos, n = n, right = right, up = up, ring = ring, radius = radius}
	while #portals > max_portals do table.remove(portals, 1) end
	-- выходное отверстие с другой стороны
	local list = Mats().wall
	local mat = list and list[math.random(#list)]
	if mat then util.DecalEx(mat, game.GetWorld(), back.HitPos, back.HitNormal, color_white, size * 1.1, size * 1.1) end
end

local function Place(tr, size, kind)
	local list = Mats()[kind]
	local mat = list and list[math.random(#list)]
	if mat then
		util.DecalEx(mat, tr.Entity, tr.HitPos, tr.HitNormal, color_white, size, size)
	else
		-- текстуры не скачались - хотя бы обычная копоть движка
		util.Decal("Scorch", tr.HitPos + tr.HitNormal * 2, tr.HitPos - tr.HitNormal * 2)
	end
end

net.Receive("rem_crater", function()
	local pos, power = net.ReadVector(), net.ReadFloat()
	local reach = 40 + power * 140

	-- ближайшие поверхности карты вокруг взрыва
	local hits = {}
	for _, dir in ipairs(DIRS) do
		local tr = util.TraceLine({start = pos, endpos = pos + dir * reach, mask = MASK_SOLID_BRUSHONLY})
		if tr.Hit and tr.HitWorld and not tr.HitSky and not tr.StartSolid then
			hits[#hits + 1] = {tr = tr, d = tr.Fraction * reach}
		end
	end
	table.sort(hits, function(a, b) return a.d < b.d end)

	local placed = {}
	for _, h in ipairs(hits) do
		if #placed >= 3 then break end
		local tr = h.tr
		local same = false
		for _, p in ipairs(placed) do
			if p.HitNormal:Dot(tr.HitNormal) > 0.9 and p.HitPos:Distance(tr.HitPos) < 80 then same = true break end
		end
		if not same then
			local k = 1 - h.d / reach
			local size = (70 + power * 230) * (0.4 + 0.6 * k) * (#placed > 0 and 0.7 or 1)
			local kind = SOFT[tr.MatType] and "ground" or METAL[tr.MatType] and "metal" or "wall"
			if kind == "metal" then size = size * 0.8 end
			Place(tr, size, kind)
			if kind == "wall" then TryPortal(tr, size) end
			if #placed == 0 and kind ~= "metal" then
				SpawnDebris(tr.HitPos, tr.HitNormal, kind == "ground" and "dirt" or tr.MatType == MAT_WOOD and "wood" or "concrete", power)
			end
			placed[#placed + 1] = tr
		end
	end
end)

------------------------------------------------------------------------------------------
-- Сквозные пробоины: вид за стеной
------------------------------------------------------------------------------------------
local rts, rtMats, rtW, rtH = {}, {}
local rendering = false
local active = {}      -- дыры, для которых в этом кадре готова картинка: {portal, slot, side}
local activeFrame = -1

local function RT(slot)
	local w, h = math.floor(ScrW() * cvPortalRes:GetFloat()), math.floor(ScrH() * cvPortalRes:GetFloat())
	if rtW ~= w or rtH ~= h then rts, rtMats, rtW, rtH = {}, {}, w, h end
	if not rts[slot] then
		local name = "rem_crater_portal" .. slot .. "_" .. w .. "x" .. h
		rts[slot] = GetRenderTargetEx(name, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, 0, 0, IMAGE_FORMAT_RGB888)
		rtMats[slot] = CreateMaterial(name .. "_mat", "UnlitGeneric", {["$basetexture"] = rts[slot]:GetName(), ["$ignorez"] = 1})
	end
	return rts[slot], rtMats[slot]
end

-- какие дыры сейчас стоит рисовать: ближайшие, перед камерой
local function Pick(origin, angles, fov, limit)
	local fwd = angles:Forward()
	local cosView = math.cos(math.rad(math.min((fov or 90) * 0.75 + 10, 89)))
	local list = {}
	for _, p in ipairs(portals) do
		local d = p.pos:Distance(origin)
		if d < portal_max_dist then
			local dir = (p.pos - origin) / math.max(d, 1)
			if dir:Dot(fwd) > cosView or d < p.radius * 3 then
				local side = (origin - p.pos):Dot(p.n) >= 0 and 1 or -1
				-- с обратной стороны смотрим сквозь выходное отверстие
				if side < 0 and (origin - p.back):Dot(p.n) > 0 then side = 0 end
				if side ~= 0 then list[#list + 1] = {p = p, d = d, side = side} end
			end
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	for i = limit + 1, #list do list[i] = nil end
	return list
end

-- зовёт камера Z-City (cl_camera.lua) перед своим кадром; без неё - хук RenderScene ниже
function hg.Craters.RenderPortals(origin, angles, fov)
	if rendering or #portals == 0 then return end
	local limit = cvPortals:GetInt()
	if limit <= 0 then return end
	local list = Pick(origin, angles, fov, limit)
	activeFrame = FrameNumber()
	active = {}
	if #list == 0 then return end
	rendering = true
	for slot, e in ipairs(list) do
		local p = e.p
		local rt = RT(slot)
		-- оставляем только то, что за дальней стороной стены
		local far = e.side > 0 and p.back or p.pos
		local cn = e.side > 0 and -p.n or p.n
		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 255, true, true)
		local oldClip = render.EnableClipping(true)
		render.PushCustomClipPlane(cn, cn:Dot(far) - 0.5)
		render.RenderView({
			origin = origin, angles = angles, fov = fov,
			x = 0, y = 0, w = rtW, h = rtH,
			drawhud = false, drawviewmodel = false, dopostprocess = false, drawmonitors = false,
		})
		render.PopCustomClipPlane()
		render.EnableClipping(oldClip)
		render.PopRenderTarget()
		active[#active + 1] = {p = p, slot = slot, side = e.side}
	end
	rendering = false
end

hook.Add("RenderScene", "rem_crater_portals", function(origin, angles, fov)
	local list = hook.GetTable().RenderScene
	if list and list.jopa then return end -- камера Z-City вызовет сама, со своей камерой
	hg.Craters.RenderPortals(origin, angles, fov)
end)

hook.Add("PostDrawOpaqueRenderables", "rem_crater_portals", function(depth, sky, sky3d)
	if rendering or depth or sky or sky3d or activeFrame ~= FrameNumber() or #active == 0 then return end
	for _, a in ipairs(active) do
		local p = a.p
		local _, mat = RT(a.slot)
		local face = a.side > 0 and p.pos + p.n * 0.4 or p.back - p.n * 0.4
		render.ClearStencil()
		render.SetStencilEnable(true)
		render.SetStencilWriteMask(255)
		render.SetStencilTestMask(255)
		render.SetStencilReferenceValue(1)
		render.SetStencilCompareFunction(STENCIL_ALWAYS)
		render.SetStencilPassOperation(STENCIL_REPLACE)
		render.SetStencilFailOperation(STENCIL_KEEP)
		render.SetStencilZFailOperation(STENCIL_KEEP)
		-- отверстие в трафарет (с проверкой глубины: то, что перед дырой, её закрывает)
		render.OverrideColorWriteEnable(true, false)
		render.SetColorMaterial()
		mesh.Begin(MATERIAL_TRIANGLES, #p.ring)
		for i = 1, #p.ring do
			local a1, a2 = p.ring[i], p.ring[i % #p.ring + 1]
			mesh.Position(face) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
			mesh.Position(face + p.right * a1[1] + p.up * a1[2]) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
			mesh.Position(face + p.right * a2[1] + p.up * a2[2]) mesh.Color(255, 255, 255, 255) mesh.AdvanceVertex()
		end
		mesh.End()
		render.OverrideColorWriteEnable(false)
		-- картинка за стеной - только внутри отверстия
		render.SetStencilCompareFunction(STENCIL_EQUAL)
		render.SetStencilPassOperation(STENCIL_KEEP)
		cam.Start2D()
			surface.SetMaterial(mat)
			surface.SetDrawColor(255, 255, 255, 255)
			surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
		cam.End2D()
		render.SetStencilEnable(false)
	end
end)

hook.Add("PreCleanupMap", "rem_crater_portals", function() portals = {} active = {} end)
