-- Фон главного меню: город в закатной дымке (materials/rem_menu/menu_bg.jpg) с живым дымом, как в меню Dying Light.
-- 1) там, где на картинке дым (карта в cl_menu_smoke_data.lua), фон рисуется сеткой и текстура медленно колышется;
-- 2) поверх рождаются полупрозрачные клубы: ползут вправо и чуть вверх, разбухают, поворачиваются и тают.
hg.MenuSmoke = hg.MenuSmoke or {}
local MS = hg.MenuSmoke

local bgMat = Material("rem_menu/menu_bg.jpg", "smooth")
local puffMats = {}
for i = 1, 4 do
	puffMats[i] = Material("rem_menu/smoke_puff" .. i .. ".png", "smooth")
end

-- колыхание дыма на фоне
local WARP_U = 0.0065 -- сила по горизонтали (доля ширины картинки)
local WARP_V = 0.0035
local WARP_SPEED = 1

-- клубы поверх фона (размеры и скорости - для 1920x1080, дальше масштабируются)
local PUFF_COUNT = 44
local PUFF_LIFE = {16, 30}
local PUFF_SIZE = {170, 400}
local PUFF_GROW = 1.6
local PUFF_DRIFT_X = {7, 18}
local PUFF_DRIFT_Y = {-6, -1}
local PUFF_ALPHA = {0.10, 0.24}
local PUFF_SPIN = 2.5 -- градусов в секунду

-- запас по краям под сдвиг от мыши
local OVERSCAN = 1.04

local puffs = {}
local verts = {{}, {}, {}, {}}

local function rand(r) return math.Rand(r[1], r[2]) end

local function NewPuff(p, age)
	local spawn = MS.Spawn
	local pt = spawn and spawn[math.random(#spawn)] or {math.Rand(0, 1), math.Rand(0.3, 0.7)}
	p.x = pt[1] * 1920 + math.Rand(-40, 40)
	p.y = pt[2] * 1080 + math.Rand(-25, 25)
	p.life = rand(PUFF_LIFE)
	p.age = age or 0
	p.size = rand(PUFF_SIZE)
	p.vx = rand(PUFF_DRIFT_X)
	p.vy = rand(PUFF_DRIFT_Y)
	p.alpha = rand(PUFF_ALPHA)
	p.rot = math.Rand(0, 360)
	p.spin = math.Rand(-PUFF_SPIN, PUFF_SPIN)
	p.mat = puffMats[math.random(#puffMats)]
	-- цвет - как у дыма на картинке в этом месте, чуть светлее или темнее
	local shade = math.Rand(0.9, 1.15)
	local L = MS.Light or Color(226, 158, 84)
	p.r = math.min((pt[3] or L.r) * shade, 255)
	p.g = math.min((pt[4] or L.g) * shade, 255)
	p.b = math.min((pt[5] or L.b) * shade, 255)
	return p
end

function MS.Reset()
	puffs = {}
	for i = 1, PUFF_COUNT do
		-- сразу заполняем экран клубами разного возраста, чтобы дым не "включался"
		local p = NewPuff({})
		p.age = math.Rand(0, p.life)
		puffs[i] = p
	end
	MS.LastTime = RealTime()
end

local function DrawWarpedBackground(x0, y0, w, h, alpha)
	surface.SetMaterial(bgMat)
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.DrawTexturedRect(x0, y0, w, h)

	local grid, GX, GY = MS.Grid, MS.GX, MS.GY
	if not grid then return end

	local t = RealTime() * WARP_SPEED
	local cw, ch = w / GX, h / GY

	-- смещение текстуры в вершине (i, j); на краях маски = 0, так что швов с обычным фоном нет
	local function uv(i, j)
		local m = grid[j + 1][i + 1]
		local u, v = i / GX, j / GY
		if m <= 0 then return u, v end
		local du = (math.sin(t * 0.13 + j * 0.35 + i * 0.21) + 0.6 * math.sin(t * 0.071 + i * 0.5 - j * 0.23)) * WARP_U * m
		local dv = (math.cos(t * 0.11 + i * 0.31 + j * 0.17) + 0.5 * math.sin(t * 0.083 - i * 0.27)) * WARP_V * m
		return u + du, v + dv
	end

	for j = 0, GY - 1 do
		local row, nextRow = grid[j + 1], grid[j + 2]
		for i = 0, GX - 1 do
			if row[i + 1] > 0 or row[i + 2] > 0 or nextRow[i + 1] > 0 or nextRow[i + 2] > 0 then
				local px, py = x0 + i * cw, y0 + j * ch
				local a, b, c, d = verts[1], verts[2], verts[3], verts[4]
				a.x, a.y = px, py
				a.u, a.v = uv(i, j)
				b.x, b.y = px + cw, py
				b.u, b.v = uv(i + 1, j)
				c.x, c.y = px + cw, py + ch
				c.u, c.v = uv(i + 1, j + 1)
				d.x, d.y = px, py + ch
				d.u, d.v = uv(i, j + 1)
				surface.DrawPoly(verts)
			end
		end
	end
end

local function DrawPuffs(x0, y0, w, h, alpha)
	local now = RealTime()
	local dt = math.Clamp(now - (MS.LastTime or now), 0, 0.1)
	MS.LastTime = now

	local sx, sy = w / 1920, h / 1080
	local alphaMul = alpha / 255

	for i = 1, #puffs do
		local p = puffs[i]
		p.age = p.age + dt
		if p.age >= p.life then
			NewPuff(p, 0)
		end
		p.x = p.x + p.vx * dt
		p.y = p.y + p.vy * dt
		p.rot = p.rot + p.spin * dt

		local k = p.age / p.life
		local fade = math.sin(k * math.pi) -- плавно появляется и тает
		local size = p.size * (1 + (PUFF_GROW - 1) * k)

		surface.SetMaterial(p.mat)
		surface.SetDrawColor(p.r, p.g, p.b, 255 * p.alpha * fade * alphaMul)
		surface.DrawTexturedRectRotated(x0 + p.x * sx, y0 + p.y * sy, size * sx, size * sy, p.rot)
	end
end

-- рисует фон с дымом на весь экран; offsetX/offsetY - сдвиг от мыши (параллакс), alpha - общая прозрачность
function MS.Draw(w, h, offsetX, offsetY, alpha)
	if #puffs == 0 then MS.Reset() end

	local bw, bh = w * OVERSCAN, h * OVERSCAN
	local x0 = (w - bw) * 0.5 - (offsetX or 0)
	local y0 = (h - bh) * 0.5 - (offsetY or 0)

	DrawWarpedBackground(x0, y0, bw, bh, alpha or 255)
	DrawPuffs(x0, y0, bw, bh, alpha or 255)
end
