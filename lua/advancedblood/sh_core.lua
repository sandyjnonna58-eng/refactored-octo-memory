-- Core utilities shared by every module: object pools, list helpers, seeded RNG, gravity access,
-- spatial hashing and small math helpers. Hot paths elsewhere avoid Vector allocations and use
-- plain numbers; these helpers follow the same rule.

local C = ABL.Config
local floor, sqrt, exp, log, cos, sin, pi = math.floor, math.sqrt, math.exp, math.log, math.cos, math.sin, math.pi

ABL.Stats = ABL.Stats or {}

function ABL.Print(...)
	MsgC(Color(210, 40, 40), "[AdvancedBlood] ", color_white, string.format(...), "\n")
end

function ABL.Enabled()
	if not C.sv.enabled:GetBool() then return false end
	if CLIENT then return C.cl.enabled:GetBool() end
	return true
end

------------------------------------------------------------------------------------------
-- Object pool: reuse tables instead of allocating per droplet / blob / pool record.
------------------------------------------------------------------------------------------
local Pool = {}
Pool.__index = Pool

function ABL.NewPool(ctor)
	return setmetatable({ free = {}, n = 0, ctor = ctor, made = 0 }, Pool)
end

function Pool:Get()
	local n = self.n
	if n > 0 then
		local o = self.free[n]
		self.free[n] = nil
		self.n = n - 1
		return o
	end
	self.made = self.made + 1
	return self.ctor()
end

function Pool:Put(o)
	local n = self.n + 1
	self.free[n] = o
	self.n = n
end

-- O(1) unordered removal
function ABL.SwapRemove(list, i)
	local n = #list
	list[i] = list[n]
	list[n] = nil
end

------------------------------------------------------------------------------------------
-- Seeded RNG (Park-Miller). Deterministic per wound so every client gets similar patterns.
------------------------------------------------------------------------------------------
local RNG = {}
RNG.__index = RNG

function ABL.RNG(seed)
	seed = floor(math.abs(seed or 1)) % 2147483646 + 1
	return setmetatable({ s = seed }, RNG)
end

function RNG:Next()
	local s = (self.s * 16807) % 2147483647
	self.s = s
	return s / 2147483647
end

function RNG:Range(a, b) return a + (b - a) * self:Next() end

function RNG:Normal()
	local u1 = self:Next()
	if u1 < 1e-7 then u1 = 1e-7 end
	return sqrt(-2 * log(u1)) * cos(2 * pi * self:Next())
end

function ABL.Hash(str)
	return tonumber(util.CRC(str)) or 1
end

------------------------------------------------------------------------------------------
-- World gravity vector. The server publishes physenv.GetGravity() as a Global2 var so that
-- clients use the true vector even if a map/addon rotates or scales gravity.
------------------------------------------------------------------------------------------
local gx, gy, gz, gmag = 0, 0, -C.DEFAULT_GRAVITY, C.DEFAULT_GRAVITY

function ABL.RefreshGravity()
	local g = GetGlobal2Vector("abl_grav", vector_origin)
	if g.x == 0 and g.y == 0 and g.z == 0 then
		local cv = GetConVar("sv_gravity")
		g = Vector(0, 0, -(cv and cv:GetFloat() or C.DEFAULT_GRAVITY))
	end
	gx, gy, gz = g.x, g.y, g.z
	gmag = sqrt(gx * gx + gy * gy + gz * gz)
	if gmag < 1e-3 then gmag = 1e-3 end
end

function ABL.Gravity() return gx, gy, gz, gmag end

timer.Create("ABL_RefreshGravity", 0.5, 0, ABL.RefreshGravity)
ABL.RefreshGravity()

------------------------------------------------------------------------------------------
-- Spatial hashing (exact, collision free for |coord / size| < 32768)
------------------------------------------------------------------------------------------
function ABL.CellKey(x, y, z, s)
	return ((floor(x / s) + 32768) * 65536 + (floor(y / s) + 32768)) * 65536 + (floor(z / s) + 32768)
end

------------------------------------------------------------------------------------------
-- Math helpers (numbers only)
------------------------------------------------------------------------------------------
-- (a vector with no length, or one that is no vector at all, has no direction: zero)
function ABL.Norm(x, y, z)
	local l = sqrt(x * x + y * y + z * z)
	if not (l >= 1e-9 and l < 1e30) then return 0, 0, 0, 0 end
	return x / l, y / l, z / l, l
end

-- Values are checked where they enter a part of the simulation (a drop is made, blood is fed to a
-- surface, a pool takes a deposit): a volume that is no volume or a place that is nowhere is turned
-- away there, so that nothing behind the door has to test for it. (A comparison with NaN is false.)
local WORLD, FAST = 65000, 1e5
-- a point of the map
function ABL.InWorld(x, y, z)
	return x > -WORLD and x < WORLD and y > -WORLD and y < WORLD and z > -WORLD and z < WORLD
end
-- a velocity, a direction, any three numbers of ordinary size
function ABL.Finite3(x, y, z)
	return x > -FAST and x < FAST and y > -FAST and y < FAST and z > -FAST and z < FAST
end
-- a volume of blood (ml)
function ABL.GoodVol(v)
	return v > 0 and v < 1e4
end

function ABL.Clamp(v, a, b)
	if v < a then return a end
	if v > b then return b end
	return v
end

-- Any unit vector perpendicular to n
function ABL.Perp(nx, ny, nz)
	if math.abs(nz) < 0.9 then
		-- n x up
		return ABL.Norm(ny, -nx, 0)
	end
	return ABL.Norm(0, nz, -ny)
end

-- Exponential smoothing factor for time step dt and time constant tau
function ABL.Smooth(dt, tau)
	return 1 - exp(-dt / tau)
end

-- Terminal velocity (u/s) of a blood drop of given volume (ml): Gunn-Kinzer style fit.
function ABL.TerminalVelocity(volMl)
	local dmm = (6 * volMl * 1000 / pi) ^ (1 / 3)
	local vt = 9.43 * (1 - exp(-((dmm / 1.77) ^ 1.147)))
	if vt < 0.4 then vt = 0.4 end
	return vt / 0.0254
end

-- Physical drop diameter (mm) of a volume in ml.
function ABL.DropDiameterMM(volMl)
	return (6 * volMl * 1000 / pi) ^ (1 / 3)
end
