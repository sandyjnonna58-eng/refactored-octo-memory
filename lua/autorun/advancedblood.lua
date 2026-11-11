-- AdvancedBlood: physics-informed blood & bleeding for Z-City (Garry's Mod multiplayer).
-- Bootstrap: loads shared, server and client modules in a fixed order.

ABL = ABL or {}
ABL.VERSION = "1.0.0"

-- Lua refresh / addon reload: free every mesh and table from the previous load first.
if CLIENT and ABL.ClearAll then pcall(ABL.ClearAll, true) end

local ROOT = "advancedblood/"

-- JIT policy for the client modules (each calls ABL.NoJIT() first thing). Their hot paths are
-- thousands of engine calls per frame (mesh.*, render.*, traces, bone matrices), which LuaJIT cannot
-- compile: it stitches a trace around every such call instead, and this game build's LuaJIT has
-- been seen to crash natively when a stale stitched trace is entered. Running these modules in the
-- interpreter costs little (the engine calls dominate) and keeps them out of that machinery.
-- data/abl_jit.txt containing "1" keeps the JIT on for them (for comparison).
ABL.jitOff = true
if CLIENT and file.Exists("abl_jit.txt", "DATA") and string.Trim(file.Read("abl_jit.txt", "DATA") or "") == "1" then ABL.jitOff = false end
function ABL.NoJIT()
	if not (CLIENT and ABL.jitOff and jit and jit.off) then return end
	local info = debug.getinfo(2, "f")
	if info and info.func then jit.off(info.func, true) end
end

-- The test harness's marker (data/abl_selftest.txt, tools/harness). The harness removes it when a
-- run ends. One left behind (the harness was stopped from outside) must not start the test plan in
-- a game somebody starts later, so a marker older than ten minutes counts as absent.
function ABL.TestMarker()
	local t = file.Time("abl_selftest.txt", "DATA")
	return isnumber(t) and t > 0 and os.time() - t < 600
end
ABL.testRun = ABL.TestMarker()

local shared = {
	"sh_config.lua",
	"sh_core.lua",
	"sh_net.lua",
	"sh_wound.lua",
	"sh_zcity.lua",
}

-- (тестовые сценарии разработчика - *test*, selftest, hostile - из сборки убраны: в игре они не нужны)
local server = {
	"server/sv_main.lua",
	"server/sv_woundstore.lua",
	"server/sv_compat.lua",
	"server/sv_persist.lua",
	"server/sv_dev.lua",
}

-- Order matters: later modules capture tables created by earlier ones.
local client = {
	"client/cl_profiler.lua",
	"client/cl_trace.lua",
	"client/cl_materials.lua",
	"client/cl_surface.lua",
	"client/cl_render.lua",
	"client/cl_lod.lua",
	"client/cl_bodymesh.lua",
	"client/cl_sources.lua",
	"client/cl_wounds.lua",
	"client/cl_emission.lua",
	"client/cl_flowcore.lua",
	"client/cl_filmchart.lua",
	"client/cl_film.lua",
	"client/cl_filmdraw.lua",
	"client/cl_bodyflow.lua",
	"client/cl_flowdraw.lua",
	"client/cl_woundfx.lua",
	"client/cl_droplets.lua",
	"client/cl_filmpendant.lua",
	"client/cl_stains.lua",
	"client/cl_groundstains.lua",
	"client/cl_impacts.lua",
	"client/cl_poolsim.lua",
	"client/cl_poolatlas.lua",
	"client/cl_poolcanvas.lua",
	"client/cl_pools.lua",
	"client/cl_poolmirror.lua",
	"client/cl_runoff.lua",
	"client/cl_flowworld.lua",
	"client/cl_transfer.lua",
	"client/cl_events.lua",
	"client/cl_compat.lua",
	"client/cl_sim.lua",
	"client/cl_debug.lua",
	"client/cl_accum.lua",
}

for _, f in ipairs(shared) do
	if SERVER then AddCSLuaFile(ROOT .. f) end
	include(ROOT .. f)
end

if SERVER then
	for _, f in ipairs(client) do AddCSLuaFile(ROOT .. f) end
	for _, f in ipairs(server) do include(ROOT .. f) end
else
	for _, f in ipairs(client) do include(ROOT .. f) end
end

ABL.Loaded = true
hook.Run("ABL_Loaded")
