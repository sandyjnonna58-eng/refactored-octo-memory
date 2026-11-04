-- Простые модели из кода (бутылки, пачки, сигареты): свет запекается в цвет вершин, общая яркость - по свету на карте.
-- Сетка строится с материалом, которым рисуется (Mesh(mat)): иначе формат вершин без цвета и игра падает.
-- Оси модели: начало - центр дна, z - вверх.
hg = hg or {}
hg.RemMesh = hg.RemMesh or {}
local RM = hg.RemMesh

RM.SolidMat = RM.SolidMat or CreateMaterial("rem_mesh_solid", "UnlitGeneric", {["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1})
RM.GlassMat = RM.GlassMat or CreateMaterial("rem_mesh_glass", "UnlitGeneric", {["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$translucent"] = 1, ["$nocull"] = 1})

local LIGHT = Vector(0.45, -0.35, 0.82):GetNormalized()

local B = {}
B.__index = B

function RM.Builder()
	return setmetatable({verts = {}}, B)
end

function B:Quad(a, b, c, d, col, n)
	local off = self.offset
	if off then a, b, c, d = a + off, b + off, c + off, d + off end
	local k = 0.45 + 0.55 * math.max(0, n:Dot(LIGHT))
	local vc = Color(math.min(255, col.r * k), math.min(255, col.g * k), math.min(255, col.b * k), col.a)
	local v = self.verts
	for _, p in ipairs({a, b, c, a, c, d}) do
		v[#v + 1] = {pos = p, normal = n, color = vc, u = 0, v = 0}
	end
end

-- тело вращения: profile = {{z, r}, ...} снизу вверх; a0..a1 - дуга в градусах (по умолчанию круг);
-- opts.offset - сдвиг оси вращения (Vector)
function B:Lathe(profile, col, opts)
	opts = opts or {}
	local prevOff = self.offset
	if opts.offset then self.offset = (prevOff or Vector()) + opts.offset end
	local a0, a1, seg = opts.a0 or 0, opts.a1 or 360, opts.seg or 24
	for i = 1, #profile - 1 do
		local z0, r0, z1, r1 = profile[i][1], profile[i][2], profile[i + 1][1], profile[i + 1][2]
		local slope = (r0 - r1) / math.max(z1 - z0, 0.001)
		for s = 0, seg - 1 do
			local u0, u1 = math.rad(a0 + (a1 - a0) * s / seg), math.rad(a0 + (a1 - a0) * (s + 1) / seg)
			local c0, s0, c1, s1 = math.cos(u0), math.sin(u0), math.cos(u1), math.sin(u1)
			local um = (u0 + u1) / 2
			local n = Vector(math.cos(um), math.sin(um), slope):GetNormalized()
			self:Quad(Vector(r0 * c0, r0 * s0, z0), Vector(r0 * c1, r0 * s1, z0), Vector(r1 * c1, r1 * s1, z1), Vector(r1 * c0, r1 * s0, z1), col, n)
		end
	end
	if opts.top then self:Disc(profile[#profile][1], profile[#profile][2], opts.top, 1, a0, a1, seg) end
	if opts.bottom then self:Disc(profile[1][1], profile[1][2], opts.bottom, -1, a0, a1, seg) end
	self.offset = prevOff
end

function B:Disc(z, r, col, dir, a0, a1, seg)
	a0, a1, seg = a0 or 0, a1 or 360, seg or 24
	for s = 0, seg - 1 do
		local u0, u1 = math.rad(a0 + (a1 - a0) * s / seg), math.rad(a0 + (a1 - a0) * (s + 1) / seg)
		local p0, p1 = Vector(r * math.cos(u0), r * math.sin(u0), z), Vector(r * math.cos(u1), r * math.sin(u1), z)
		local c = Vector(0, 0, z)
		if dir > 0 then self:Quad(c, p0, p1, c, col, Vector(0, 0, 1)) else self:Quad(c, p1, p0, c, col, Vector(0, 0, -1)) end
	end
end

function B:Cylinder(z0, z1, r, col, opts)
	self:Lathe({{z0, r}, {z1, r}}, col, opts)
end

-- коробка по углам (min, max); faces - какие грани рисовать (по умолчанию все)
function B:Box(mn, mx, col, skip)
	skip = skip or {}
	local x0, y0, z0, x1, y1, z1 = mn.x, mn.y, mn.z, mx.x, mx.y, mx.z
	local P = function(x, y, z) return Vector(x, y, z) end
	if not skip.top then self:Quad(P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1), col, Vector(0, 0, 1)) end
	if not skip.bottom then self:Quad(P(x0, y1, z0), P(x1, y1, z0), P(x1, y0, z0), P(x0, y0, z0), col, Vector(0, 0, -1)) end
	if not skip.front then self:Quad(P(x0, y0, z0), P(x1, y0, z0), P(x1, y0, z1), P(x0, y0, z1), col, Vector(0, -1, 0)) end
	if not skip.back then self:Quad(P(x1, y1, z0), P(x0, y1, z0), P(x0, y1, z1), P(x1, y1, z1), col, Vector(0, 1, 0)) end
	if not skip.left then self:Quad(P(x0, y1, z0), P(x0, y0, z0), P(x0, y0, z1), P(x0, y1, z1), col, Vector(-1, 0, 0)) end
	if not skip.right then self:Quad(P(x1, y0, z0), P(x1, y1, z0), P(x1, y1, z1), P(x1, y0, z1), col, Vector(1, 0, 0)) end
end

function B:Finish(mat)
	if #self.verts == 0 then return nil end
	local m = Mesh(mat)
	m:BuildFromTriangles(self.verts)
	self.verts = {}
	return m
end

-- собирает модель один раз: build(builder) -> {solid = Mesh, glass = Mesh, ...}; ошибка - модель не рисуется
local cache = {}
function RM.Get(name, build)
	local c = cache[name]
	if c == false then return nil end
	if c then return c end
	local ok, res = pcall(build)
	if not ok or not istable(res) then
		cache[name] = false
		ErrorNoHalt("[remmesh] " .. name .. " build failed: " .. tostring(res) .. "\n")
		return nil
	end
	cache[name] = res
	return res
end

-- рисует части модели в pos/ang; parts = {{mesh, mat, scaleZ}, ...} по порядку (сначала непрозрачное)
function RM.Draw(parts, pos, ang, scale)
	local lc = render.GetLightColor(pos)
	local k = math.Clamp(0.3 + (lc.x + lc.y + lc.z) / 3 * 2.5, 0.3, 1.15)
	render.SetColorModulation(k, k, k)
	for _, part in ipairs(parts) do
		local mesh = part[1]
		if mesh then
			local m = Matrix()
			m:Translate(pos)
			m:Rotate(ang)
			if scale then m:Scale(Vector(scale, scale, scale)) end
			if part[3] then m:Scale(Vector(1, 1, part[3])) end
			if part[4] then m:Translate(part[4]) end
			cam.PushModelMatrix(m)
				render.SetMaterial(part[2] or RM.SolidMat)
				mesh:Draw()
			cam.PopModelMatrix()
		end
	end
	render.SetColorModulation(1, 1, 1)
end
