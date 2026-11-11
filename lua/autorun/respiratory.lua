-- Respiratory: the lungs of a Z-City character as a breathing state on the server and as a
-- three-dimensional, breathing model inside the chest.
-- A module of the AdvancedBlood addon with its own switch (resp_enabled). It needs the skeleton
-- module (lua/skeleton: where the chest is on a body) and reads Z-City and, when it is there, the
-- brain module; it changes nothing of theirs.
--
-- Things kept apart (docs/LUNGS_PHASE1_AUDIT.md, docs/LUNGS_PHASE2.md):
--   the state     what is true of a character's breathing, on the server (sv_zcity.lua, sv_clock.lua,
--                 sv_state.lua): Z-City's lung fields under plain names, and the breathing clock;
--   the link      how that state becomes the few numbers a picture is made from (sh_link.lua);
--   the rig       what those numbers do to each bone of the models (cl_rig.lua, generated cl_rigdata.lua);
--   the models    what is drawn (models/hemogen/lung_r, lung_l, airways, diaphragm .mdl, made by
--                 tools/offline/lunggen.ps1).
-- This is a game's model of breathing, not a medical one.

HemoRespiratory = HemoRespiratory or {}
local RS = HemoRespiratory
RS.VERSION = "0.2.0"

local ROOT = "respiratory/"

-- Client files that make many engine calls a frame run in the interpreter (the same policy and the
-- same reason as lua/autorun/advancedblood.lua).
function RS.NoJIT()
	if not (CLIENT and jit and jit.off) then return end
	if istable(ABL) and ABL.jitOff == false then return end
	local info = debug.getinfo(2, "f")
	if info and info.func then jit.off(info.func, true) end
end

-- The test harness's marker (ten minutes and it is stale), as in the other modules; and what it
-- asks for. In a harness run that asks for no scene of this module, the module keeps out of the
-- way of whoever runs it: nothing of it acts on a body (RS.Quiet).
function RS.TestMarker()
	local t = file.Time("abl_selftest.txt", "DATA")
	return isnumber(t) and t > 0 and os.time() - t < 600
end
RS.testRun = RS.TestMarker()
RS.testPlan = RS.testRun and (file.Read("abl_selftest.txt", "DATA") or "") or ""
RS.Quiet = RS.testRun and not string.find(RS.testPlan, "resp_", 1, true)

function RS.Print(...)
	MsgC(Color(225, 150, 160), "[Respiratory] ", color_white, string.format(...), "\n")
end

-- Order matters: later files capture tables made by earlier ones.
local shared = {
	"sh_config.lua",
	"sh_structures.lua",
	"sh_clock.lua",
	"sh_link.lua",
}

local server = {
	"sv_zcity.lua",
	"sv_bridge.lua",
	"sv_clock.lua",
	"sv_state.lua",
	"sv_net.lua",
	"sv_dev.lua",
	"sv_selftest.lua",
}

local client = {
	"cl_rigdata.lua",
	"cl_net.lua",
	"cl_chest.lua",
	"cl_rig.lua",
	"cl_draw.lua",
	"cl_view.lua",
	"cl_selftest.lua",
}

if SERVER then
	for _, f in ipairs(shared) do AddCSLuaFile(ROOT .. f) end
	for _, f in ipairs(client) do AddCSLuaFile(ROOT .. f) end
end

-- The skeleton module's loader runs after this one (file names in order): its data is waited for.
local function Load()
	if RS.Loaded then return end
	if not (istable(HemoSkeleton) and HemoSkeleton.Loaded) then return end
	for _, f in ipairs(shared) do include(ROOT .. f) end
	if SERVER then
		for _, f in ipairs(server) do include(ROOT .. f) end
	else
		for _, f in ipairs(client) do include(ROOT .. f) end
	end
	RS.Loaded = true
	hook.Run("RS_Loaded")
end

if istable(HemoSkeleton) and HemoSkeleton.Loaded then Load() else hook.Add("SK_Loaded", "RS_Load", Load) end

hook.Add("InitPostEntity", "RS_LoadCheck", function()
	if not RS.Loaded then RS.Print("not loaded: the skeleton module (lua/skeleton) is not there") end
end)
