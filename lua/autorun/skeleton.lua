-- Skeleton: the bones of a Z-City character as anatomy and as a three-dimensional model inside it.
-- A module of the AdvancedBlood addon with its own switch (skel_enabled). It does not need the
-- other modules and changes nothing of theirs or of Z-City's: it reads.
--
-- Three things are kept apart (docs/SKELETON_PHASE1_AUDIT.md, docs/SKELETON_PHASE2.md):
--   the registry   what bones and joints a person has (sh_registry.lua): the same for every model;
--   the rig        which of a player model's animation bones carries which of them (sh_rig.lua);
--   the geometry   what is drawn (client/cl_geometry.lua): the game's own skeleton model, read from the
--                  game at run time and taken apart into its bones (sh_stock.lua says how).
-- On top: where a bone is now (sh_pose.lua), what a path through a body meets (sh_proxy.lua), what
-- is known to be wrong with a bone (sv_records.lua), and the developer's view (cl_view.lua).
-- How skull, lower jaw and brain lie in a head is said in one place, sh_headfit.lua, from each
-- model's own numbers (sh_headdata.lua); the view for looking at it and fitting a head by hand is
-- cl_headview.lua (docs/SKULL_BRAIN_ALIGNMENT.md).
-- This is a game's model of a skeleton, not a medical one.

HemoSkeleton = HemoSkeleton or {}
local SK = HemoSkeleton
SK.VERSION = "0.1.0"

local ROOT = "skeleton/"

-- Client files that make many engine calls a frame run in the interpreter (the same policy and the
-- same reason as lua/autorun/advancedblood.lua). The files that only do arithmetic do not call it.
function SK.NoJIT()
	if not (CLIENT and jit and jit.off) then return end
	if istable(ABL) and ABL.jitOff == false then return end
	local info = debug.getinfo(2, "f")
	if info and info.func then jit.off(info.func, true) end
end

-- The test harness's marker (ten minutes and it is stale), as in the other modules.
function SK.TestMarker()
	local t = file.Time("abl_selftest.txt", "DATA")
	return isnumber(t) and t > 0 and os.time() - t < 600
end
SK.testRun = SK.TestMarker()

function SK.Print(...)
	MsgC(Color(215, 205, 170), "[Skeleton] ", color_white, string.format(...), "\n")
end

-- Order matters: later files capture tables made by earlier ones.
local shared = {
	"sh_config.lua",
	"sh_registry.lua",
	"sh_stock.lua",
	"sh_fitdata.lua",
	"sh_headdata.lua",
	"sh_headfit.lua",
	"sh_rig.lua",
	"sh_pose.lua",
	"sh_proxy.lua",
	"sh_brain.lua",
}

local server = {
	"sv_records.lua",
	"sv_zcity.lua",
	"sv_net.lua",
	"sv_dev.lua",
	"sv_selftest.lua",
}

local client = {
	"cl_records.lua",
	"cl_geometry.lua",
	"cl_draw.lua",
	"cl_view.lua",
	"cl_headview.lua",
	"cl_selftest.lua",
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

SK.Loaded = true
hook.Run("SK_Loaded")
