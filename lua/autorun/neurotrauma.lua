-- NeuroTrauma: head injury and its neurological consequences for Z-City characters.
-- A module of the AdvancedBlood addon with its own switch (neuro_enabled); it does not need the
-- blood module. Design: docs/NEUROTRAUMA_ARCHITECTURE.md. Sources: docs/NEUROTRAUMA_RESEARCH.md.
-- This is a game simulation, not a medical model: every curve in sh_config.lua names its tier.

NeuroTrauma = NeuroTrauma or {}
local NT = NeuroTrauma
NT.VERSION = "0.4.0"

local ROOT = "neurotrauma/"

-- Client modules call this first thing: the same JIT policy as the blood module (engine-call loops
-- run in the interpreter; see lua/autorun/advancedblood.lua).
function NT.NoJIT()
	if not (CLIENT and jit and jit.off) then return end
	if istable(ABL) and ABL.jitOff == false then return end
	local info = debug.getinfo(2, "f")
	if info and info.func then jit.off(info.func, true) end
end

-- The test harness's marker, as in lua/autorun/advancedblood.lua (ten minutes and it is stale).
function NT.TestMarker()
	local t = file.Time("abl_selftest.txt", "DATA")
	return isnumber(t) and t > 0 and os.time() - t < 600
end
NT.testRun = NT.TestMarker()

function NT.Print(...)
	MsgC(Color(120, 170, 230), "[NeuroTrauma] ", color_white, string.format(...), "\n")
end

local shared = {
	"sh_config.lua",
	"sh_states.lua",
	"sh_anim.lua",
	"sh_atlas.lua",
	"sh_text.lua",
	"sh_move.lua",
	"sh_items.lua",
}

-- Order matters: later modules capture tables created by earlier ones.
local server = {
	"sv_zcity.lua",
	"sv_biomech.lua",
	"sv_injury.lua",
	"sv_states.lua",
	"sv_anatomy.lua",
	"sv_vascular.lua",
	"sv_spine.lua",
	"sv_brain.lua",
	"sv_seizure.lua",
	"sv_cardio.lua",
	"sv_cardioresp.lua",
	"sv_treatment.lua",
	"sv_anim.lua",
	"sv_collapse.lua",
	"sv_motor.lua",
	"sv_face.lua",
	"sv_language.lua",
	"sv_net.lua",
	"sv_trauma.lua",
	"sv_debug.lua",
	"sv_api.lua",
	"sv_braincmd.lua",
	"sv_selftest.lua",
	"sv_selftest2.lua",
	"sv_selftest3.lua",
}

local client = {
	"cl_state.lua",
	"cl_pose.lua",
	"cl_senses.lua",
	"cl_debug.lua",
	"cl_brainview.lua",
	"cl_signal.lua",
	"cl_brainsurf.lua",
	"cl_brainvasc.lua",
	"cl_brain3d.lua",
	"cl_selftest.lua",
	"cl_litprobe.lua",
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

NT.Loaded = true
hook.Run("NT_Loaded")
