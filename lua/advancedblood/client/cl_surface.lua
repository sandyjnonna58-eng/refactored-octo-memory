-- Surface classification (substrate categories from surfaceprops / MAT_ / texture name) and a
-- sparse wetness grid that remembers where blood recently landed. Wetness changes how new blood
-- behaves: lower adhesion, fewer satellites, accumulation into pools.

ABL.NoJIT()
ABL.Surface = ABL.Surface or {}
local S = ABL.Surface
local C = ABL.Config
local exp, floor = math.exp, math.floor

local byProp, byTex = {}, {}

local texHints = {
	{ "carpet", "fabric" }, { "rug", "fabric" }, { "cloth", "fabric" }, { "fabric", "fabric" },
	{ "grass", "grass" }, { "dirt", "dirt" }, { "mud", "dirt" }, { "sand", "dirt" }, { "snow", "snow" },
	{ "tile", "tile" }, { "metal", "metal" }, { "glass", "glass" }, { "wood", "wood" },
	{ "concrete", "concrete" }, { "brick", "stone" }, { "stone", "stone" }, { "rock", "stone" },
	{ "plaster", "concrete" }, { "floor", "concrete" },
}

local function Resolve(name)
	local s = C.Surfaces[name] or C.Surfaces.default
	s.name = s.name or name
	return s
end
for k, s in pairs(C.Surfaces) do s.name = k end

-- Surface properties for a trace result.
function S.FromTrace(tr)
	local id = tr.SurfaceProps or 0
	local r = byProp[id]
	if r then return r end
	local propName = util.GetSurfacePropName(id) or ""
	local cat = C.SurfaceNames[propName]
	if cat then
		r = Resolve(cat)
		byProp[id] = r
		return r
	end
	local tex = string.lower(tr.HitTexture or "")
	r = byTex[tex]
	if r then return r end
	for _, h in ipairs(texHints) do
		if string.find(tex, h[1], 1, true) then cat = h[2] break end
	end
	cat = cat or C.MatTypes[tr.MatType or 0] or "default"
	r = Resolve(cat)
	byTex[tex] = r
	return r
end

------------------------------------------------------------------------------------------
-- Wetness grid
------------------------------------------------------------------------------------------
local CELL = 4
local cells = {}
local count = 0
S.cells = cells

local function Key(x, y, z) return ABL.CellKey(x, y, z, CELL) end

-- Adds `vol` ml at a point. `tau` = drying time constant in seconds.
function S.WetAdd(x, y, z, vol, tau)
	-- (nowhere, or no amount: nothing is noted. A key that is no number cannot be written.)
	if not (ABL.InWorld(x, y, z) and vol >= 0 and vol < 1e4) then return nil end
	local k = Key(x, y, z)
	local c = cells[k]
	local now = CurTime()
	if not c then
		c = { vol = 0, t = now, tau = tau or 60, n = 0 }
		cells[k] = c
		count = count + 1
	else
		c.vol = c.vol * exp(-(now - c.t) / c.tau)
		c.t = now
		c.tau = math.max(c.tau, tau or 60)
	end
	c.vol = c.vol + vol
	return c
end

function S.WetTake(x, y, z, amount)
	local c = cells[Key(x, y, z)]
	if not c then return end
	local now = CurTime()
	c.vol = math.max(0, c.vol * exp(-(now - c.t) / c.tau) - amount)
	c.t = now
end

function S.WetGet(x, y, z)
	local c = cells[Key(x, y, z)]
	if not c then return 0, nil end
	return c.vol * exp(-(CurTime() - c.t) / c.tau), c
end

-- Decal stacking counter for a cell (prevents hundreds of decals on one spot).
function S.CellDecals(x, y, z)
	local c = cells[Key(x, y, z)]
	return c and c.n or 0
end

function S.CountDecal(x, y, z)
	local c = cells[Key(x, y, z)]
	if not c then c = S.WetAdd(x, y, z, 0, 30) end
	if c then c.n = c.n + 1 end
end

function S.Clear()
	for k in pairs(cells) do cells[k] = nil end
	count = 0
end

timer.Create("ABL_WetGC", 5, 0, function()
	if count < 2500 then return end
	local now = CurTime()
	for k, c in pairs(cells) do
		if now - c.t > c.tau * 4 then cells[k] = nil count = count - 1 end
	end
end)

function S.Count() return count end

-- Surface probes (pool extents, runoff tracking) must see world / props but not characters or the
-- bleeding body itself would stop pools from spreading underneath it.
function S.ProbeFilter(e)
	return not (e:IsPlayer() or e:IsRagdoll() or e:IsNPC() or e:IsWeapon())
end
