-- Пробоины и воронки от взрывов. Стену карты по-настоящему не пробить (столкновения карты не меняются), поэтому
-- это картинка: на ближайших к взрыву стенах / полу - большая рваная пробоина (чёрная дыра, разбитый край, трещины,
-- копоть), на мягкой земле - воронка, на металле - только копоть; от места взрыва летят обломки.
-- Размер - от силы взрыва (power: граната ~0.5, СВУ ~0.9, РПГ 1). Текстуры - tools/craters/make.py -> materials/rem_crater.
-- Выключить: rem_craters 0 (сервер). Обломки у игрока: rem_craters_debris 0..2 (0 - нет, 1 - как есть, 2 - вдвое больше).
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
			if #placed == 0 and kind ~= "metal" then
				SpawnDebris(tr.HitPos, tr.HitNormal, kind == "ground" and "dirt" or tr.MatType == MAT_WOOD and "wood" or "concrete", power)
			end
			placed[#placed + 1] = tr
		end
	end
end)
