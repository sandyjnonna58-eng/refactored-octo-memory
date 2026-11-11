-- Configuration: convars, bleeding profiles, surface categories, LOD tiers, physical constants.
-- Units: 1 game unit = 1 inch (2.54 cm). Blood volume is tracked in millilitres (ml).

local C = {}
ABL.Config = C

------------------------------------------------------------------------------------------
-- Convars
------------------------------------------------------------------------------------------
local SVFLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED)

C.sv = {
	enabled      = CreateConVar("abl_enabled", "1", SVFLAGS, "AdvancedBlood master switch (server authoritative).", 0, 1),
	volume       = CreateConVar("abl_volume_scale", "1", SVFLAGS, "Visual blood volume multiplier (1 = matches Z-City bleed rates).", 0.1, 4),
	drying       = CreateConVar("abl_drying_scale", "1", SVFLAGS, "Drying time multiplier (2 = blood stays wet twice as long).", 0.1, 10),
	envTemp      = CreateConVar("abl_env_temperature", "20", SVFLAGS, "Air temperature in C for the drying and setting of ground pools (20 = neutral; warmer dries and sets faster).", -20, 50),
	envHumid     = CreateConVar("abl_env_humidity", "50", SVFLAGS, "Relative humidity in % for the drying of ground pools (50 = neutral; damp air dries slower).", 0, 100),
	netHits      = CreateConVar("abl_net_hits", "1", SVFLAGS, "Send compact wound-impact events to clients.", 0, 1),
	netCollide   = CreateConVar("abl_net_collisions", "1", SVFLAGS, "Send bloody ragdoll collision events to clients.", 0, 1),
	netReplay    = CreateConVar("abl_net_wound_replay", "1", SVFLAGS, "Keep the wounds a character carries on the server and tell them to clients that were not there when they were made (a player who comes into sight of a wounded body later, or joins the game).", 0, 1),
	persist      = CreateConVar("abl_persist", "1", SVFLAGS, "Track coarse pools on the server so late joiners see existing blood.", 0, 1),
	hitDecals    = CreateConVar("abl_zcity_hitdecals", "0", SVFLAGS, "Z-City's server-made blood decals and blood puffs (behind every bullet hit, at cuts and claws, where the meat of a burst head lands): keep them (1) or leave all blood to AdvancedBlood (0).", 0, 1),
	dev          = CreateConVar("abl_dev", "0", SVFLAGS, "Enable admin developer commands (abl_dev_*).", 0, 1),
}

if CLIENT then
	C.cl = {
		enabled     = CreateClientConVar("abl_cl_enabled", "1", true, false, "Client-side AdvancedBlood simulation/rendering.", 0, 1),
		quality     = CreateClientConVar("abl_quality", "2", true, false, "0 = low, 1 = medium, 2 = high, 3 = ultra, 4 = extreme.", 0, 4),
		wound3d     = CreateClientConVar("abl_wound_3d", "1", true, false, "1 = a wound has a recess behind its opening (real depth, seen through the opening); 0 = the painted opening alone.", 0, 1),
		woundMarks  = CreateClientConVar("abl_wound_marks", "1", true, false, "1 = wounds are drawn on bodies (openings, bruises, the blood round them); 0 = none are drawn (they are kept, and are there again with 1).", 0, 1),
		woundMax    = CreateClientConVar("abl_wound_max", "14", true, false, "Wound marks kept for one character at the most; the oldest go first.", 2, 40),
		woundLife   = CreateClientConVar("abl_wound_life", "0", true, false, "Seconds a wound mark is kept on a body; then it fades and goes. 0 = as long as the body is there.", 0, 3600),
		woundDist   = CreateClientConVar("abl_wound_dist", "1100", true, false, "Units: further away than this a character's wounds are not drawn.", 100, 4000),
		wound3dDist = CreateClientConVar("abl_wound_3d_dist", "520", true, false, "Units: further away than this a wound is its painted opening alone (no recess).", 50, 2000),
		woundForm   = CreateClientConVar("abl_wound_form", "1", true, false, "1 = a wound is one piece of lit geometry on the body: a raised rim, a lip that turns in, and the inside behind it; 0 = the recess as it was before (no rim, not lit).", 0, 1),
		woundIntensity = CreateClientConVar("abl_wound_intensity", "1", true, false, "How strongly bruises and the blood round a wound are drawn (0.4 faint .. 1.6 strong).", 0.4, 1.6),
		woundDebug  = CreateClientConVar("abl_wound_debug", "0", false, false, "1 = each wound says where it was put when it is made, and its place and the skin's normal are drawn.", 0, 1),
		budget      = CreateClientConVar("abl_budget_ms", "1.5", true, false, "Target CPU milliseconds per frame for the blood simulation.", 0.3, 20),
		simHz       = CreateClientConVar("abl_sim_hz", "100", true, false, "Target update rate (Hz) of high-priority blood (near, visible); lowered automatically when over abl_budget_ms.", 30, 240),
		maxDrops    = CreateClientConVar("abl_max_droplets", "300", true, false, "Hard cap: simulated droplets.", 16, 4000),
		maxBlobs    = CreateClientConVar("abl_max_blobs", "120", true, false, "Hard cap: body-surface blobs.", 8, 1000),
		maxSegs     = CreateClientConVar("abl_max_body_segments", "1600", true, false, "Hard cap: body-surface streak segments (all characters).", 64, 20000),
		maxPools    = CreateClientConVar("abl_max_pools", "40", true, false, "Hard cap: pools of all characters together (over it the least important one becomes a flat stain).", 4, 400),
		poolsPerBody = CreateClientConVar("abl_max_pools_per_body", "5", true, false, "Hard cap: pools kept for one bleeding character. Over it the least important of its own becomes a flat stain, never another character's (0 = no limit of its own).", 0, 64),
		poolMaxSize = CreateClientConVar("abl_pool_max_size", "48", true, false, "Units: a pool grows no wider than about this; blood that reaches it after that is taken up by the floor (0 = no limit).", 0, 220),
		poolMinSize = CreateClientConVar("abl_pool_min_size", "0", true, false, "Units: drops form a pool only once they bring enough blood for one this wide (2 ml at the least, whatever this says).", 0, 12),
		bodyCatch   = CreateClientConVar("abl_body_catch", "1", true, false, "Blood that lands on another character runs down that body (1) or only leaves a spot there (0).", 0, 1),
		maxRunoff   = CreateClientConVar("abl_max_runoff", "72", true, false, "Hard cap: world runoff rivulets.", 4, 600),
		maxOverlays = CreateClientConVar("abl_max_overlays", "300", true, false, "Hard cap: wet-stain overlays.", 16, 4000),
		maxParts    = CreateClientConVar("abl_max_particles", "260", true, false, "Hard cap: cheap GMod particles.", 0, 3000),
		maxTraces   = CreateClientConVar("abl_max_traces", "100", true, false, "Hard cap: collision traces per frame.", 10, 2000),
		maxGround   = CreateClientConVar("abl_max_ground_stains", "320", true, false, "Hard cap: blood stains from droplets landing on the ground (oldest removed first).", 16, 4000),
		maxGroundBody = CreateClientConVar("abl_max_ground_stains_per_body", "200", true, false, "Hard cap: ground and wall stains kept of one character's blood. Over it that character's own oldest go first, never another's (so one body bleeding hard does not wipe out everybody else's stains).", 8, 4000),
		maxBodyDecals = CreateClientConVar("abl_max_body_decals", "12", true, false, "Hard cap: blood decals kept on one character's model (the spots of drops, soaked cloth round a wound); the oldest go first. 0 = none are placed.", 0, 40),
		decalRate   = CreateClientConVar("abl_decals_per_sec", "60", true, false, "Hard cap: engine decals placed per second.", 1, 1000),
		drawDist    = CreateClientConVar("abl_draw_distance", "2800", true, false, "Blood effects beyond this distance are skipped.", 256, 20000),
		sounds      = CreateClientConVar("abl_sounds", "1", true, false, "Drip / splash sounds.", 0, 1),
		takeover    = CreateClientConVar("abl_zcity_takeover", "1", true, false, "In Z-City: AdvancedBlood is the only blood on screen (1), or Z-City's own blood particles and decals run next to it (0). Z-City's physiology runs either way.", 0, 1),
		fleshDecals = CreateClientConVar("abl_engine_hit_decals", "0", true, false, "The engine's own red splat decal on a body at every bullet hit: keep it (1), or clear it and show AdvancedBlood's wound alone (0).", 0, 1),
		stainScale  = CreateClientConVar("abl_stain_scale", "1", true, false, "Stain size multiplier.", 0.25, 4),
		dropScale   = CreateClientConVar("abl_drop_size", "1", true, false, "Size of airborne drops relative to their true size (1: a drop of 0.05 ml is 4.6 mm across).", 0.5, 3),
		debug       = CreateClientConVar("abl_debug", "0", false, false, "Debug overlay bitmask (see abl_debug_help).", 0, 65535),
		debugHud    = CreateClientConVar("abl_debug_hud", "0", false, false, "Show the statistics HUD.", 0, 1),
		v19         = CreateClientConVar("abl_liquid_v19", "1", true, false, "Blood drawn as the smooth wet liquid of phase 19 (1: smoother outlines and highlights, a surface that follows the liquid's depth, pendant drops, pools lit like the bodies; each part can be turned off in C.V19), or as it was before (0).", 0, 1),
		p24         = CreateClientConVar("abl_liquid_p24", "0", false, false, "Blood on bodies as phase 24 has it (1: liquid that moves, gathers and soaks by the state of the whole surface and how much has come, cloth that takes it from the wound outward, drawn as a filter over the lit body with the liquid's own light and beads; each part can be turned off in C.P24), or as phase 23 left it (0). Needs abl_liquid_v19 1.", 0, 1),
		p21         = CreateClientConVar("abl_pool_p21", "1", true, false, "Ground pools as phase 21 has them (1: a pool begins where its drops landed and their stains give their liquid to it, blood that lands near a pool joins its liquid where it landed, the wet surface mirrors what stands over it; each part can be turned off in C.P21), or as they were before (0).", 0, 1),
		p22         = CreateClientConVar("abl_pool_p22", "1", true, false, "Ground pools as phase 22 has them (1: the floor under a pool is as uneven as its surface, so the liquid stands deeper and darker in its hollows and its edge goes round its rises; each part can be turned off in C.P22), or as phase 21 left them (0).", 0, 1),
		p23         = CreateClientConVar("abl_pool_p23", "1", true, false, "Ground pools as phase 23 draws them (1: an outline smooth at any angle, the meniscus's light restrained; each part can be turned off in C.P23), or as phase 22 left them (0).", 0, 1),
	}

	-- remorseism: настройки по умолчанию снижены ради FPS (качество 2 - без отражений в лужах, бюджет 1.5 мс, 100 Гц,
	-- меньше капель/луж/следов). GMod запоминает настройки у игрока, поэтому у тех, кто уже запускал аддон со старыми
	-- (ultra), новые ставятся один раз (метка data/abl_perf_v1.txt); дальше игрок может менять их как хочет.
	if not file.Exists("abl_perf_v1.txt", "DATA") then
		local perf = {
			abl_quality = 2, abl_budget_ms = 1.5, abl_sim_hz = 100, abl_max_droplets = 300, abl_max_body_segments = 1600,
			abl_max_pools = 40, abl_max_overlays = 300, abl_max_traces = 100, abl_draw_distance = 2800,
		}
		for name, value in pairs(perf) do RunConsoleCommand(name, tostring(value)) end
		file.Write("abl_perf_v1.txt", "1")
	end
end

------------------------------------------------------------------------------------------
-- Physical constants (game-scaled)
------------------------------------------------------------------------------------------
C.ML_PER_CU = 16.387            -- ml per cubic unit (1 in^3)
C.MM_PER_UNIT = 25.4
C.DEFAULT_GRAVITY = 600

-- Blood colours (sRGB 0..255, before light) of shaded liquid geometry: airborne drops, beads and
-- hanging drops on bodies. Whole blood is a deep crimson leaning slightly blue (burgundy), never a
-- bright red: red light passes, green and blue are absorbed within a fraction of a millimetre.
-- Z-City compatibility (sh_zcity.lua, client/cl_compat.lua, server/sv_compat.lua).
C.ZCity = {
	-- Blood decals by name (Lua patterns). While abl_zcity_hitdecals is 0 the server's Lua code
	-- stamps none of Z-City's own (decals), and none of the engine's (engineDecals: the red
	-- splat, the splat at a bullet hit on flesh) within nearBody units of a body with a Z-City
	-- organism. Blood of another colour (YellowBlood) is not AdvancedBlood's and is left alone.
	decals = { "^Normal%.Blood", "^Arterial%.Blood", "^Water%.Blood$" },
	engineDecals = { "^Blood$", "^Impact%.Flesh$" },
	-- Engine effects that are a puff of red blood, by name; near such a body, the same rule.
	effects = { BloodImpact = true, bloodspray = true },
	nearBody = 110,
	-- A headless body: Z-City keeps a "fountain" at its neck and no wound. ABL bleeds it as one
	-- arterial wound of this size, the size Z-City itself gives the stump of an amputated limb.
	stumpSize = 10,
	-- Volume of one blob of a burst (a limb or a head coming off), ml: [1] to [2].
	burstVol = { 0.1, 0.35 },
}

C.Colors = {
	fresh   = { 100, 7, 12 },
	wet     = { 88, 6, 11 },
	aging   = { 66, 11, 11 },
	dried   = { 46, 16, 13 },
	body    = { 80, 6, 9 },       -- on skin / soaked into cloth (darker than free blood)
	-- engine decals: their textures carry the blood colour (tools/texgen), this only tints them
	decal   = { 255, 248, 248 },
}

-- Textured blood (tools/texgen) gets its colour from the textures: thickness sets it through
-- absorption, so thin films are lighter and translucent, thick layers deep and opaque. Vertex colours
-- only light and age it.
--   Filter textures (ground stains, runoff trails, settled body streaks) are multiplied over the lit
--   surface, so the surface shows through thin blood. They sit between fresh and dried blood; these
--   linear multipliers pull them either way: fresh deepens green (crimson), drying darkens red and
--   leaves green (brown).
C.Filter = {
	fresh = { 1.0, 0.72, 0.93 },
	aging = { 0.8, 0.86, 0.9 },
	dried = { 0.47, 1.0, 0.86 },
}
-- per-instance variation (venous darker, arterial brighter, dilution): multiplier range on red
C.ToneRange = { 0.86, 1.08 }

-- Venous bleed estimate (ml/s) from a Z-City wound value and pulse; see docs/ZCITY_INTEGRATION.md
C.VENOUS_K = 0.28      -- ml/s per wound point at pulse 70
C.ARTERIAL_K = 0.0563  -- ml/s per artery-size point per pulse bpm
C.POSTMORTEM_OOZE = 0.18   -- fraction of venous flow that keeps draining by gravity after death
C.POSTMORTEM_DECAY = 90    -- seconds for post-mortem drainage to fade

------------------------------------------------------------------------------------------
-- Bleeding profiles (selected by estimated flow rate; arterial wounds are always PULSED)
------------------------------------------------------------------------------------------
-- clot: small wounds bleed intermittently. A forming clot throttles the flow to `level` for
-- shut[1..2] seconds, then pressure (or movement) reopens it for open[1..2] seconds with a
-- short surge of the blood that backed up behind it.
C.Profiles = {
	minor = {
		name = "MINOR", seep = 1.0, gush = 0.0, jet = 0.0,
		beat = 0.05, noiseSigma = 0.45, noiseTau = 5.0,
		spurtRate = 0.0, spurtSpeed = 0, beadMax = 0.22, spreadCap = 0.35,
		clot = { level = 0.08, shut = { 2.5, 7 }, open = { 2, 6 } },
	},
	moderate = {
		name = "MODERATE", seep = 1.0, gush = 0.0, jet = 0.0,
		beat = 0.10, noiseSigma = 0.35, noiseTau = 4.0,
		spurtRate = 0.03, spurtSpeed = 28, beadMax = 0.3, spreadCap = 0.6,
		clot = { level = 0.4, shut = { 1.5, 4 }, open = { 4, 11 } },
	},
	severe = {
		name = "SEVERE", seep = 0.88, gush = 0.12, jet = 0.0, gushSpeed = 22,
		beat = 0.18, noiseSigma = 0.3, noiseTau = 3.0,
		spurtRate = 0.08, spurtSpeed = 40, beadMax = 0.4, spreadCap = 1.0,
	},
	high = {
		name = "HIGH-OUTPUT", seep = 0.6, gush = 0.4, jet = 0.0, gushSpeed = 38,
		beat = 0.25, noiseSigma = 0.25, noiseTau = 2.5,
		spurtRate = 0.15, spurtSpeed = 55, beadMax = 0.5, spreadCap = 1.6,
	},
	pulsed = {
		name = "PULSED", seep = 0.18, gush = 0.0, jet = 0.82, jetSpeed = 120,
		beat = 0.65, noiseSigma = 0.2, noiseTau = 2.0,
		spurtRate = 0.0, spurtSpeed = 0, beadMax = 0.5, spreadCap = 1.2,
	},
}
C.ProfileRate = { minor = 1.0, moderate = 4.0, severe = 10.0 } -- ml/s upper bounds
C.FRESH_WOUND_TIME = 3.0      -- seconds of HIGH-OUTPUT behaviour after a strong hit

-- Posture and movement. Venous pressure at a wound grows with its depth below the heart
-- (about 10 mmHg per 5.4 units of blood column), so a wound on a hanging leg bleeds harder than
-- the same wound on a raised arm. Arterial pressure is ~10x higher, so the effect is smaller.
C.HYDRO_VENOUS = 0.012        -- flow change per unit of height below (+) / above (-) the heart
C.HYDRO_ARTERIAL = 0.003
C.HYDRO_MIN, C.HYDRO_MAX = 0.4, 1.6
C.HEART_BONE = "ValveBiped.Bip01_Spine2"
C.MOVE_PUMP = 1 / 400         -- extra venous flow per u/s of limb speed (muscle pump, exertion)
C.MOVE_PUMP_MAX = 0.3

------------------------------------------------------------------------------------------
-- Surface categories. Values are relative multipliers used by impacts, runoff and pools.
--  adhesion : resistance to sliding (runoff threshold)       spread : stain size multiplier
--  absorb   : 0..1, fraction soaked in (less runoff/pooling) splash : splash tendency multiplier
--  runoff   : mobility of surface flow                        film   : pool film thickness (units)
--  dry      : drying speed multiplier (>1 dries faster)       alpha  : stain opacity
--  tint     : colour multiplier                               soak   : use fibrous soak stains
------------------------------------------------------------------------------------------
C.Surfaces = {
	default  = { adhesion = 1.0, spread = 1.0,  absorb = 0.2,  splash = 1.0,  runoff = 0.9,  film = 0.09, dry = 1.0, alpha = 0.95, tint = { 1, 1, 1 } },
	concrete = { adhesion = 1.1, spread = 1.0,  absorb = 0.25, splash = 1.0,  runoff = 0.8,  film = 0.085, dry = 1.1, alpha = 0.93, tint = { 1, 0.95, 0.95 } },
	metal    = { adhesion = 0.6, spread = 1.1,  absorb = 0.0,  splash = 1.25, runoff = 1.3,  film = 0.12, dry = 0.8, alpha = 1.0,  tint = { 1, 1, 1 } },
	wood     = { adhesion = 1.0, spread = 1.0,  absorb = 0.35, splash = 0.9,  runoff = 0.75, film = 0.09, dry = 1.1, alpha = 0.92, tint = { 0.95, 0.95, 0.95 } },
	glass    = { adhesion = 0.45, spread = 1.15, absorb = 0.0, splash = 1.35, runoff = 1.5,  film = 0.13, dry = 0.75, alpha = 0.9, tint = { 1.05, 1, 1 } },
	tile     = { adhesion = 0.55, spread = 1.1, absorb = 0.03, splash = 1.3,  runoff = 1.35, film = 0.12, dry = 0.8, alpha = 0.97, tint = { 1, 1, 1 } },
	stone    = { adhesion = 1.0, spread = 0.95, absorb = 0.2,  splash = 1.0,  runoff = 0.85, film = 0.1,  dry = 1.0, alpha = 0.93, tint = { 0.95, 0.95, 0.95 } },
	plastic  = { adhesion = 0.6, spread = 1.05, absorb = 0.0,  splash = 1.2,  runoff = 1.3,  film = 0.12, dry = 0.85, alpha = 0.97, tint = { 1, 1, 1 } },
	dirt     = { adhesion = 1.7, spread = 0.8,  absorb = 0.7,  splash = 0.6,  runoff = 0.25, film = 0.2,  dry = 1.4, alpha = 0.8,  tint = { 0.7, 0.8, 0.8 }, soak = true },
	grass    = { adhesion = 1.7, spread = 0.75, absorb = 0.65, splash = 0.5,  runoff = 0.2,  film = 0.22, dry = 1.2, alpha = 0.7,  tint = { 0.8, 0.9, 0.9 }, soak = true },
	fabric   = { adhesion = 2.2, spread = 1.35, absorb = 0.92, splash = 0.35, runoff = 0.05, film = 0.3,  dry = 0.7, alpha = 0.85, tint = { 0.85, 0.9, 0.9 }, soak = true },
	flesh    = { adhesion = 1.2, spread = 1.0,  absorb = 0.1,  splash = 0.8,  runoff = 0.9,  film = 0.1,  dry = 1.0, alpha = 0.95, tint = { 1, 1, 1 } },
	snow     = { adhesion = 1.5, spread = 1.2,  absorb = 0.8,  splash = 0.4,  runoff = 0.15, film = 0.25, dry = 0.3, alpha = 0.9,  tint = { 1.2, 1.1, 1.1 }, soak = true },
}

-- surfaceproperties names -> category
C.SurfaceNames = {
	concrete = "concrete", concrete_block = "concrete", plaster = "concrete", brick = "stone",
	rock = "stone", boulder = "stone", gravel = "dirt", porcelain = "tile", tile = "tile", ceramic = "tile",
	metal = "metal", metalpanel = "metal", metalgrate = "metal", metalvent = "metal", chainlink = "metal",
	metal_box = "metal", solidmetal = "metal", metal_barrel = "metal", floating_metal_barrel = "metal",
	metalvehicle = "metal", canister = "metal", paintcan = "metal", popcan = "metal", weapon = "metal",
	combine_metal = "metal", roller = "metal", slipperymetal = "metal", ladder = "metal", computer = "plastic",
	wood = "wood", wood_crate = "wood", wood_plank = "wood", wood_panel = "wood", wood_solid = "wood",
	wood_furniture = "wood", wood_box = "wood", wood_lowdensity = "wood",
	glass = "glass", glassbottle = "glass", combine_glass = "glass",
	dirt = "dirt", mud = "dirt", sand = "dirt", slipperyslime = "dirt", quicksand = "dirt", antlionsand = "dirt",
	grass = "grass", foliage = "grass",
	carpet = "fabric", cloth = "fabric", paper = "fabric", cardboard = "fabric", papercup = "fabric", mattress = "fabric",
	rubber = "plastic", rubbertire = "plastic", plastic = "plastic", plastic_box = "plastic", plastic_barrel = "plastic",
	flesh = "flesh", alienflesh = "flesh", bloodyflesh = "flesh", armorflesh = "flesh", zombieflesh = "flesh",
	snow = "snow", ice = "glass",
}

-- MAT_* fallback when the surfaceprop name is unknown
C.MatTypes = {
	[MAT_CONCRETE or 67] = "concrete", [MAT_METAL or 77] = "metal", [MAT_WOOD or 87] = "wood",
	[MAT_GLASS or 89] = "glass", [MAT_TILE or 84] = "tile", [MAT_DIRT or 68] = "dirt",
	[MAT_GRASS or 85] = "grass", [MAT_SAND or 78] = "dirt", [MAT_PLASTIC or 76] = "plastic",
	[MAT_FLESH or 70] = "flesh", [MAT_SNOW or 74] = "snow", [MAT_VENT or 86] = "metal",
	[MAT_GRATE or 71] = "metal", [MAT_COMPUTER or 80] = "plastic", [MAT_FOLIAGE or 79] = "grass",
	[MAT_SLOSH or 83] = "dirt",
}

------------------------------------------------------------------------------------------
-- LOD tiers (distance thresholds are scaled by quality and by the performance governor)
------------------------------------------------------------------------------------------
C.LOD_OFF, C.LOD_VERYFAR, C.LOD_LOW, C.LOD_MEDIUM, C.LOD_HIGH, C.LOD_ULTRA = 0, 1, 2, 3, 4, 5
C.LODNames = { [0] = "OFF", "VERYFAR", "LOW", "MEDIUM", "HIGH", "ULTRA" }
C.LODTiers = {
	-- dist: max distance for the tier; drops: per-source droplet quota
	-- hz: update rate of wound emission and droplets; flowHz: body-surface flow (0: none);
	-- runoffHz: world rivulets. The tick itself runs at abl_sim_hz (165), so ULTRA gets every tick.
	[5] = { dist = 420,  bodyflow = true,  hz = 165, flowHz = 165, runoffHz = 82, drops = 110, secondary = 1.0, satellites = 1.0, particlesOnly = false },
	[4] = { dist = 950,  bodyflow = true,  hz = 82,  flowHz = 82,  runoffHz = 41, drops = 70,  secondary = 0.55, satellites = 0.7, particlesOnly = false },
	[3] = { dist = 1700, bodyflow = false, hz = 41,  flowHz = 0,   runoffHz = 20, drops = 36,  secondary = 0.0, satellites = 0.4, particlesOnly = false },
	[2] = { dist = 3000, bodyflow = false, hz = 20,  flowHz = 0,   runoffHz = 10, drops = 12,  secondary = 0.0, satellites = 0.0, particlesOnly = true },
	[1] = { dist = 6000, bodyflow = false, hz = 12,  flowHz = 0,   runoffHz = 5,  drops = 0,   secondary = 0.0, satellites = 0.0, particlesOnly = true },
}
C.QualityScale = { [0] = 0.4, 0.6, 0.8, 1.0, 1.4 }

------------------------------------------------------------------------------------------
-- Simulation tuning
------------------------------------------------------------------------------------------
-- The tick rate targets abl_sim_hz; at low frame rates at most MAX_STEPS ticks run per frame, each
-- stretched up to MAX_TICK seconds, so blood keeps real time while the cost per frame is bounded.
C.MAX_STEPS = 8
C.MAX_TICK = 1 / 30
-- The longest frame the simulation follows in full (s): MAX_STEPS ticks of MAX_TICK cover it, so
-- blood keeps real time down to 4 frames per second. A longer frame (a stall, the game in the
-- background) is this long to the blood and no longer: it does not catch up afterwards.
C.MAX_FRAME = 0.25
-- Surface models of bodies kept (one per model and outfit, about 1.7 MB each), and how long one
-- must have gone unasked for before it may go (s).
C.MESH_KEEP = 24
C.MESH_IDLE = 60
C.DROP_TRACE_HZ = 66      -- collision look-ahead traces per droplet per second (at most)
C.DROP_LOOK_MAX = 0.12    -- s: how far ahead a drop in free flight looks once nothing is near (then ~8 traces/s)
C.DROP_BODY_HZ = 40       -- own-body hitbox tests per droplet per second while it is inside the body's bounds
C.DROP_STRETCH = 0        -- how far a drop near the eye is drawn out behind at speed. 0: round, which is what a drop in
                          -- free flight is (what a camera makes of a fast one is the streak of the sprites, and what it
                          -- leaves is the long stain). 0.6: an egg, blunt in front, up to 2.2 radii long behind at 500
                          -- units a second, the same volume: a picture of speed, not a shape blood takes
C.JET_HZ = 90             -- arterial jet segments per second at most (the stream is drawn continuous)
-- A stream in the air is a thread only for so long: surface tension pinches it into drops
-- (Rayleigh: about 12 sqrt(density d^3 / surface tension) for a thread d across; 0.05 s for one
-- of 1 mm, 0.15 s for one of 2 mm). k: seconds per mm^1.5; the limits in seconds.
C.StreamBreak = { k = 0.052, min = 0.04, max = 0.3 }

-- body-surface flow
C.Body = {
	adhesion      = 0.15,   -- ml^(2/3) * (|g_t|/|g|) to overcome before a bead runs (~0.06 ml on vertical skin)
	wetAdhesion   = 0.35,   -- adhesion multiplier on already-wet skin/cloth (follows old trails)
	speed         = 3.2,    -- u/s terminal runnel speed at 1 ml on a vertical surface
	filmLoss      = 0.006,  -- ml deposited per unit travelled on dry surface
	wetFilmLoss   = 0.35,   -- multiplier on wet surface
	minVol        = 0.006,  -- blob dies below this
	pendant       = 0.045,  -- ml detach volume for a hanging drop facing straight down
	edgePendant   = 0.03,   -- ml detach volume at open mesh edges (sleeves, hems, fingertips)
	inertia       = 0.55,   -- fraction of body acceleration felt by surface blood
	flingAccel    = 5200,   -- u/s^2 normal acceleration that flings blood off regardless of volume
	trailSpacing  = 0.8,    -- units between trail points
	trailPoints   = 22,     -- max points per trail
	offset        = 0.22,   -- render offset along the surface normal
	maxPerSource  = 24,     -- beads (runnel heads, resting lenses, hanging drops) per character
	nearDist      = 520,    -- closer than this, fresh body blood is drawn as liquid geometry re-skinned every frame
	glossDist     = 240,    -- closer than this, that liquid also gets its wet reflection pass
	domeDist      = 90,     -- closer than this, beads are raised domes; beyond, flat drops (their relief is below a pixel)
	settleTime    = 6,      -- seconds after a streak segment was last fed until it lies flat as a stain
	stainOffset   = 0.07,   -- render offset of settled body stains near the camera
	holdMax       = 1.6,    -- ml a bead at a wound holds before it runs off as a separate runnel
	spreadCap     = 0.45,   -- ml a free puddle on a flat body area holds before it overflows downhill
	film          = 0.035,  -- units: thickness of blood pooled on skin / soaked into cloth (puddle footprint)
	soak          = 0.02,   -- ml/s per ml^(2/3) of a resting puddle absorbed by cloth / dried on skin
	bridge        = 0.7,    -- max gap (units) blood crosses between mesh pieces (zipper strips, clothing layers)
	contact       = 2.2,    -- units: a drop forming this close to the ground seeps under the body instead of falling
}

-- flow core (cl_flowcore.lua): blood on a body as a liquid in channels
C.Flow = {
	-- cross-section of a rivulet: a parabola, area = 2/3 width x height
	aspect     = 8,        -- width / height while its contact line is free (a contact angle near 28 degrees)
	hMax       = 0.045,    -- units: the tallest a rivulet stands (about 1.1 mm); with more blood it only widens
	wCap       = 0.3,      -- units: the widest a stream gets on a body; more blood than that stands higher (a bulge)
	hBead      = 0.12,     -- units: ... up to the height of a drop
	wSheet     = 1.0,      -- units: ... and then widens again, to a sheet no wider than this. More blood than
	                       -- fills that stands higher still: it runs over what held it back, and where the
	                       -- surface is steep it does not stay at all (it drops off)
	-- transport: mean speed u = kFlow * slope * h^2 / mu (units/s, h in units). rho g / (3.5 muInf)
	-- for blood (1060 kg/m3, 3.45 mPa s at high shear) down a vertical surface, in game units
	kFlow      = 21900,
	maxSpeed   = 10,       -- units/s: no stream on a body runs faster (about 25 cm/s)
	level      = 1.0,      -- weight of the film's own height difference where gravity presses it on
	capillary  = 1.5,      -- ... and everywhere: surface tension evens out jumps in height along a stream
	subHz      = 60,       -- liquid steps per second at least (the step of a slow frame is split, and
	                       -- split further while a fast stream crosses short cells)
	maxSub     = 8,
	farHz      = 12,       -- steps per second of bodies too far away for full body flow
	-- cost: what the flow of all characters may take per frame, as a share of abl_budget_ms. The most
	-- important character is stepped every frame, the others while there is time left (their steps
	-- get longer, their liquid is drawn between its last two states as always).
	stepShare  = 0.36,     -- share of the budget for the solver
	stepWait   = 0.25,     -- s: no character waits longer than this for its step
	nodeCost   = 1.3,      -- microseconds one node costs per step (measured; plans how many short steps fit)
	nodePx     = 4,        -- pixels between two nodes at least: streams far from the camera are laid with
	coarseMax  = 4,        -- longer stretches (up to this many times the spacing)
	-- nodes
	spacing    = 0.35,     -- units between nodes
	minSpacing = 0.2,      -- ... at least, where the path turns onto another triangle
	minCell    = 0.2,      -- units: the shortest stretch a node stands for
	maxNodes   = 260,      -- per channel
	maxNodesSrc = 900,     -- per character
	-- the head and the wound
	cutFlow    = 0.3,      -- ml/s: a wound that bleeds less than this first beads at a few points along the cut
	cutLen     = 0.22,     -- units: length of the cut the beads stand on (plus cutGrow for a large wound value)
	cutGrow    = 0.25,
	woundSoak  = 0.5,      -- ml of blood the cloth right round a wound takes up (plus woundSoakSev for a large
	woundSoakSev = 1.0,    -- wound value): the soaked patch that grows round the opening
	woundSoakShare = 0.25, -- share of what comes out of the wound that goes into it while it is not full
	rootHold   = 0.002,    -- ml that stay at the wound as its wet opening
	rootRate   = 40,       -- 1/s: how fast the wound's blood passes to the bead on it
	headFull   = 0.14,     -- ml: a head with more than this sheds the rest into the stream behind it
	headShed   = 0.6,      -- ... this share of it, at every node it lays
	shedMax    = 0.03,     -- ml at most per node (what a node of a full stream holds)
	trailVol   = 0.0016,   -- ml of thin rivulet a head leaves at every node behind it (never a gap behind the bead)
	gapDraw    = 0.6,      -- units: a gap between mesh pieces wider than this is not drawn across
	spillSpeed = 1.2,      -- units/s: how fast blood creeps away from a puddle that runs over
	meanderLen = 1.6,      -- units of path over which a rivulet's heading wanders
	meanderAmp = 0.26,     -- radians (rms) it wanders off the fall line
	respawn    = 0.02,     -- ml at the end of a headless channel that start a new head
	mergeDist  = 0.17,     -- units: a head this close to another channel joins it; so does one whose edge
	mergeMax   = 0.5,      -- touches the other stream's edge (by their drawn widths), up to this far apart
	mergeWorld = 0.6,      -- ... on walls and floors (their streams are wider apart and drawn wider)
	worldChans = 40,       -- channels kept per region of the map (the oldest dry one goes first)
	worldShare = 0.5,      -- of abl_max_flow_nodes: what dry streams on walls may keep (bodies come first)
	landDist   = 1.0,      -- units: a drop landing this close to a channel is drawn into it
	landChans  = 12,       -- streams begun by landed drops, per character; beyond that a drop goes into the
	landFar    = 2.5,      -- nearest channel within this many units, or stays a spot
	maxChans   = 28,       -- channels per character (the least of those that no longer run makes way)
	checkEvery = 0.08,     -- units travelled between two looks for another channel
	-- branches
	branchVol  = 0.02,     -- ml standing at a node (beyond what a stream leaves there) before it may break out
	branchCos  = 0.4,      -- cosine between the channel's line and the fall line below which gravity pulls blood out
	                       -- of it (about 66 degrees: a rivulet that only wanders off the fall line keeps its bed)
	branchSpeed = 3.0,     -- units/s: a surge this fast may overshoot a bend
	branchBend = 0.03,     -- 1 - cosine of the bend (about 14 degrees) it overshoots at
	branchShare = 0.35,    -- share of the blood at the node an overshoot takes
	branchChance = 0.2,    -- per look (about three a second) at a bend that qualifies
	branchRate = 10,       -- 1/s: how fast a branch draws on its parent's node
	branchMax  = 3,        -- branches per channel
	branchEvery = 5,       -- s between two branches of one channel
	branchFree = 1.2,      -- units a branch runs before it may fall back into its parent
	-- rheology
	clotTime   = 60,       -- s (times abl_drying_scale) out of the vessel until blood sets: game time, not clinical
	clotVisc   = 30,       -- steepness of the rise in viscosity toward the gel point
	shearTau   = 0.25,     -- s: how long blood remembers the shear it flowed at
	tempK      = 0.02,     -- viscosity rise per degree C of cooling (about 2 % per degree)
	warmSkin   = 4,        -- degrees C fresh blood is warmer than skin
	warmCloth  = 10,       -- ... than clothing
	coolTau    = 3,        -- s: a thin film takes this long to come to the surface's temperature
	-- surface
	narrowTau  = 2.5,      -- s: how slowly a rivulet's contact line gives way when it holds less blood
	widenTau   = 0.12,     -- s: how fast it widens when it holds more
	thinH      = 0.0025,   -- units: blood thinner than this (0.06 mm) no longer runs, it is film
	thinTau    = 4,        -- s: ... and becomes film at this pace
	absorb     = 0.006,    -- ml/s per unit^2 of cloth under the stream (times the material's absorbency)
	soakCap    = 0.06,     -- ml of blood a unit length of cloth along the stream takes up
	soakDepth  = 0.02,     -- units: how deep cloth soaks (width of the soaked band = volume / depth / length)
	filmDry    = 35,       -- s (times abl_drying_scale): time constant of a film drying to a stain
	wetTime    = 45,       -- s: how long a stretch stays wet (glossy) after blood last ran over it
	stainDry   = 90,       -- s: time constant of wet stains on walls and floors (books only)
	-- drawing
	widthGain  = 2.2,      -- drawn / simulated width of a thin trickle (skin and cloth spread it wider than a clean
	                       -- rivulet); a wide stream is drawn nearer its own width (widthWide)
	widthWide  = 1.15,
	widthRef   = 0.06,     -- units: simulated width around which the gain falls from the one to the other
	minWidth   = 0.0012,   -- units of width per unit of distance: a stream stays about 1.5 pixels wide
	lutRef     = 0.03,     -- units: the depth the lookups call 1 (0.75 mm; tools/texgen Gen.FlowDepth)
	stainRef   = 0.006,    -- units: the depth the stain lookup calls 1 (what lies on a surface is thin but dense)
	stainMax   = 0.0055,   -- units: the deepest a stain is drawn (blood in cloth scatters light: red, not black)
	bodyK      = 0.75,     -- brightness of the liquid's own colour (what blood scatters back) under the light there
	stainBody  = 0.45,     -- ... of what a stream has left (dried blood, blood in the cloth: darker, browner)
	stainRow   = 0.55,     -- how dense that own colour is for a given stain (1: as dense as liquid of that depth)
	sheenK     = 3.0,      -- brightness of the mirrored surroundings relative to the light on the body
	specK      = 0.5,      -- brightness of the key light's highlight line (stretches of it: an unbroken white line
	skyK       = 0.1,      -- down a stream is a wire), and of the line the sky above leaves
	clothDull  = 0.4,      -- absorbency from which blood on a surface no longer shines (it is in the cloth)
	ragSkin    = 0.07,     -- how uneven the margin of what a stream leaves is on skin (share of its width) ...
	ragCloth   = 0.22,     -- ... and on cloth that soaks it (blood wicks along the weave)
	specSlope  = 1.0,      -- how far across the stream a highlight moves per unit of tilt (1 / the slope of its edge)
	headGain   = 1.0,      -- drawn / simulated contact radius of the head
	headShow   = 0.25,     -- ml: the head's drawn size stops growing here
	trackK     = 0.75,     -- width of the track a head leaves, relative to the head
	bakeDist   = 160,      -- units: beyond this a channel that has stopped is drawn from baked strips while it dries
	-- detail by distance (units; the governor's LOD scale shortens them all under load)
	lineDist   = 150,      -- highlight lines along streams
	haloDist   = 400,      -- the band of cloth soaked around a stream
	viewSpeed  = 8,        -- units/s at the top of the velocity view's scale
	viewMass   = 0.02,     -- ml per node at the top of the mass view's scale
}

-- blood film (cl_film.lua): blood on a body as a layer that covers its surface, cell by cell
C.Film = {
	-- the surface: one grid per material, laid in that material's own texture space (cl_filmchart.lua)
	cell        = 0.3,     -- units: the size of a cell (7.6 mm); a material too large for its canvas gets larger ones
	canvas      = 256,     -- texels: the size of a body's canvases (a material's grid is no larger, less the border)
	border      = 2,       -- texels round the grid in a canvas: the outer one stays clear, the inner takes the rim's colour
	trim        = 0.03,    -- share of a material's surface that may be left out so that the rest gets finer cells
	overlapDist = 2.5,     -- units: two places further apart than this that share texels cannot both be painted
	minUsable   = 0.6,     -- share of a material's surface that must be paintable for it to carry a film
	minBody     = 0.5,     -- ... and of the whole body's, for the body to have one (else: the flow core's channels)
	inside      = { "mouth" },   -- materials (by a word in their name) that are no outside of a body: they carry no film
	seam        = 1.3,     -- cells: how far off the rim of a material's map the surface is looked for (a texture seam)
	bridge      = 2.2,     -- units: the gap between two pieces of the mesh (a shirt's hem, trousers) the film still crosses
	-- the liquid: the law of the ground pools (cl_poolsim.lua) on a body's surface
	step        = 0.05,    -- s: the film's own time step (20 a second, on a grid of the game's time)
	maxSteps    = 2,       -- steps of one body in one frame at the most (a body that fell behind does not catch up in a burst)
	lim         = 0.4,     -- share of the head difference that may cross a face in a step (two surfaces come level, they
	                       -- do not swap) ...
	limRun      = 0.8,     -- ... and of the layer itself, where the place ahead lies lower than that allows for: down a
	                       -- steep place nothing pushes back, and most of a deep layer goes on in a step. (At 0.4, as
	                       -- it was, a layer ran 2.4 units a second at the most, whatever its depth: a wound that gave
	                       -- five millilitres a second could not be carried off in a run, stood a tenth of a unit deep
	                       -- beside the opening and spread from there as a sheet. Blood two millimetres deep on a steep
	                       -- place runs several times as fast. Measured on the bench, tools/offline/benchset.ps1.)
	downFirst   = 1,       -- 1: of a place's four sides the one that lies lowest is given to first: what gravity takes
	                       -- of a layer goes before anything of it is pushed sideways. 0: the sides take turns at being
	                       -- first, as they did (a run of five millilitres a second fanned out to ten cells just below
	                       -- its wound and came down a sloping chest as a ragged sheet; with 1 it is a run three or
	                       -- four cells wide, and one of two millilitres a second is two cells wide. Measured on the
	                       -- bench: tools/offline/benchset.ps1 with k_downFirst=0 and 1.)
	sweep       = 1,   -- the order the places are stepped in: 1 is the order blood first came to them, from the
	                       -- wound down: what a place is given in a step it passes on in the same step, as a run does.
	                       -- 0 turns the order round every other step (as it was: every second step a run moved by
	                       -- one place only, and its depth went up and down with the steps)
	visc        = 1.3,     -- viscosity relative to the flow core's (kFlow). (At 6 a layer crept a hand's width in a minute
	                       -- and what a wound gave soaked in round it: a stain, not a flow. Measured on the bench.)
	filmSkin    = 0.022,   -- units: the layer a dry place of bare skin holds back before blood runs on over it (0.55 mm)
	filmCloth   = 0.03,    -- ... of cloth (what cloth does differently is drink it, below). Sideways a layer has to
	                       -- stand that deep before it spreads; downhill far less (slope): a small flow stays a run
	                       -- one or two cells wide and does not come down as a band (measured on the bench: at 0.018
	                       -- it was three cells wide all the way).
	pinAmp      = 3,       -- how much more than that the roughest places hold back (ABL.PoolSim.Pin, fixed to the body): where
	                       -- the line holds, blood gathers and the flow is full; where it gives, a narrow run goes on
	pinScale    = 2.4,     -- ... and how much finer than a floor's a body's unevenness is (folds, weave, pores)
	level       = 3,       -- how much more a place holds back that faces up: gravity presses the layer on there
	filmMax     = 0.085,   -- units: the most any place holds back (2 mm: the depth of a puddle of blood on a level place)
	slope       = 1.5,     -- how much more a layer counts toward running on over a dry place that lies a whole cell lower
	                       -- (at 3 nothing held a front that ran downhill: it came down as one even band)
	res         = 0.15,    -- of what a place holds back: the film it keeps when blood has run off it
	memory      = 0.25,    -- a place that has been wet holds the contact line back this much of what a dry one does
	tension     = 0.45,    -- how much harder the line holds at the tip of a finger than along a straight front (less in a bay)
	hold        = 0.07,    -- units: the most that stands on a steep place (1.8 mm); what is more drops off
	holdUp      = 1.0,     -- ... on a place that faces up: as good as anything (a hollow of a lying body fills and runs
	                       -- over its rim; nothing drops off the top of a chest)
	holdDown    = 0.028,   -- ... under a place that faces down (a hanging drop)
	shedRate    = 0.4,     -- share of what is too much that leaves in a step
	dropVol     = 0.045,   -- ml: what collects at an edge or a low point leaves as drops of about this size
	dropWait    = 1.5,     -- s: ... or after this long, if it is at least dropLeast of that (less stays on the body:
	                       -- a hundred places that each let go of a trace are a spray, not drops)
	dropLeast   = 0.3,
	gapDrip     = 0.5,     -- share of what runs across a gap between two pieces of clothing (a hem over trousers, a cuff)
	                       -- that does not get across: it hangs at the edge and drops
	dropRate    = 8,       -- drops a second one body lets go at the most: when more blood leaves than that many drops
	                       -- of dropVol carry, the drops are larger ...
	dropBigMax  = 6,       -- ... up to this many times dropVol
	idleSteps   = 10,      -- steps without moving after which a place is looked at only now and then
	source      = 0.03,    -- units: a cell of the wound's opening holds this much; what wells up beyond it runs over the
	                       -- opening's rim where the rim is lowest (cl_film.lua, Spill)
	openMin     = 0.05,    -- units: how far a wound's opening reaches from its middle when nothing is known of it (one cell) ...
	openMax     = 0.75,    -- ... and at the most. In between it is the visible wound's own opening (cl_woundfx.lua): the
	                       -- blood comes out of the hole that is seen, a cell for a bullet's entry, a few for a wide exit.
	                       -- (It went by the wound's value before: a gunshot's blood welled up over a patch five cells
	                       -- across, and what that could not hold was laid round it on every side: a disc of blood with
	                       -- the hole in its middle within a third of a second, on a wall as on a floor. Measured: scene
	                       -- bleed_origin, run bo0.) How wide the flow is below a wound is the flow's own doing.
	-- The folds of cloth and the unevenness of skin that the model's mesh does not have: a relief on
	-- the floor the film runs on, fixed to the body (the same on either side of a texture seam). Blood
	-- gathers in its hollows, runs along them and parts at its ridges, where on the smooth mesh it would
	-- come down as one even tongue. Its height is the height of a fold, not of the film: an
	-- approximation of what folds do to a thin layer, applied whichever way the surface faces.
	reliefCloth = 0.6,     -- units: how far the folds of cloth stand out: enough to turn a run aside into a fold and
	                       -- along it (drawn out along the body they do not dam it: reliefTall)
	reliefSkin  = 0.15,    -- ... and skin (what a face has of shape is in its mesh)
	reliefScale = 2.6,     -- units from one fold to the next
	reliefTall  = 0.35,    -- how much shorter than that a fold is along the body's height (1: as long as wide; 0.35: three
	                       -- times as long, as cloth hangs)
	reliefLevel = 0.75,    -- how much less the folds count where the surface is level (share: on a lying chest they are
	                       -- a quarter as high, or its blood would stand in them as in basins)
	reliefFine  = 0.3,     -- share of it at a third of that scale (creases, the weave)
	round       = 0.75,    -- how much of the roundness the body is drawn with the film runs on (0: on its flat triangles,
	                       -- as it did: straight across each, with a corner at every edge of the mesh; cl_film.lua, Bulge)
	roundMax    = 0.35,    -- units: the furthest a place is taken to lie off its flat triangle for that
	grain       = 0.008,   -- units: how much one place stands above or below the next, at random (pores, threads): a
	                       -- layer running down a surface that is even to the grid's eye would keep to the grid's lines
	-- cloth
	soakDepth   = 0.012,   -- units: how much blood a unit of ordinary cloth takes up (0.3 mm of it), times the material's absorbency
	soakTau     = 0.8,     -- s: how fast it takes blood up from the layer standing on it
	soakUneven  = 0.25,    -- how uneven cloth is in how much it takes up (share, either way: a stain is mottled)
	wickFrom    = 0.3,     -- how full cloth has to be before blood creeps on through it to drier cloth beside it
	wickRate    = 0.10,    -- share of the difference in fullness that moves across a cell's side in half a second
	                       -- (across a corner half of that: a patch grows round, not along the grid)
	wickDown    = 0.8,     -- how much of that gravity adds downhill and takes away uphill
	wickUneven  = 0.9,     -- how uneven cloth is in passing blood on (share of the rate, either way) ...
	wickPatch   = 3.2,     -- ... in patches about this many units across (how the cloth lies), and finer within them
	wickReach   = 2.2,     -- cells: how far blood creeps through cloth from where liquid stands on it (0.15 to 1.85 times
	                       -- that, by the patch of cloth it is in), ever slower the further it has come
	wickReachSkin = 1.2,   -- ... and along bare skin
	-- A front in cloth goes on, ever slower: by the root of the time liquid has stood where it comes
	-- from. The reach above is where it is at once; after wickGrowTau seconds it is (1 + wickGrow)
	-- times that, after four times as long (1 + 2 wickGrow) times, and never more than wickGrowMax
	-- times. So the stain round a run that goes on running goes on widening for a few minutes: what
	-- a wound has given is seen on the body, not only on the ground under it. (Measured: scene
	-- cont_long. With one reach for good the body's blood was the same picture after 15 s and
	-- after 150 s.)
	wickGrow    = 1.0,
	wickGrowTau = 15,      -- s (at 40 the stain of a wound that had bled for half a minute was still the narrow
	                       -- margin of its run: scene cont_stand, run fl2_first)
	wickGrowMax = 3.2,
	wickWet     = 60,      -- s (times abl_drying_scale): how long blood in cloth goes on creeping after the last of it
	                       -- came there; then it has set, and the stain is as wide as it gets
	wickUp      = 1.5,     -- how much more of its reach a place counts that the front has to climb to (straight up:
	                       -- 1 + this; sideways and down: 1)
	hemReach    = 3,       -- how many times as far blood creeps from cloth at an edge of the surface or at a gap between
	                       -- two pieces of clothing (a hem, a cuff, a collar: doubled cloth, a channel along the edge)
	-- An edge of the surface (a hem, a cuff, a collar) and a gap between two pieces of clothing hold
	-- a layer back as the rim of anything does: only what stands above this leaves the edge or
	-- crosses the gap. Blood that comes down to a hem gathers along it, soaks it to either side and
	-- drops from where it has gathered (several places when much comes), where it used to go over
	-- the edge in one place at the width of its run.
	edgeHold    = 0.045,   -- units (1.1 mm)
	-- Bare skin drinks nothing, but its furrows and fine hair hold a little, and blood creeps along
	-- them from where it stands: slowly, and only from places that are full. The wet margin of blood
	-- on skin is uneven for it, and stays as a thin stain when the layer has run off.
	skinSoak    = 0.12,    -- what skin's surface holds, as a share of what ordinary cloth takes up (0.09 mm)
	wickSkin    = 0.3,     -- how readily it passes on along skin, as a share of cloth's rate
	wickFromSkin = 0.6,    -- ... and how full a place of skin has to be for it
	-- time
	dryRate     = 0.0001,  -- units a second that dry off a wet place (a film of 0.25 mm in 100 s), divided by abl_drying_scale.
	                       -- (At 0.00028 a small wound's film dried as fast as the wound fed it once it was a hand wide.)
	dryEdge     = 0.5,     -- how much faster per dry neighbour (the margin dries first, then inward)
	wetTime     = 45,      -- s: how long cloth looks wet after the last liquid stood on it (times abl_drying_scale)
	-- limits and cost
	maxCells    = 9000,    -- cells of one body at the most
	stepShare   = 0.4,     -- share of abl_budget_ms the films of all bodies may take in a frame
	-- What is shown of a cell (cl_filmdraw.lua). The film is drawn as what it is on the body: a layer
	-- with a colour of its own that hides what lies under it, inside one clean outline, lit by the
	-- game's light as the body under it is, with that light's highlight where it is wet.
	showMin     = 0.0012,  -- units of blood in all, on a place and in its cloth, from which the film is there: its outline
	openCover   = 2.6,     -- how much more than its share a place counts that blood comes out at (a wound's opening):
	                       -- the film's outline lies a cell's width round it, clear of the visible opening
	coverSoak   = 0.5,     -- how full cloth that has only drawn blood in from beside it has to be to count as covered
	                       -- with it (less: by its share of that)
	edgeNoise   = 0.10,    -- how far the outline strays from the even line between the cells (in the field's own units:
	                       -- the outline is where the field is 0.5), fixed to the body and even from one cell to the
	                       -- next: no outline of blood is a ruled curve, and none has a kink at every cell
	deepRef     = 0.03,    -- units of blood at a place from which its colour is as dark as it gets: a run of liquid is
	                       -- dark, the cloth it has soaked beside it lighter (one even red from rim to rim is paint)
	-- Its own colour (sRGB 0..255, before light): by how much blood is at a place (a film's, a
	-- layer's, the deepest) and by how wet it still is (fresh: red; dried: red-brown). Dark for a
	-- red: blood gives back little light, and under a strong light or a camera that has opened up
	-- in the dark a brighter one is paint (measured: scene film_skin).
	palette = {
		wetThin = { 112, 14, 16 },
		wetBody = { 92, 10, 12 },
		-- (the deepest. At 60 the middle of a run on a white sweater in the sun was 0.58 times as
		-- bright as its rim, a dark stripe down a red one; as one layer it had been 0.74 times:
		-- measured, scene film_liquid)
		wetDeep = { 70, 7, 8 },
		wetDeepOld = { 60, 6, 7 },   -- (as it was: for the film as one layer, abl_film_layers 0)
		dryThin = { 80, 26, 19 },
		dryBody = { 64, 18, 13 },
		dryDeep = { 42, 11, 9 },
	},
	mottle      = 0.16,    -- how much a place differs in colour from other places (share, either way): in patches, and
	                       -- finer within them
	grainTone   = 0.05,    -- ... and one texel from the next
	-- How it shines: liquid standing on a place in full, cloth full of fresh blood hardly, dried
	-- blood less still. (Cloth that shines as liquid does is a pale pink sheet under the sun: measured,
	-- scene film_lying.)
	wetRef      = 0.006,   -- units of liquid from which a place shines in full
	soakShine   = 0.05,
	dryShine    = 0.03,
	-- The highlight of a lamp on wet blood is small and bright. A wide one (an exponent of 28 or 60)
	-- lies over the liquid as a pale pink smear, a weak wide one as a pink haze: measured with the sun
	-- on a wet chest and the eye where the sun is mirrored, scene film_shine.
	phongExp    = 130,     -- how small it is ...
	phongBoost  = 1.3,     -- ... and how bright (more, and blood-soaked cloth shows a pale patch under the sun; at 1.8
	                       -- the flank of a run was a white stripe from where the sun is mirrored: scene film_ab)
	-- A level sheet of liquid mirrors the sun as one pale glow, however small the highlight is set:
	-- the film shows a lamp in full only where its surface turns (its rims, its ridges, its lumps).
	flatShine   = 0.04,    -- how much of its shine a place has where the surface is level (at a tenth, a sheet of
	                       -- liquid seen from where the sun is mirrored in it was a pale pink patch: scene film_ab) ...
	shineSlope  = 0.35,    -- ... and the tilt (its tangent) from which it has all of it: the flank of a bead, the rim
	                       -- of a sheet. (At 0.1, the value for one layer, the waves on a running sheet were tilt
	                       -- enough: all of it shone at once, a white patch. Measured: scene film_ab.)
	-- its surface: the light on it follows how deep the blood stands from place to place, and no
	-- wet surface is quite even
	relief      = 8,       -- how much steeper than it is the surface is drawn: a run of liquid is a rounded bead under
	                       -- the light, lit on one flank and dark on the other, not a flat stripe
	reliefMax   = 0.5,     -- the steepest it is drawn (the tangent of its tilt)
	glint       = 0.10,    -- how uneven a wet surface is, in lumps a few texels across (the tangent of its tilt, where it
	                       -- shines in full)
	ease        = 0.3,     -- s: how long a texel takes to become what its cells have become (the outline moves, it
	                       -- does not jump from cell to cell)
	smooth      = 1,       -- 1: the film's outlines are read from a second picture of twice the canvas's size, made from
	                       -- the canvas by the graphics card, in which they bend evenly through the cells; 0: cut from
	                       -- the canvas itself, a straight piece a cell with a corner between each two (in the game:
	                       -- abl_film_smooth 0, to see the two side by side; cl_filmdraw.lua, D.Smooth)
	smoothOff   = 0,       -- texels of the canvas by which that second picture is moved to lie where the first does
	                       -- (as measured in the game: scene film_smooth)
	paintEvery  = 0.12,    -- s: how often a film's canvases are painted at the most (what changed, and what is on its way)
	paintNear   = 0.066,   -- ... of a body nearer the eye than paintNearDist: fifteen times a second, nearly as often as
	                       -- the film itself is stepped, so that its outline moves in small steps (at 0.12 it moved
	                       -- eight times a second, a cell's width at a time where blood ran fast; at 0.05 a film that
	                       -- bled hard cost 0.7 ms a frame to paint, measured: run bo2)
	paintNearDist = 150,   -- units
	paintWork   = 30,      -- cells and texels that wait from which a film is painted that often ...
	paintCalm   = 0.3,     -- ... and how long one with less to paint waits (s)
	paintTexels = 240,     -- texels looked at in one painting at the most: a cell that changed is nine of them
	paintSteps  = 20,      -- steps after which a place where blood runs is painted again (a second)
	paintTurns  = 6,       -- turns (of half a second) after which a place that dries or soaks is painted again
	paintBusy   = 250,     -- cells of one film that wait to be painted from which the two above are twice as long:
	                       -- what a large film shows of its inside changes slowly, and its outline is painted first
	paintSkip   = 1,       -- 1: a cell asked to be painted again whose look has not changed by a step of colour or of
	                       -- its outline is not painted again (cl_filmdraw.lua, PaintMap); 0: it is, as before
	idleFree    = 4,       -- s: a body that has not been drawn for this long may give its canvases back ...
	idleSpare   = 6,       -- ... and does when fewer canvases than this are left to be had (and to a film that finds none),
	idleLong    = 120,     -- ... or when it has not been drawn for this long (s). Until then it keeps them: its blood is
	                       -- on it in the first frame it is seen again, and is not painted anew from nothing.
	glossDist   = 420,     -- units: further away than this the wet film mirrors nothing
	drawDist    = 1700,    -- ... and further away than this no film is drawn
	-- Two layers (cl_filmdraw.lua). All of the film is drawn as a stain in the surface it lies on:
	-- with that surface's own relief and with its own texture showing in it, so that a shirt's
	-- weave, its pattern and its folds go on through it, and it takes the light as the cloth round
	-- it does. Blood that stands on the surface as liquid has an outline of its own inside that, and
	-- a surface of its own (its rims, its streaks, its waves): what is drawn of it over the stain is
	-- what a wet surface adds, the light's highlight and the sky's sheen. Drawn as one layer with a
	-- relief of its own (the way it was) blood is paint on the body: on some clothes it takes the
	-- light quite otherwise than the cloth under it. (Measured: scenes film_try, film_liquid.)
	material    = 1,       -- 1: so; 0: one layer, as before (in the game: abl_film_layers 0, to see the two side by side)
	-- How much of a layer of liquid a place counts for, by how deep wet blood stands on it. The
	-- liquid's outline lies where half of a texel's surroundings are liquid: a single row of places
	-- that count for two thirds is a hairline, at 1 a bead a cell and a third wide, at 1.25 one of a
	-- cell and three quarters. (Cut at one depth instead, the outline ran through the middle of what
	-- a run leaves behind it and broke up into blocks: measured, scene film_ab.) Dried blood is stain.
	topLo       = 0.0015,  -- units of wet blood on a place from which it counts at all ...
	topHi       = 0.004,   -- ... and from which it counts for liqThin
	liqThin     = 0.75,
	liqFull     = 1.25,    -- what a place counts for from liqDeep units on
	liqDeep     = 0.03,
	rim         = 0.5,     -- how bright the sky's sheen on liquid seen at a flat angle is (the engine's rim light)
	liquidTint  = 1.0,     -- (with liquidPasses 2 or 3) the liquid's brightness against the colour of the place it
	                       -- stands on: at 0.95 a run in a body's own shade was half as bright as the cloth it had
	                       -- soaked, nearly black; at 0.72 a dark stroke with a bright border (scene film_ab)
	-- The liquid's own surface: a layer of liquid ends in a rounded rim and is level where it is
	-- broad; a narrow run is all rim, a bead. It is what the highlight and the sheen are laid on:
	-- a lamp shows on the flank of a run that is turned to it, and along the rim of a sheet.
	bead        = 0.8,     -- the slope of that rim where it is steepest (the tangent of its tilt, about). (With the
	                       -- liquid's colour drawn by this surface too, liquidPasses 2 or 3: at 1.6 the flank of a
	                       -- run that faces away from the sun was black, a rubber tube; at 1.1, under a sun that
	                       -- grazes the surface, still a dark line along the liquid's outline, half as bright as
	                       -- the stain beside it. Measured: scenes film_ab, film_pairs)
	beadMax     = 1.2,     -- the steepest the liquid's surface is drawn, all told
	beadDeep    = 0.012,   -- units: how deep blood stands round a place (on average over it and the eight round it)
	                       -- for its rim to be that steep; a shallower film has a lower rim, down to a fifth
	reliefLiquid = 4,      -- how much steeper than it is the liquid's surface is drawn on top of that (its depth from
	                       -- place to place, its streaks, its waves): `relief`, for the liquid as a layer of its own
	-- (2026-10-13, later: the stain is now drawn darker by as much as the cloth's texture makes it
	-- brighter on average, cl_filmdraw.lua, Gain: its brightness stays what it was at clothShowWas,
	-- on any cloth, and more of the texture shows only what differs from place to place in the
	-- cloth, its knit, its pattern, its folds. At 0.2 nothing of a sweater's knit showed in its
	-- blood: scene cont_stand, run fl1_diag. The notes below are of the time before that.)
	clothShowWas = 0.2,    -- the share the stain's brightness is kept at, and what shows through a layer of liquid
	deepTint    = 1.0,     -- (phase 18) how bright the liquid's own colour is drawn against the stain round it (light,
	                       -- linear: 0.7 is seven tenths of it). 1: as bright, as before
	deepPass    = 1,       -- 1: the liquid's own colour is drawn over the stain's, with as little of the cloth showing
	                       -- as clothShowWas (a layer of liquid hides the weave under it); 0: the stain's colour all over
	clothShow   = 0.6,     -- how much of the surface's own texture shows in the film (0: none .. 1: in full). It is
	                       -- the texture's brightness too: at 0.5 blood in white cloth was half again as bright as
	                       -- the colours below, a red of paint (scene film_wave); at 0.25 the rim of a run on a
	                       -- white sweater was a fifth brighter for the cloth and blood on a black suit a fifth
	                       -- darker, a third darker than it was as one layer (scene film_liquid)
	soakDeep    = 1.0,     -- how much blood in cloth counts toward the depth of its colour (cloth that is full of it
	                       -- is two fifths of the way from the lightest red to the darkest; at 1.6, with the liquid on
	                       -- it counted in full, a run on cloth was the darkest colour from end to end: nearly black)
	deepLiquid  = 0.045,   -- units of liquid on a place that make its colour as dark as it gets, by themselves
	liquidShow  = 0.2,     -- (with liquidPasses 2 or 3) ... and in the liquid's own colour over the stain
	-- (2026-10-14, phase 18: 2. Seen again in the game with the stain's own relief valid (run p18b,
	-- scene acc_look): on a white sweater in the sun and in its own shade, and on a black suit, the
	-- liquid lit by its own surface shows a run as a rounded run (a darker core where its surface turns
	-- away from the light, its rim and its middle ridge raised) where with 1 it was one flat red; no
	-- dark shape with a bright line round it, 7 % darker on average in shade. The notes below are of
	-- the time before, when the stain they were compared with was lit through a relief texture the game
	-- names "error".)
	liquidPasses = 2,      -- what is drawn of the liquid over the stain. 1: the light's highlight and the sky's sheen
	                       -- on its own surface, added over the stain (its colour is the stain's, which is as deep
	                       -- as the blood there). 2: its colour too, by a pass of its own with its own surface for
	                       -- relief, and the highlight over that. 3: colour and highlight in one pass, by the
	                       -- shader that has the highlight.
	                       -- Measured (scene film_liquid, on a white sweater and a black suit, in the sun and in
	                       -- the body's own shade): with 2 and with 3 alike, the liquid on the white sweater in
	                       -- shade was 0.4 times as bright as the stain beside it, a dark shape with a bright red
	                       -- line round it, and 0.8 times in the sun; on the black suit the two were alike. It is
	                       -- not the shader (2 and 3 are alike). What is left that they do not share with the
	                       -- stain is the relief they are drawn with: the stain has the body's own, as the cloth
	                       -- round it has, and they have the liquid's. On the black suit that makes no difference
	                       -- (scene film_bump); on the sweater it was not taken apart. With 1 there is no such
	                       -- line on either, and a pass less over the body.
	softPx      = 0,       -- screen pixels over which the stain's outline is smoothed, by a pass of its own (0: none).
	                       -- None: told a pixel's width, the pass drew no rim at all on a white sweater and a red
	                       -- glow a texel wide (twenty pixels from close by) round blood on a black suit, and what
	                       -- it was told made no difference to either (measured: scenes film_pairs, film_rim). The
	                       -- outline is the stain's own cut: a smooth line, stepped by the pixel as every edge in
	                       -- the picture is when the game's anti-aliasing is off
	softMin     = 0.006,   -- ... and the least it is smoothed over, in the field's own units (a fifth of a millimetre
	                       -- at a sharp outline; where the blood thins out toward its rim, the rim is wider by
	                       -- itself. At 0.035, and again at 0.012 with the pixel measured from the body's middle,
	                       -- it was a blurred red edge from close by: measured, scene film_ab)
	softDist    = 380,     -- units: further away than this the outline is left as it is
	-- What the liquid's surface shows of its flow. For every place the film keeps which way the
	-- blood crosses it and how fast (cl_film.lua: dx, dy, sp), and how far the blood there has run
	-- since it left the wound (ds). Streaks: what differs from place to place is drawn out along
	-- the flow, in colour and as low ridges. Waves: a running layer carries low waves that travel
	-- the way it runs; they are as steep as it is fast, and a layer that has come to rest is still.
	dirTau      = 0.3,     -- s over which a place's direction follows what crosses it: a flow that turns takes its
	                       -- streaks round with it over a moment
	speedTau    = 0.5,     -- s: the same for how fast it runs
	streak      = 0.09,    -- how much lighter and darker the streaks are (share, either way)
	streakH     = 0.0025,  -- units: how far their ridges stand out of the liquid
	rippleTilt  = 0.16,    -- how steep the waves on a layer that runs fast are, along the flow (the tangent of the
	                       -- tilt: nine degrees forward and back as a wave passes)
	rippleFull  = 1.2,     -- cells a second from which they are that steep
	rippleLen   = { 9, 5 },       -- cells from one wave to the next: two trains of them, a long slow one ...
	rippleRun   = { 1.0, 1.8 },   -- ... and a shorter faster one (cells a second); the faster the layer, the more of the second.
	                              -- (Shorter than five cells a wave is not there on a grid of cells: the places along a
	                              -- run cancel one another out. Measured on the bench.)
	rippleEvery = 0.1,     -- s between two paintings of the waves
	rippleCells = 320,     -- places whose waves are moved on in one painting at the most (a film with more takes turns:
	                       -- its waves then move in coarser steps, which shows. A painting of that many is a millisecond.)
	rippleDist  = 260,     -- units: further away than this the liquid's surface is still (the governor's scale shortens it)
	-- How fast the waves travel, as multiples of how fast the liquid under them runs (the two trains):
	-- waves on a running film travel a little faster than the film. On a layer that stops they stop.
	-- (nil: on a clock at rippleRun cells a second whatever the liquid does, as before: on a slow run
	-- they slid down it faster than the blood went.)
	rippleWith  = { 1.3, 1.8 },
	ageTone     = 0.14,    -- how much darker blood is that has been out of the vessel for the clotting time
	-- (2026-10-14, phase 18) The films nearest the eye are drawn and painted in full whatever the
	-- governor's scale is (abl_film_full_near; cl_filmdraw.lua, D.FullLook): this many ...
	fullCount   = 3,
	fullDist    = 320,     -- ... within this many units (times the quality preset's scale)
	-- A layer of liquid that stands deep (a hollow that fills, the low side of a lying body) has a
	-- fuller, rounder rim than a thin run: its rim's slope grows past beadDeep with the depth, by
	-- rimGrow for every beadDeep more, up to rimMax times the slope at beadDeep. (0: as before, one
	-- rim for every depth past beadDeep.)
	rimGrow     = 0.35,
	rimMax      = 1.8,
}

-- Phase 19 (2026-10-17): blood drawn as one smooth wet liquid. Every part is on while the client's
-- abl_liquid_v19 is 1 and its own entry here is not 0 (C.V19On); abl_liquid_v19 0 draws everything
-- as it was before phase 19. Most of it is how the liquid is drawn and where a drop starts. Three parts
-- change where blood goes, every millilitre still booked: fullIsWall (what a film does at its cell
-- cap), and reachField and reachRun (how far blood creeps through cloth: more of it stays in the cloth
-- and less drips off). docs/blood_upgrade/PHASE19_PLAN.md and PHASE19_SMOOTH_LIQUID.md say what each
-- part does and why.
C.V19 = {
	-- The film on a body (cl_filmdraw.lua)
	split        = 1,      -- the film's outline and the liquid's are each the alpha of a target of its own (A and L),
	                       -- its share itself, so that each cut lies where its share is a half and the two no longer
	                       -- force a margin of stain round every run (no alpha-to-coverage on them: a ramp a texel wide
	                       -- would be a dithered band on screen)
	alphaK       = 1,      -- alpha 0.5 + alphaK x (share - 0.5), clamped. 1: the share itself, linear wherever a texel
	                       -- beside an outline is, so the outlines lie exactly where they lay before
	b2           = 1,      -- the liquid's surface is read from a second picture of twice its size (B2), as the outline is
	                       -- (made from B's own bytes; turned off by itself if the game's probe finds otherwise)
	surface      = 1,      -- the liquid's surface follows its depth: a low dome with a rim where it ends, not a tube
	depthGain    = 1.5,    -- how much steeper than its depth makes it the liquid's surface is drawn (1: as it is)
	rimK         = 0.7,    -- the rim at the liquid's edge: this times the gradient of its share per cell ...
	                       -- ... times the root of how deep it stands there against K.beadDeep, from 0.3 to 1.5 of that
	slopeSoft    = 0.6,    -- the steepest the surface is drawn, reached softly (no plateaus, no creases)
	lumps        = 0.4,    -- share of K.glint that the surface's lumps keep
	-- (The highlight's numbers stay K's until an A/B in the game from where the sun is mirrored: 0.2 and 1.6
	-- here were worked out to repeat the "pale pink patch" of scene film_ab, sh_config's C.Film notes.)
	flatShine    = 0.04,   -- how much a level surface of liquid shines
	phongExp     = 130,    -- the highlight's lobe ...
	phongBoost   = 1.3,    -- ... and how bright
	rim          = 0.15,   -- the engine's rim light on the liquid (K.rim 0.5 laid a pale line along every flank: it is not
	                       -- masked by the shine)
	ease         = 1,      -- colour, shine and surface come to what their cells have become over K.ease, as the outline does
	easeMax      = 200,    -- texels whose colour, shine or surface still ease, of one film in one painting, at the most
	snap         = 1,      -- a canvas new to a film is there as it is (no easing) only until the cells asked for with it
	                       -- have been painted, or 0.5 s; 0: until the film's whole queue is empty, as before
	depthTone    = 1,      -- the liquid darkens what it lies on by its own depth, ever less for each more of it
	deepScale    = 0.05,   -- units: the depth of liquid that darkens by 1 - 1/e (0.02 made a run's core 0.83 of the
	                       -- soaked cloth beside it, a dark stripe once the cloth is lit as it should be; 0.05: 0.87)
	mottleLiquid = 0.6,    -- how much less of the cloth's patches shows in standing liquid than in the stain
	feather      = 1,      -- the film thins out at its outline: its colour goes over to the thin blood's on what it lies on
	featherW     = 0.25,   -- over how much of the share inside the outline
	-- (0.85 and (0.92, 0.40, 0.38) drew a salmon line round the stain on the white sweater: 1.3 times its red
	-- and 4 times its green, run p19 and the user's picture of 2026-10-17)
	featherAmt   = 0.4,    -- how far toward that at the outline itself
	featherTint  = { 0.85, 0.25, 0.25 },  -- what a thin film of blood leaves of the colour under it
	-- (2026-10-17, the "painted stripe": a cloth with no relief of its own (the white sweater, nine of the
	-- face textures) gave the stain the engine's "error" texture for relief, and the stain was lit twice as
	-- bright as it should be, brighter than the white cloth beside it: a glowing red band with the rightly
	-- lit liquid a dark stripe down its middle. Measured in the game: the same blood 114 red with that
	-- relief, 81 with a flat one.)
	clothRelief  = 1,      -- the stain takes the cloth's relief only where the cloth has one; else the body's own flat normal
	-- (2026-10-17, run p19f: on the white sweater the stain was one red from rim to rim, its knit faint streaks in it
	-- and its pattern gone: tape laid over the cloth, not blood in it)
	dye          = 0,      -- blood in cloth is a dye in it: the cloth's own texture shows through the stain and the liquid
	dyeShow      = 1.0,    -- ... in the stain, this share of it on light cloth (C.Film.clothShow without dye) ...
	dyeLiquid    = 0.6,    -- ... and under liquid standing on it (C.Film.clothShowWas without dye); brightness as before
	lerp         = 1,      -- the films nearest the eye move from one painting to the next in every frame (on the graphics card)
	lerpMax      = 4,      -- pictures made anew in one frame for that at the most, the nearest film's first
	lerpPool     = 12,     -- canvases that can be moving so at once (the earlier pictures they need are kept for them)
	waves        = 1,      -- the waves on running liquid are carried by the liquid itself (its age), not by a clock or a sum
	-- (At 0.14 and 0.24 crests a second the waves were four to eight times as long as a run on a chest: the whole
	-- run brightened and dimmed at once and nothing could be seen to travel. Measured on the bench, 2026-10-17.)
	waveHz       = { 1.0, 1.6 },  -- how many crests a second pass a place where the liquid runs, of the two trains
	waveTilt     = 0.10,   -- how steep they are at the most
	waveAcross   = 1,      -- a crest is one line across a run: its phase is the youngest running liquid beside the cell
	                       -- across the flow, and what fades a train is looked for along the flow only
	rippleNear   = 0.066,  -- s: how often the waves of a film nearer the eye than K.paintNearDist are painted (K.rippleEvery else)
	waveMinCells = 4,      -- cells: a train with crests closer than this is not drawn (the grid cannot show it)
	fade         = 1,      -- the near look comes and goes over a band of distance, with hysteresis: no switch in one frame
	nearIn       = 0.9,    -- a body comes near at this share of the near distance, and goes at the whole of it
	fadeFrom     = 0.75,   -- the highlight fades out from this share of the near distance to the whole of it
	fullKeep     = 40,     -- units: a film nearest the eye stays one this much further away
	pendPaint    = 1,      -- blood waiting at an edge to drop swells the film there
	pendMaxDepth = 0.04,   -- units: as much as it swells it at the most
	-- The film's simulation (cl_film.lua): only when its cells are painted again, and the cell cap
	touchByChange = 1,     -- a cell is painted again when what stands on it has changed, not only on a clock
	touchAbs     = 0.0012, -- units of change that count ...
	touchRel     = 0.12,   -- ... or this share of what stands there
	touchLiquidEdge = 1,   -- a cell that liquid comes to or leaves is painted first, as one that blood first comes to is
	fullIsWall   = 1,      -- a body with all the cells it may have: its fronts stand, they do not become edges that drip
	-- How far blood creeps through cloth from where liquid stands (2026-10-17, the "painted stripe"). It was a
	-- map of one patch noise clipped to two flat levels (a third of a cell, or four cells): along a low patch
	-- the stain was the liquid's own path, along a high one a block with sides parallel to the run, and the two
	-- met within a unit or two: "a line with a patch stuck to it", the same at every bleeding rate (the width
	-- of the margin followed that noise at 0.96 and the rate hardly at all; measured on the bench).
	reachField   = 1,      -- the reach from a field of its own, at two scales, linear, without flat levels ...
	reachPatch   = 0.5,    -- ... its patches this share of K.wickPatch across (and finer within them) ...
	-- (at 0.4 and 1.6 the stain of a standing chest wound was 26 to 61 % larger than before; at 0.25 and 1.1,
	-- 14 to 34 %, up to 43 % on another body's noise: measured on the bench)
	reachLo      = 0.25,   -- ... from this many times K.wickReach ...
	reachHi      = 1.1,    -- ... to this many
	reachContrast = 1.5,   -- ... spread out by this much (value noise keeps to the middle of its range; at 2 the
	                       -- margin's bulges stood out as a string of beads, run p19d)
	reachRun     = 1,      -- the margin widens with how far the blood feeding it has run (cloth below has more soaked
	                       -- cloth above it draining into it): the stain grows out of the run as one shape ...
	reachRunGrow = 0.9,    -- ... up to this much wider ...
	reachRunLen  = 30,     -- ... over about this many cells of the run ...
	reachNear    = 1.0,    -- ... and round the wound itself this much wider, where the cloth has drunk from the opening
	reachNearLen = 8,      -- ... over about this many cells from it (at 4 a waist formed under the head of the stain)
	reachNearRate = 0,     -- ... where the cloth is given blood this many times faster besides (blood out of a wound under
	                       -- clothing spreads between skin and cloth, and the cloth drinks it over all of that)
	-- Which way a run goes (2026-10-17, the "straight blood line"): down a wall whose grid stands upright the
	-- cell below was always the lowest of the four round a place, by a whole cell's fall against a fold's fifth
	-- of that to the side, and a run went straight down its column of cells, whatever the cloth's folds and
	-- the body's shape turned it toward.
	steer        = 0,      -- a front goes the way the floor falls, followed below the size of a cell (cl_film.lua Flow)
	steerMin     = 0.25,   -- ... where the floor falls by more than this a unit (less: near level, as before) ...
	steerHalf    = 0.75,   -- cells: ... and is held in the cells its line passes within this of
	-- (and the folds it follows: drawn out along the body's height, C.Film.reliefTall, their hollows ran down it as
	-- ruled lines, and so did a run that kept to one)
	foldWarp     = 0,      -- units: a fold wanders by about this much to either side as it hangs (0: straight, as before) ...
	foldWarpLen  = 6,      -- ... over about this many units of the body's height
	-- Where blood leaves a body (cl_filmpendant.lua, cl_film.lua Leave, cl_droplets.lua)
	pendant      = 1,      -- blood waiting to drop hangs from the body as a drop that swells and lets go
	pendDist     = 120,    -- units: nearer the eye than this
	pendMax      = 6,      -- drawn on one body at the most
	pendTau      = 0.06,   -- s: how fast what is drawn follows what waits
	pendSpawn    = 1,      -- a drop that leaves starts where its pendant hung, with that place's own velocity
	pendKick     = 0.5,    -- units a second it is given along the way it hung, besides
	pendExp      = 30,     -- its highlight's lobe (a drop is small: a narrower one is under a pixel and twinkles) ...
	pendBoost    = 0.8,    -- ... and how bright
	dropHyst     = 1,      -- a drop near the eye is drawn as a bead or as a streak with hysteresis, not flip by flip
	dropLightTau = 0.2,    -- s: how fast the light on a falling drop follows the light of the place it is in
	-- Ground pools (cl_pools.lua, cl_poolcanvas.lua, cl_render.lua)
	poolModelLight = 1,    -- a pool is lit as a model lying there would be (render.ComputeLighting), as the bodies are
	poolLightScale = 1.0,  -- ... times this
	poolLightEase = 0.25,  -- s: a pool's light follows a change of light over this
	poolDepthColour = 1,   -- a pool's colour by how deep its liquid is, as the film's is (one blood on body and floor)
	poolDeepScale = 0.08,  -- units: ... with a scale of its own (pools stand 0.08 to 0.22 deep: with the film's every pool
	                       -- would be the deepest colour all over)
	poolNoTint   = 1,      -- no tint of its own for a pool of liquid blood
	poolEdgePx   = 1,      -- a pool's outline is smoothed over about a screen pixel at any distance
	poolEdgeWidth = 0.75,  -- ... this many pixels
	poolBodyFill = 3,      -- cells: blood seen at a lying body's edge reaches this far under the body's outline (drawn only)
	poolFillShade = 0.75,  -- ... this much darker where the body and the floor meet
	-- Wounds (cl_woundfx.lua, cl_sources.lua)
	woundBlotFade = 1,     -- the blot round an opening fades where the film covers it: one blood, not a disc under it
	holeRed      = 0.22,   -- the blood in an opening: as dark as this share of its light (it was 0.34, as bright as the film;
	                       -- under 0.14 it is darker than the opening's own ground and the blood in it is gone)
	woundFade    = 1,      -- a wound's parts come and go over a band of distance, not in one frame
	woundBand    = 0.14,   -- ... each band as wide as this share of the distance it ends at
	woundLightTau = 0.3,   -- s: the light on a wound's mark follows the light of the place over this
	bindAtDeath  = 1,      -- a body that dies keeps its blood drawn in the frames before its corpse is known
}

if CLIENT then
	-- Is part `name` of phase 19 on? (abl_liquid_v19 and the part's own entry in C.V19)
	function C.V19On(name)
		local v = C.V19[name]
		return v ~= nil and v ~= 0 and v ~= false and C.cl.v19:GetBool()
	end
end

-- Phase 24 (2026-10-21): the bleeding system overhaul. Blood on a body moves, gathers, soaks and leaves as
-- one booked liquid, and is drawn as what it is: a filter over the body as the engine lit it, with the
-- liquid's own light and highlight on top, beads where thick liquid stands. It replaces phase 20's design,
-- which was configured here and never built (its flux was unstable: PHASE24_DESIGN.md F7).
-- C.P24On(name): a visual or physical part, on while the client's abl_liquid_p24 and abl_liquid_v19 are both
-- 1 and its own entry here is not 0; abl_liquid_p24 0 runs and draws everything exactly as phase 23 left it.
-- C.P24Fix(name): an accounting fix (blood that was made or lost outside the books), on while its entry is not
-- 0, whatever abl_liquid_p24 says. What was wrong and why each part is what it is:
-- docs/blood_upgrade/PHASE24_DESIGN.md; what was measured: docs/blood_upgrade/PHASE24_BLEEDING.md. The
-- numbers below are where each part starts; the bench and the game set them.
C.P24 = {
	-- How liquid moves over a body (cl_film.lua)
	sweep        = 1,      -- liquid moves in one sweep from the highest cell down, each cell giving through all its faces
	                       -- at once and keeping what its own outflow leaves it (implicit: stable at any flow)
	steer        = 1,      -- a front opens the dry cell the way the surface falls, not the one down its texture column
	                       -- (phase 19's steer, carried into the sweep: without it a tilted body's run stays in its column)
	noShed       = 1,      -- a sloping place (not an underside, not a floor) never sheds what stands on it as drops:
	steepSafe    = 0.12,   -- units: liquid deeper than this opens its steepest dry face downhill (booked as flow)
	het          = 1,      -- the surface's own unevenness, fixed to the body in its own space: where it holds a front
	hetScale     = 2.5,    -- back and where it keeps liquid; its patches lie this many cells apart ...
	hetContrast  = 2.5,    -- ... value noise spread out by this, clamped ...
	hetPin       = 0.5,    -- ... a dry place holds a front back by 2^(hetPin (2f - 1)) times the film's own pinning ...
	hetRet       = 0.5,    -- ... and keeps 2^(hetRet (2f - 1)) times the film's retention
	pocketSkin   = 0.003,  -- units: a hollow of skin holds up to this much more ...
	pocketCloth  = 0.02,   -- ... of cloth this much ...
	pocketSteep  = 0.25,   -- ... a hollow on a vertical place this share of it (a meniscus, not a basin)
	sill         = 1,      -- folds of cloth stand across the way down in places and dam what runs to them ...
	sillMax      = 0.04,   -- units: ... up to this high where cloth bunches (a garment's lower edge, its gaps, the waist)
	sillFrom     = 0.55,   -- ... where their field is above this (0..1) ...
	sillTall     = 3,      -- ... drawn out this many times across the way down as along it ...
	sillBunch    = 0.3,    -- ... and this share of that elsewhere
	capPocket    = 1,      -- a hollow's pocket and a fold's dam are added to what a place may hold before it sheds
	dryRun       = 1,      -- liquid that moves leaves nothing dried under it (its solids go on with it); it dries once it
	                       -- stands
	recede       = 1,      -- liquid a run has left behind is drawn into the run beside it after this many quiet steps
	recedeSteps  = 10,     -- (a receding contact line: a stopped or pulsed run breaks into pieces, it does not stay a line)
	seamFacing   = 1,      -- a seam or a gap joins only surfaces that face the same way and the place the blood comes from
	detach       = 1,      -- blood waiting at an endpoint lets go when its weight beats what the place holds by how it
	                       -- faces and how fast it moves, not after a fixed wait
	trueArea     = 1,      -- a cell's area is the area it really covers on the model (face cells 0.12-0.70 of nominal)
	-- Blood in cloth (cl_film.lua)
	soakDepth    = 0.024,  -- units of blood a full T-shirt's cloth holds (0.61 mm, 0.06 ml a square centimetre) ...
	garments     = {       -- ... times this for the garment whose name has the word (unknown cloth: `other`)
		sweater = 2.5, hoodie = 2.5, fleece = 2.5, knit = 2.5, wool = 2.5, jumper = 2.5,
		shirt = 1.0, tee = 1.0, jersey = 1.0, formal = 1.0, suit = 1.0,
		denim = 1.0, jean = 1.0, pants = 1.0, trouser = 1.0,
		leather = 0, latex = 0, armor = 0, armour = 0, vest = 0, rubber = 0,
		other = 1.5,
	},
	soakStep     = 1,      -- cloth drinks the liquid on it at every step of the flow, not every half second ...
	soakTau      = 0.35,   -- s: ... dry cloth takes up what lies on it over this (slower as it fills)
	capWick      = 1,      -- blood creeps on through cloth by how full it is here and there and by gravity, as far as
	                       -- what has come takes it: no reach, no clock (Wick's reach, growK, reachRun and hemK not used)
	wickD        = 0.02,   -- units^2 a second: how fast full cloth passes blood on to cloth beside it ...
	wickM        = 3,      -- ... times its fullness to this power (cloth half full passes on an eighth as much) ...
	wickG        = 0.4,    -- ... downhill more, uphill less, by this times the fall over a cell ...
	wickFrom     = 0.02,   -- ... from this fullness on ...
	wickSet      = 20,     -- ... until this many seconds after the cell last got blood from outside (it sets) ...
	wickInherit  = 1,      -- ... a cell wetted by creeping keeps the time its giver last got blood (it does not restart it)
	wickMin      = 1e-4,   -- ... and passes nothing smaller than this share of the smaller cell's capacity
	underCloth   = 1,      -- a wound under cloth gives its blood into the cloth round the opening first; only what the
	                       -- cloth cannot take up there comes through onto it as liquid ...
	underShare   = 0.8,    -- ... at most this share of what the wound gives (pressure in the gap grows with the flow) ...
	underFall    = 4,      -- cells: ... half of that when the cloth not yet full is this far off ...
	underReach   = 12,     -- cells: ... and no further than this ...
	underFull    = 0.97,   -- ... through cloth fuller than this ...
	underUp      = 1.5,    -- ... a step uphill costing this much more, ...
	underDown    = 0.6,    -- ... a step downhill this much less, ...
	underWkMin   = 0.25,   -- ... and the cloth's own drawing power counted no lower than this ...
	underNodes   = 100,    -- ... found by a search of at most this many cells ...
	underEvery   = 5,      -- ... made again every this many steps
	inner        = 1,      -- blood that comes through under cloth runs on between the skin and the cloth (a layer of its
	                       -- own, moved by the same sweep, slower) and soaks the cloth above it from inside; it leaves at
	                       -- the garment's lower edge or a gap, and comes through onto the cloth only where the gap is full
	innerCap     = 0.02,   -- units: what the gap between skin and cloth holds before blood comes through ...
	innerK       = 0.25,   -- ... and how freely it moves there, against liquid on the open surface
	-- How it is drawn (cl_filmdraw.lua)
	dye          = 1,      -- blood is a filter over the body as the engine lit it (Beer-Lambert per channel): the cloth's
	                       -- knit, pattern and light stay; no opaque paint, no cut edge
	dyeR         = 0.9,    -- what a full cloth's worth of blood takes of red, green and blue (blue more than green: the
	dyeG         = 16,     -- Soret band; thin margins read orange-red, not pink) ...
	dyeB         = 22,
	dyeFloor     = 0.01,   -- ... down to this share at the most (full soak stays at the palette's crimson) ...
	dyeDryR      = 2.4,    -- ... and dried blood this many times as much, per channel (browner) ...
	dyeDryG      = 0.95,
	dyeDryB      = 1.2,
	dyeEdge      = 0.08,   -- ... fading in over this much fullness at a soaked edge ...
	dyeSharp     = 0.5,    -- ... with a margin this steep (0 soft .. 1 a cut) ...
	dyeDark      = 0.35,   -- ... and on dark cloth this much of the blood's own colour besides (a tinge and a sheen)
	dyeForce     = nil,    -- (developer) "modulate", "blend" or "translucent": the drawing path, whatever the probe found
	liquid       = 1,      -- standing liquid absorbs as deep as it is and sends back its own light; its highlight ends
	liqOpaque    = 0.035,  -- inside its outline. Units: its own light is 1 - 1/e of full at this depth ...
	liqLenR      = 0.08,   -- ... and red, green and blue fall to 1/e through this much of it
	liqLenG      = 0.0035,
	liqLenB      = 0.005,
	ease         = 0.08,   -- s: what the nearest films show comes to their cells over this
	env          = 0,      -- the liquid mirrors the place's cubemap (masked by where it stands) ...
	envTint      = 0.05,   -- ... this much
	-- Beads (cl_filmbead.lua): thick liquid at a high point of its own, where it slows, stands or heads a run, drawn
	-- as a lens of its volume (a steady rivulet is not beaded)
	beads        = 1,
	beadAngle    = 50,     -- degrees: the lens's contact angle
	beadMin      = 0.025,  -- units: liquid at least this deep
	beadMax      = 8,      -- lenses a body at the most
	-- Accounting (C.P24Fix: on whatever abl_liquid_p24 says). They land at 0 and are turned on together in one
	-- announced sync, with the pool session's regression plan around it (they change what reaches the pools).
	blot         = 0,      -- a body resting on a floor leaves there only blood it really gives up from its film
	spurtBank    = 0,      -- spurts and jolts are paid from the wound's own flow and booked
	unseen       = 0,      -- a body not in view deposits nothing; a far body's deposit lands under its wound
	dripBook     = 0,      -- blood let out with no surface model to take it is booked, not dropped
	freeBook     = 0,      -- a film that is let go books out its cloth and dried blood with its liquid
	carry        = 0,      -- a body whose surface model changes (clothes, bodygroups) keeps its blood on the new one
	evict        = 0,      -- when the films' cells near their cap, the oldest unseen idle corpse films are let go (booked)
	track        = 0,      -- (developer) count new blood and arrivals into pools by the file and line that made them
}

if CLIENT then
	-- Is part `name` of phase 24 on? (abl_liquid_p24, abl_liquid_v19 and the part's own entry in C.P24)
	function C.P24On(name)
		local v = C.P24[name]
		local cv = C.cl.p24
		return v ~= nil and v ~= 0 and v ~= false and cv ~= nil and cv:GetBool() and C.cl.v19:GetBool()
	end
end
-- Is the accounting fix `name` on? (its entry in C.P24 only)
function C.P24Fix(name)
	local v = C.P24[name]
	return v ~= nil and v ~= 0 and v ~= false
end

-- Phase 21 (2026-10-20): ground pools that are the blood that has reached them, shown once, and that
-- mirror what stands over them. Every part is on while the client's abl_pool_p21 is 1 and its own entry
-- here is not 0 (C.P21On); abl_pool_p21 0 runs and draws the pools exactly as phase 20 left them. What
-- was wrong and what each part does: docs/blood_upgrade/PHASE21_POOLS.md.
-- (What was there, measured 2026-10-20: drops that collect toward a pool showed as stains that carry
-- their liquid, and when they had brought 2 ml a pool of all of it appeared at their middle while the
-- stains went on showing the same liquid beside and under it; blood that collected up to 10 units from
-- one of its character's pools was laid down at that pool's nearest edge; a pool's wet surface mirrored
-- a blurred cubemap at most 14 %.)
C.P21 = {
	-- Where blood lands (cl_pools.lua, P.Deposit and P.Create; cl_impacts.lua; cl_groundstains.lua)
	seedPoints   = 1,      -- drops collecting toward a pool keep where each landed: the pool begins as their spots, each
	                       -- with its own blood, joined by the liquid's own flow (not one disc of all of it at their middle)
	seedPointMax = 24,     -- places kept for one collecting cell (more: what lands goes to the nearest one kept) ...
	seedPointJoin = 0.45,  -- ... and units within which two landings count as one place
	handover     = 1,      -- a drop's stain gives its liquid to the pool that takes its blood: the stain stays as what
	                       -- the floor shows, its body of liquid goes (no second picture of the same blood)
	lattice      = 1,      -- blood that lands within latticeReach of a pool's liquid on its surface joins that liquid
	                       -- where it landed (a spot of its own on the pool's lattice until the liquid reaches it), and
	                       -- is not gathered to the pool's nearest edge from up to C.Pool.gather away
	latticeReach = 4,      -- units from the pool's wet cells
	exitRun      = 1,      -- a pool on a slope hands what crosses a line downhill to a stream only where such a stream
	                       -- runs (cl_flowworld.lua: the drive of exitVol ml on that slope above what the surface holds a
	                       -- stream back with); on a gentler slope the pool's own liquid goes on downhill. And blood that
	                       -- comes down past that line never goes back into the pool above it. (A stream that could not
	                       -- run stopped where it began, inside the pool, and was laid back into it: on a plate tilted
	                       -- 5 degrees 440 ml went round pool -> stream -> pool in 24 s while 36 ml were poured.)
	exitVol      = 0.4,    -- ml: what the pool hands to a stream at a time (cl_pools.lua, SimSinks)
	-- How a pool looks (cl_pools.lua P.Draw; cl_poolmirror.lua)
	mirror       = 1,      -- the wet surface of the nearest pools mirrors what stands over it (the scene seen from below
	                       -- the floor, drawn into a target), as much as Fresnel says at each place of the screen
	mirrorDist   = 700,    -- units: pools nearer than this (and in view) are mirrored ...
	mirrorPx     = 30,     -- ... that are this many pixels across on screen at least (smaller: the cubemap, as before)
	mirrorQuality = 3,     -- abl_quality from which the mirror is drawn (it is a second view of the scene: about 0.5 to
	                       -- 0.9 ms a frame on gm_construct on the machine it was made on, more on a busy map)
	mirrorScale  = 0.5,    -- the mirror's picture: this share of the screen's width and height
	mirrorMax    = 0.85,   -- the most of it a place shows (a liquid surface is a dielectric: Fresnel at a glancing view)
	mirrorMs     = 0.8,    -- ms a view of the mirror may cost on average before it is drawn only every second frame (and
	                       -- every third at twice that, every fourth at three times; every second while the game's frame
	                       -- takes over 1/55 s, every third over 1/45 s or while the load governor has scaled the
	                       -- addon's work under three quarters)
	mirrorFrameOff = 1 / 40, -- s: a game frame slower than this (smoothed) for a second, or the governor under a half for
	                       -- a second, stops the mirror (the cubemap as before) ...
	mirrorFrameOn = 1 / 52, -- ... until frames have been quicker than this for a second, and 4 s have passed (8, 16, ...
	                       -- up to 64 when it had to stop again within 30 s of coming back)
	mirrorEntities = false, -- whether characters, ragdolls and props are mirrored too (each is drawn again with all that
	                       -- Z-City draws for it: 3.9 ms a frame with five bots about, against 0.6 for the world alone;
	                       -- off, the map's static props are left out with them)
	-- How a stream on the world looks (cl_flowdraw.lua, FD.Source; cl_flowworld.lua, FW.Draw)
	streamLiquid = 1,      -- a running stream on a floor, slope or wall is drawn as the pools' liquid: the colour of
	                       -- C.Pool.palette by its depth (rim, body, deep, by the pools' own rule with
	                       -- C.V19.poolDeepScale), lit as a pool there is lit, over what it has left on the surface (not
	                       -- over itself again as a stain), and mirroring as much as a pool does. (What was there,
	                       -- measured 2026-10-20 on the plate tilted 12 degrees, run p21s_base: a stream 0.3 units wide
	                       -- and 0.04 deep had its own colour drawn at 0.58 of the light, over the stain and liquid
	                       -- filters both at their darkest, under a grey reflection of the sky three times a pool's: a
	                       -- brown-grey line, (95, 50, 50) in the picture where the pool it left was (136, 20, 21).)
	streamSheen  = 1.0,    -- ... the mirrored surroundings on it, in place of C.Flow.sheenK (3, for a stream on a body,
	                       -- whose rounded surface faces the sky somewhere; a stream on a floor is as flat as a pool)
	-- How a stream on the world runs (cl_flowworld.lua, StepHead; cl_flowcore.lua, StepChannel and FC.Laid)
	streamHead   = 1,      -- a stream on the world carries its blood in its own bed and its head stays a bead: a head
	                       -- takes from the stream behind it no more than its bead (streamBead, or what it needs to run
	                       -- where it is), unless more stands at the stream's end than its bed holds (a burst: that goes
	                       -- on into the head, which grows heavy), and lays down only what it holds beyond its bead; a
	                       -- hanging head that holds more than two drops lets go the sooner the more it holds, all of it
	                       -- but one drop, so that one a stream feeds drips as fast as it is fed; a finger that a heavy
	                       -- head splits off takes its share of that head and nothing of the stream after it. (What was
	                       -- there, measured 2026-10-20 on the plate tilted 12 degrees, run p21s_after: a head that a
	                       -- pool fed took all that came down and laid at most 0.13 ml a node while 1.3 to 1.5 ml/s
	                       -- arrived; the heads ran at about 1 ml, five fingers split off in the first 16 s and each
	                       -- finger's channel went on taking 40 % of what stood at the node it left: six channels side
	                       -- by side. At the plate's edge the heads hung with 1.9 to 7.4 ml, letting go about 0.06 ml
	                       -- every 0.25 to 1.2 s.)
	streamBead   = 0.25,   -- ml: the bead a running head is at most (C.Flow.headShow: no head is drawn bigger) ...
	streamBeadRun = 1.15,  -- ... or this many times what it needs to run where it is (its weight along the surface against
	                       -- C.Runoff.adhesion), whichever is more (0.44 ml on dry tile tilted 12 degrees)
}

if CLIENT then
	-- Is part `name` of phase 21 on? (abl_pool_p21 and the part's own entry in C.P21)
	function C.P21On(name)
		local v = C.P21[name]
		return v ~= nil and v ~= 0 and v ~= false and C.cl.p21:GetBool()
	end
end

-- Phase 22 (2026-10-20): pools as the user's reference shows them, made by the liquid itself: one
-- irregular, connected sheet with darker parts where it stands deeper. Every part is on while the
-- client's abl_pool_p22 is 1 and its own entry here is not 0 (C.P22On); abl_pool_p22 0 is phase 21.
-- docs/blood_upgrade/PHASE22_POOL_LOOK.md.
-- (What was there, measured 2026-10-20: the floor under a pool's lattice is level unless the world's own
-- geometry is not, so a pool at rest stood one depth all over and was one colour all over, a gel; its
-- outline's irregularity came from the contact line's pinning alone.)
C.P22 = {
	-- The floor under the liquid (cl_poolsim.lua, PS.Relief / PS.SetGround)
	relief       = 1,      -- the floor's own unevenness under a pool: a height field fixed in the world (about 6, 2.5
	                       -- and 1 units across), as high as below by surface. The liquid fills its hollows and stands
	                       -- thinner on its rises: darker where it is deeper, an edge that goes round the rises
	reliefAmp    = {       -- units (1 = 25.4 mm): how far the floor rises and falls about its mean, at the most
		default = 0.05, concrete = 0.08, stone = 0.09, wood = 0.035, tile = 0.012, metal = 0.008, plastic = 0.008,
		glass = 0.003, dirt = 0.1, grass = 0.12, fabric = 0.05, flesh = 0.02, snow = 0.07,
	},
	-- The colour of the liquid by how deep it stands (cl_poolcanvas.lua, Cell)
	depthTone    = 1,      -- the wet layer's colour by how full it stands, in films of its surface (the depth a pool
	                       -- rests at there, C.Surfaces film): the thin film's colour (C.Pool.palette) up to
	                       -- toneThin, the body's at toneBody, deepColour from toneDeep on, eased between. Deeper
	                       -- blood is darker: where the floor's hollows hold more the pool is darker, where it
	                       -- arrives and heaps up too. (By the phase-19 rule in units, 1 - exp(-depth / 0.08) from
	                       -- thin over body to deep, a pool at rest 1.6 to 2.7 mm deep on concrete was one colour:
	                       -- poolbench, 80 ml). How full a cell stands: with its wet neighbours' (SmoothFull: by
	                       -- each cell alone, a step in depth came out as a comb of lighter teeth a cell apart)
	toneThin     = 0.35,   -- films
	toneBody     = 0.85,   -- films (about where a pool at rest stands: its colour on average is the body's)
	toneDeep     = 1.25,   -- films
	deepColour   = { 68, 6, 9 },  -- sRGB 0..255, before light: the deepest blood of a pool (a little darker than the palette's
	                       -- wetDeep; at (50, 4, 7) and (56, 5, 8) the deepest parts came out red 52-63, darker than the
	                       -- reference's darkest, about 70-77: runs p22_e, p22_sun)
	-- Where the sun is mirrored in the meniscus (cl_poolcanvas.lua, SunRim; cl_pools.lua works out the way)
	sunRim       = 1,      -- the curved edge of the liquid mirrors the sun where its slope faces the half-way
	                       -- direction between the sun and the eye: a thin bright line along that part of the
	                       -- outline, while the pool's middle is in the sun (the level part's own glint is
	                       -- C.Pool.glint's, where the half-way direction stands upright)
	sunRimK      = 0.55,   -- how bright (0..1 of white in the pool's colour, before its light)
	sunRimCut    = 0.8,    -- only where the edge faces the half-way direction within about 35 degrees (the slope's
	                       -- band less this, scaled back to 1): a glint along part of the edge, not a line round it
	sunRimTilt   = { 7, 14, 45, 60 },  -- degrees the half-way direction leans from upright: from nothing at the
	                       -- first to full at the second, full to the third, nothing at the fourth (a meniscus
	                       -- leans out from level at its inner edge to about 60 degrees at the contact line)
	sunRimBreak  = 0.44,   -- the line broken into short lights where the contact line, pinned grain by grain, turns
	                       -- away from the sun (finer than the lattice draws it): the pools' tiled noise laid in the
	                       -- world, dark below this, full an eighth above it (two fifths of the lit stretch stays
	                       -- dark, an eighth is full, lights 8 to 20 mm long). 0: one unbroken line (run p22_f: it
	                       -- read as a stroke along the pool's sunlit side)
	sunRimWorld  = 5,      -- units a tile of that noise
	-- The edge and the mirror (cl_poolcanvas.lua, FilterPage; cl_poolmirror.lua, M.Composite)
	edgeFilter   = 1,      -- the layer's red filter on the floor reaches all the way to the outline, under the band
	                       -- where the colour is half there: the thin edge is red film over the floor, not a pink
	                       -- line (the filter came in over a little way inside, and the first pixels inside the
	                       -- outline were half red, half bare floor: (149, 106, 99) between (100, 36, 48) and the
	                       -- floor's (185, 182, 165), run p22_c; the reference's edge goes 88 -> 142 -> 177 in red)
	mirrorK      = 0.5,    -- the share of Fresnel's reflectance the mirror lays over a pool: the user's reference
	                       -- keeps its reflections restrained (warm, blue no more than green inside the pool), and
	                       -- the whole of it laid a lilac wash over the blood under a bright sky (green 35, blue 48
	                       -- where the palette's are 9 and 13, run p22_c)
	-- Where a stream's blood comes to lie (cl_pools.lua, P.Deposit)
	landOn       = 1,      -- blood that a stream or a seep brings lies on the surface under where it stops, found
	                       -- by a short trace: a stream that runs down a ramp onto the level brings the ramp's
	                       -- normal and entity with it, and the pool made with them lay in the ramp's plane through
	                       -- the level plate, most of it under the plate's top (run p22_c: two pools of 28 and 15 ml
	                       -- seen as dots at the ramp's foot)
}

if CLIENT then
	-- Is part `name` of phase 22 on? (abl_pool_p22 and the part's own entry in C.P22)
	function C.P22On(name)
		local v = C.P22[name]
		return v ~= nil and v ~= 0 and v ~= false and C.cl.p22:GetBool()
	end
end

-- Phase 23 (2026-10-20): the quality lock. What the pools show at every distance and angle, measured
-- against the user's brief (smooth outline, restrained wet highlights, no artificial outline). Every
-- part is on while the client's abl_pool_p23 is 1 and its own entry here is not 0 (C.P23On);
-- abl_pool_p23 0 is phase 22. docs/blood_upgrade/PHASE23_POOL_QUALITY.md.
-- (What was there, measured 2026-10-20, run p23_base: seen low, 9 units over the floor and 46 off,
-- the pool's near edge was a saw of one-pixel steps; close up and from most sides, a white line
-- ran along a third of its outline, a few pixels inside its red rim.)
C.P23 = {
	-- The outline's soft edge (cl_pools.lua, PoolEdge)
	edgeAA       = 1,      -- the window over which the outline goes from nothing to the layer is set for the edges
	                       -- the view foreshortens most, the near and far ones: a screen pixel there spans 1 / cos
	                       -- of the view's angle more of the floor than at the sides. (Set for the mean of the two,
	                       -- 1 / sqrt(cos), it was a third of a pixel at the near edge seen 11 degrees over the floor:
	                       -- the alpha's cut stepped a pixel at a time along it, run p23_base, picture pk_low)
	edgeWidth    = 1.0,    -- ... that many screen pixels (C.V19.poolEdgeWidth, 0.75, without edgeAA)
	-- The meniscus's light (cl_poolcanvas.lua, SunRim and RimGlow; cl_pools.lua, SunRimWay)
	meniscus     = 1,      -- the sun in the meniscus and the far slope's light restrained, the sun's line not broken
	                       -- by noise: a faint warm line where the edge faces the sun, a fainter one along the far
	                       -- side. (At C.P22.sunRimK 0.55 and C.Pool.sim.rimGlow 0.3 they drew a white line along a
	                       -- third of the outline and a light one along the far side, read as a painted outline:
	                       -- run p23_rimab, every view; at a fifth, a sheen on the edge)
	sunRimK      = 0.18,   -- the sun's line (C.P22.sunRimK without this part)
	rimGlow      = 0.18,   -- the far slope's light (C.Pool.sim.rimGlow without this part)
	-- The colour by fullness (cl_poolcanvas.lua, BuildPatch and Cell; C.P22.depthTone)
	tone         = 1,      -- the stops moved so that a pool at rest, about a film deep, is the palette's body colour,
	                       -- darker only where it stands deeper (a heap where blood arrives, the floor's hollows), and
	                       -- the wet colours lifted by `lift`. (With C.P22's stops a pool at rest stood two fifths of
	                       -- the way from body to deep: in the sun its middle was (69, 13, 22) where the reference's is
	                       -- (120, 44, 38), run p23_rimab, close view. With these, red 90 to 92 in the middle, 78 to
	                       -- 103 between the 10th and 90th percentile; lifted by 1.12, 102 to 105, which began to read
	                       -- as red paint: run p23_toneab)
	toneThin     = 0.35,   -- films
	toneBody     = 1.0,    -- films
	toneDeep     = 1.7,    -- films
	deepColour   = { 70, 6, 9 },
	lift         = 1.0,    -- the thin film's, the body's and the deep colour, times this
	-- The red filter on the floor at the thin edge (cl_pools.lua, P.Draw)
	filterView   = 1,      -- seen at a glancing angle the floor under the thin edge is gone: what a film of liquid
	                       -- mirrors rises toward its surface's glancing angle (Fresnel) and what it lets through falls
	                       -- with the longer way through it. The filter fades from all of it at filterView1 (cos of the
	                       -- view's angle to the floor's normal) to none at filterView0. (Laid at full there, the
	                       -- bright grains of a concrete floor showed through the edge as single scarlet pixels, a
	                       -- saw along the near edge seen 11 degrees over the floor: run p23_rimab, view low; gone
	                       -- with the filter faded, as with none at all, run p23_toneab, PNG edge_low_*)
	filterView0  = 0.12,
	filterView1  = 0.35,
	-- The lattice's resolution (cl_pools.lua, SimNMax)
	fineCells    = 1,      -- more cells a side before a pool's cells grow twice as wide: a pool keeps cells of 0.4
	                       -- units (1 cm) up to about 20 units across. (With 36 or 40, a stream's pool 17 units long on
	                       -- a 5-degree plate was laid in cells of 0.8 units: two cells wide, drawn as a bar of one
	                       -- width with round ends, run p23_base, picture ps05_016s)
	fineN        = { 52, 44, 30, 24 },  -- at quality 3 and more, 2, 1, 0 (52: the patch, 54 cells with its ring, still
	                       -- has two texels a cell in its 128-texel target, cl_poolcanvas.lua)
	-- Where two bodies of liquid meet (cl_poolsim.lua, Sweep)
	bridge       = 1,      -- a dry cell with liquid on two opposite sides, a strip one cell wide between two bodies
	                       -- of liquid, holds back bridgeK of what the floor there would: the outline is drawn over
	                       -- such a strip anyway (it is narrower than the drawing can show), and the two menisci press
	                       -- on it from both sides. (Two pools that met kept a line of such cells between them, pinned
	                       -- at 1.75 films with 1.1 films of head on either side: one pool on the screen, two depths
	                       -- and a seam along a row of cells, runs p23_val and p23_mergedbg5)
	bridgeK      = 0.35,
	-- A slope's contact line (cl_pools.lua, SimInit)
	slopePin     = 1,      -- a pool on a slope (sine over slopePinFrom) holds its contact line at least as unevenly as
	                       -- slopePinAmp (C.Pool.sim.rough): on an even surface a stream's pool down a gentle slope was a
	                       -- straight band of one width (run p23_final, 5-degree plate). A floor's unevenness under the
	                       -- liquid does not change that (tile relief raised to 0.04: width cv 0.00), its pinning does
	                       -- (rough 1.2: cv 0.21-0.27, the middle wandering 0.15-0.19 units; phase 24's bench, audit H).
	                       -- A model of what wets a slope unevenly below the lattice (dust, the grain's direction, the
	                       -- stream's own wobble), not a measured surface; level pools are unchanged.
	slopePinFrom = 0.05,   -- sine of the slope (about 3 degrees)
	slopePinAmp  = 0.9,
	-- Where a lying body's blood seeps onto the floor (cl_pools.lua, P.Deposit)
	seepStart    = 0.2,    -- ml in a cell from which seep makes a pool, as runoff does (C.Pool.minVolumeRunoff); drops
	                       -- need C.Pool.minVolume (2 ml). (At 2 ml, in cells that forget with tau 45 s, a seep slower
	                       -- than about 0.044 ml/s never showed: phase 24's audit, run p24_base, scene acc_lying)
}

if CLIENT then
	-- Is part `name` of phase 23 on? (abl_pool_p23 and the part's own entry in C.P23)
	function C.P23On(name)
		local v = C.P23[name]
		return v ~= nil and v ~= 0 and v ~= false and C.cl.p23:GetBool()
	end
end

-- world runoff
C.Runoff = {
	adhesion     = 0.20,   -- ~0.1 ml needed to run down a vertical concrete wall
	speed        = 5.5,
	filmLoss     = 0.008,
	pendant      = 0.06,
	checkDist    = 1.4,
	trailSpacing = 1.1,
	trailPoints  = 40,
	offset       = 0.12,
	coag         = 75,     -- seconds for flowing blood to double its effective viscosity (clotting)
	forkVol      = 0.9,    -- ml above which a running rivulet may split into two fingers
	forkRate     = 0.25,   -- forks per second per ml above forkVol
	collect      = 0.6,    -- ml a stopped rivulet needs on a gentle slope to gather into a pool
}

-- pools (cl_pools.lua: simulation, cl_poolcanvas.lua: render-target canvases)
C.Pool = {
	minVolume   = 2.0,     -- ml collected in one 8-unit cell (decaying) before it becomes a pool
	minVolumeRunoff = 0.2, -- the same for blood that a stream brings (the pool begins where the stream arrives)
	mergeFactor = 0.9,     -- pools merge when their outlines come this close (fraction of the reach)
	gather      = 10,      -- units: blood that has collected this close to one of its character's pools goes into that pool
	seepShare   = true,    -- seep that lies in the cells beside a cell counts toward its pool (cl_pools.lua, TakeBeside)
	leaveFade   = 2.5,     -- seconds over which a pool that makes way for another fades out
	leaveMax    = 6,       -- pools on their way out at once at the most (one more: the one longest so goes at once)
	glintMax    = 0.3,     -- the most of the sun's glint a pool shows (its halo is two thirds of this over the whole
	                       -- pool when the eye is in the sun's mirror direction: at 0.75 the pool was a pale plate)
	overflow    = 0.05,    -- fraction of the pool per second (per unit of overshoot) running over a ledge
	sheen       = 0.9,     -- strength of the view-dependent wet reflection on fresh pools
	envStrength = 1.0,     -- brightness of the mirrored cubemap (abl_pool_envmap 1), as the map stores it. How much
	                       -- of it a pool shows is Fresnel's reflectance (2 % from above, 40 % at ten degrees),
	                       -- taking the place of that much of the blood's own colour
	envSaturation = "[0.35 0.35 0.35]",  -- how much of the mirrored surroundings' colour is kept: a low, blurred cubemap
	                       -- of a blue sky laid over dark red is violet, which no pool of blood is; what the eye
	                       -- takes from a real one is a pale sheen
	mirrorMax   = 0.14,    -- the most of the cubemap a level pool shows, however low the view (an engine limit:
	                       -- see cl_pools.lua, P.Draw)
	slopeRun    = 0.08,    -- sin(slope) above which pools feed runoff
	slopeCreep  = 0.08,    -- sin(slope) above which a wet pool stretches / pushes lobes downhill
	life        = 900,     -- seconds a dried pool stays before fading
	fade        = 25,
	dryBase     = 240,     -- seconds to dry at ~10 ml on concrete
	offset      = 0.12,    -- units above the floor (plus the traced ground relief under the canvas)
	-- field stamps per pool
	maxBlobs    = 16,      -- body, arrival lobes, feeders, necks
	maxSats     = 12,      -- satellite droplet / spatter stamps
	probeDirs   = 16,      -- directions probed for walls and ledges
	spreadTau   = 1.1,     -- s: viscous spreading time scale (grows with the radius)
	matureTau   = 2.5,     -- s: the spreading front works through the stamp's shape in about this long
	-- canvas (one render-target slot per pool, rebuilt when the pool changes)
	edgeNoise   = 0.075,   -- field units of tiled noise added before thresholding (irregular rim)
	noiseWorld  = 26,      -- units per edge-noise / mottling tile
	sheenWorld  = 40,      -- units per reflection pattern tile (abl_pool_envmap 0)
	crackWorld  = 9,       -- units per craquelure tile of old dried pools
	wetRamp     = 0.125,   -- field units over which the wet core fades into the dried margin
	maxCanvas   = 110,     -- units: largest canvas half-size
	-- colours (sRGB 0..255, before light). The rim is the thin film at the edge (drawn translucent,
	-- the floor shows through it), the body the even thick layer: wet blood is a deep burgundy-crimson,
	-- ageing darkens it, dried blood is a dark red-brown with a darker drying ring.
	-- (2026-10-14, phase 18: fresh blood a little richer and less black. A pool beside a lying body
	-- read as near-black maroon next to the red of the run that fed it, a step of 1.7 times in red
	-- where the run met the pool (run p18a); at a standing body's feet these give 70 of red in the
	-- picture where the earlier ones gave 66 (run p18b, scene acc_look). Before: wetFresh rim 108 15 18,
	-- body 80 6 11; thin rim 116 18 21, body 92 9 13; wetDeep 58 3 7.)
	palette = {
		wetFresh = { rim = { 112, 16, 19 }, body = { 92, 9, 13 } },
		wetAged  = { rim = { 106, 18, 20 }, body = { 64, 5, 9 } },
		dryFresh = { rim = { 52, 17, 14 },  body = { 72, 25, 19 } },
		dryOld   = { rim = { 46, 17, 14 },  body = { 66, 27, 21 } },
		thin     = { rim = { 118, 19, 22 }, body = { 98, 11, 14 } },    -- thin film on smooth floors
		-- a liquid pool is coloured by its depth cell by cell: from the rim colour of its state (a thin
		-- film) over the body colour (one film deep) to these (deeper than that), dried blood from
		-- dryThin over dryBody to dryDeep
		wetDeep  = { 72, 6, 9 },
		dryThin  = { 83, 45, 41 },      -- (as a filter: half the red, a quarter of the green, a fifth of the blue)
		dryBody  = { 84, 35, 23 },
		dryDeep  = { 52, 21, 15 },
	},
	rimTranslucency = 0.5,  -- page A's alpha at the outline (it rises to 1 with the layer's depth)
	rimBand     = 0,        -- ... and how far above that the blood's own colour is fully there (nothing: a band
	                        -- here shows the filter alone as a scarlet outline)
	-- what a thin layer lets through, as a multiple of its colour in linear light (red, green,
	-- blue): the colour of a thin wet film (108, 15, 18) times this is 0.85, 0.045, 0.05; a film
	-- of fresh blood passes nearly all red and a twentieth of green and blue. The thin film's own
	-- colour is dark for that reason: what makes thin blood bright on a light floor is the floor,
	-- through the filter, and on a dark floor it is dark.
	filterGain  = { 5.7, 9.4, 8.3 },
	glint       = 0.5,      -- strength of the sun's reflection on wet pools (the texture doubles it: at 0.5 the
	                        -- core is full white, the halo round it a third and less)
	-- the liquid (cl_poolsim.lua)
	sim = {
		res       = 0.25,   -- the film a cell keeps when blood runs off it, in films of the surface
		memory    = 0.35,   -- a cell that has been wet holds the contact line back this much of what a dry one does
		-- roughness: how much more than one film the roughest spots of a floor hold back
		rough     = { default = 0.9, concrete = 1.2, metal = 0.3, wood = 1.0, glass = 0.2, tile = 0.4, stone = 1.2, plastic = 0.3,
		              dirt = 1.6, grass = 1.8, fabric = 1.2, flesh = 0.6, snow = 1.0 },
		-- how much faster than on a hard floor blood sets on a surface that draws the plasma out of it
		clot      = { default = 1, fabric = 1.4, dirt = 1.3, grass = 1.2, snow = 0.8 },
		-- (phase 18, 2026-10-14) how many times C.Flow.clotTime the blood of a pool takes to set: the
		-- bulk of a pool stays liquid far longer than a thin run on a body. At 1 a pool fed by a wound
		-- that went on bleeding stopped spreading after two or three minutes and only grew taller: in
		-- the game 98 of its 133 ml had set after 300 s while what it covered grew from 24 to 28
		-- units^2 (run p18d, scene acc_long); on the bench a steady pour of 0.6 ml/s covered 38 units^2
		-- from 180 s to 270 s at 1, and went on spreading to 68 at 3 (tools/offline/poolbody.ps1 age=1).
		clotK     = 3,
		-- surface tension on the contact line: what a dry cell holds back grows by this share for a
		-- cell with nothing wet around it and falls by as much for one in a deep bay (by the wet
		-- share of the ring of 16 cells around it; 7 of them are wet along a straight front)
		tension   = 0.35,
		edge      = 0.3,    -- edge noise on the lattice's field (the outline's fine wobble, in parts of a cell)
		rim       = 0.07,   -- units: width of the band over which the rim film becomes the opaque body
		crackWorld = 12,    -- units per tile of the crack mask (plates of about 1.3 units)
		crackFrom = 0.8,    -- films of dried blood on a cell from which it cracks ...
		crackSpan = 1.0,    -- ... and over how many more the cracks reach their full width
		crackMax  = 0.8,    -- how far a crack opens at most (1: the mask's whole width)
		budget    = 0.6,    -- ms a frame for the liquid's steps at full quality (pools wait their turn beyond it)
		evap      = 0.00028, -- units of layer that dry off a wet cell per second (a film on concrete in about
		                    -- five minutes: game time, like the drying of everything else; abl_drying_scale)
		soak      = 0.55,   -- the surface takes up this much of a film, times its absorbency
		edgeDry   = 1.3,    -- films that stand at a ledge before the first blood goes over it
		edgeWet   = 0.7,    -- ... and once the edge is wet
		exitNear  = 3,      -- units downhill of where a pool formed at which a stream takes over, on a steep
		exitFar   = 10,     -- floor / on one that barely slopes (in between: 1.2 / sin of the slope)
		-- what is shown follows the liquid: a cell at the pool's edge that the blood has just reached
		-- fills in at an even pace, over as long as the edge took to cross the cell before it: this
		-- long at least (0.4-unit cells; coarser ones take longer; a cell the edge has left behind
		-- catches up three times as fast), easeMax at most; blood that lands on a dry floor grows
		-- from where it landed, each cell over easeBirth
		-- drying: a wet cell with nothing wet on any of its eight sides would dry this many times
		-- faster than one in the middle of the pool (air reaches the contact line from the side
		-- as well: the edge dries first, and the drying moves inward from it)
		edgeDrying = 2.5,
		-- the meniscus: the share of the mirror the slope at the near edge loses; the far slope's
		-- light (what it mirrors at its glancing angle, as a share of the light at the place: a
		-- thin line; more is a painted ring); how far apart (units) the layer is compared with
		-- itself to find its slope
		rimShade  = 0.8,
		rimGlow   = 0.3,
		rimReach  = 0.09,
		ease      = 0.2,
		easeMax   = 2.5,
		easeBirth = 0.9,
		morph     = 0.6,    -- s over which the picture turns into the next when the cells change size or a pool is taken in
		paintDuty = 0.0165, -- share of the time a pool in view may spend on its repaints (0.25 ms a frame at 66 fps)
	},
}

-- stains & overlays
C.Stain = {
	dryBase   = 70,        -- seconds for a small stain to dry
	cellSize  = 3,         -- decal stacking cell
	cellCap   = 5,         -- decals per cell before we stop stacking
	offset    = 0.1,
	trailLife = 900,       -- seconds a dry mark on a thing stays (the trail a stream left on a prop that was moved)
}

-- ground impact stains (droplets landing on floor-like world surfaces, cl_groundstains.lua)
C.Ground = {
	-- colour: the stain filter (ground/stainfilter) aged through C.Filter; fresh -> aging at `agingK`
	-- of the drying time, dried at 1
	agingK   = 0.45,
	offset   = 0.07,             -- units above the surface (plus any bump found under the footprint)
	cellCap  = 6,                -- stains per 2.5-unit spot before new blood adds to the newest one
	rate     = 90,               -- max new ground stains per second
	tinyD    = 0.3,              -- stain diameter (units) below which a drop leaves a tiny spot
	maxHalf  = 14,               -- largest quad half-size (units)
	maxDry   = 400,              -- seconds after which a chunk's colours stop being refreshed
	drawDist = 2200,
	filmGB   = 0.3,              -- a film of fresh blood lets red through and next to no green or blue: what the painted
	                             -- filter lets through of those two, times this (it was a grey veil over a wall); the
	                             -- brown of dried blood comes back as the stain dries
	sheen    = 0.5,              -- what a wet stain mirrors of the light around it, times Fresnel: half of what a
	                             -- smooth liquid would (a film on a rough floor is no mirror)
	-- the body of liquid on a stain (phase 36): how high the blood of a drop stands on its foot
	capAspect  = 0.62,           -- a drop set down gently is a cap this high, in radii of its foot (a contact angle of about 64 degrees)
	capHigh    = 0.15,           -- units: no higher than this (3.8 mm: more blood lies wider and flat on top, it does not stand taller)
	contactTan = 0.78,           -- the slope at which the liquid meets the floor at its edge (a contact angle of 38 degrees): a
	                             -- drop that was spread wide is a flat layer with that edge, not a cap that thins out to nothing
	edgeMax    = 24,             -- how sharp that edge can be (the profile's exponent): what the mesh still shows
	bodyOpaque = 0.006,          -- units: a layer this deep lets 37 % of the floor through (0.15 mm; blood is opaque at a third of a millimetre)
	bodyDeep   = 0.03,           -- units: over this depth the colour goes from the red of a thin layer toward the dark of deep blood
	deepDark   = 0.4,            -- how much darker deep blood is
	bodyMin    = 0.0025,         -- units: lower than this it is a film, drawn as the filter alone
	crownTan   = 0.1,            -- no liquid surface is level: how much its top leans outward at its edge (six degrees), so
	                             -- that a light is mirrored on a part of it and not on all of it at once
	rimTan     = 1.6,            -- and at its very edge it rounds over to the floor (58 degrees, in the highlight's and the
	                             -- shading's normals): a highlight fades out before the edge of the mesh instead of being
	                             -- cut off straight by it
	filmWide   = 0.35,           -- units: a film with a foot wider than this (18 mm across) gets a second ring and 14
	                             -- sides: on five quads a highlight that wide has corners
	bodyDry    = 0.2,            -- what is left of its height when it has dried
	bodyDist   = 160,            -- units: bodies are built for stains nearer than this (and dropped beyond 1.4 times it):
	                             -- at that distance a drop a centimetre across is three pixels
	bodySmall  = 0.1,            -- units: a body with a foot narrower than this (5 mm across) ...
	smallDist  = 80,             -- ... is built only nearer than this: farther off it is a pixel or two
	reliefLoad = 360,            -- quads one batch of bodies holds (about twelve drops): what is built again when one of
	                             -- them changes
	reliefRate = 200,            -- quads of batches a frame may build (one batch in a frame or two; a share of it while the
	                             -- load governor has the effects scaled down: then a batch every few frames, except right
	                             -- at the eye, where one a frame is always built)
	reliefStep = 0.03,           -- a batch that is drying is built again when its fastest stain is this much of its drying on
	glossStep  = 0.01,           -- and this much while a body in it is setting: its highlight follows the liquid's edge
	                             -- inward, and in steps of three percent it was seen to hop
	reliefMost = 60,             -- stains in one batch at most (its vertices are worked out into a table of that many places)
	reliefWait = 0.3,            -- seconds a batch waits before it is built again for a stain that came or went (a burst of
	                             -- drops is one build, not one a drop); up to three times as long while the load governor
	                             -- has the effects scaled down
	mirrorWait = 0.5,            -- the same for a chunk's mirror
	-- the light on the liquid
	mirrorMax  = 0.03,           -- the most of the surroundings a wet stain shows, however low the view (more is a pale wash
	                             -- over the blood: what the map has to mirror is a blur of its surroundings)
	glossExp   = 300,            -- the key light's highlight on a body: how narrow (the surface within four degrees of
	                             -- mirroring the light to the eye). At 70 (phase 36: eight degrees) the level top of a drop
	                             -- was white all over from the light's mirror side and from ten degrees beside it, a pearl;
	                             -- at 300 it is a spot on the drop (phase 46, run q46c: the same drops at 70, 160 and 300)
	glossBoost = 3,              -- and how bright
	glossMin   = 0.004,          -- units: blood shallower than this (a tenth of a millimetre: fine spatter) has no highlight,
	glossFull  = 0.012,          -- and only from this depth on all of its top has (0.3 mm: the stain of a drop that fell)
	glossShade = 0.3,            -- where the sun does not reach: the light from above, this much of a highlight
	glossDist  = 150,            -- units: highlights on the bodies nearer than this (fading out over the last third)
}

-- impact physics thresholds on K = sqrt(We) * Re^(1/4)
C.Impact = {
	rho = 1060, sigma = 0.058, mu = 0.0040,   -- blood (SI)
	kDeposit = 57,          -- below: smooth round deposit
	kCrown   = 160,         -- above: spines + satellites
	kBreakup = 420,         -- above: airborne secondary droplets
	maxSecondary = 7,
	maxGeneration = 2,
}

-- wound events (sh_wound.lua: what the server classifies; cl_wounds.lua: what a client derives)
C.Wound = {
	-- muzzle to skin, units (1 unit ~ 1.9 cm). No single threshold fits every weapon: these are
	-- typical handgun values, scaled by the projectile's energy class on the client
	contactDist  = 3,       -- pressed against the skin or nearly so
	nearDist     = 16,      -- soot still reaches the skin (about 30 cm)
	mediumDist   = 42,      -- unburnt powder still marks the skin (about 80 cm)
	muzzleAhead  = 22,      -- when only the shooter's eye position is known, the muzzle is this far in front of it
	maxRecords   = 64,      -- wound records kept per client (the oldest dry ones go first)
	-- conservation (cl_wounds.lua): no more blood leaves the wounds than the reservoir lost
	internalShare = 0.6,    -- of a wound's blood, how much stays in the body at internal = 1 (heart)
	muscleShare  = 0.15,    -- and how much the muscle around the track holds back at muscle = 1 (thigh)
	credit       = 30,      -- ml that may be shown before the reservoir has been seen to fall
	govPrior     = 0.55,    -- assumed loss / nominal rate of a slow bleed the reservoir never shows
	govStart     = 0.36,    -- ... of a heavy wound in its first seconds, until the first report (measured after: 0.3 to 0.7)
	govFree      = 0.8,     -- ml/s per body: bleeding below this is never throttled (Z-City makes it good, the reservoir does not show it)
	govMin       = 0.25,    -- the governor closes no further than this while blood is paid in at least that fast
	govTau       = 1.6,     -- seconds over which what is paid in is evened out (the reservoir reports in steps)
	creditTime   = 20,      -- seconds the bank is spread over when it is more than what is paid in
	surge        = 0.15,    -- extra flow of a fresh wound over its steady rate (after its onset, fading)
	-- How a wound begins and ends (cl_emission.lua, Respond). The flow of a wound that has just
	-- opened rises from nothing through two lags of this many seconds each: a tenth of the steady
	-- rate after about half of it, a quarter after one, six tenths after two, nine tenths after
	-- four. Chosen to look right at Z-City's bleed rates, not measured on anybody.
	onset        = { arterial = 0.10, venous = 0.12, small = 0.25, smallSev = 1.6 },
	offset       = 0.22,    -- the same for a wound that has closed (it thins out and breaks up first)
	closeMax     = 3,       -- seconds a closed wound may take to run out, at most
	deathFall    = 0.9,     -- seconds: how fast the pressure goes when the heart stops
	shareTau     = 0.35,    -- seconds: how fast seeping turns into pouring or a jet, and back
	linkDist     = 5,       -- units: Z-City's wound record lies this close to the hole the hit reported
	offBone      = 5,       -- units: a wound's place further than this outside the hitbox of the bone it names is not on that part
	-- temporary cavity: the stretch of tissue around the track. Never drawn; it widens bruising,
	-- soft-tissue damage and the first release of blood. By energy class, times a velocity factor
	cavityEnergy   = { [0] = 0.25, 0.05, 0.15, 0.3, 0.6, 0.85, 1.0 },
	cavityVelocity = { [0] = 1.0, 0.6, 0.85, 1.15 },
	grazeDepth   = 1.4,     -- units: a flesh-only path that stays shallower than this under the skin is a graze
	-- A blunt blow that draws no blood is still sent to the clients when it did at least this
	-- much damage, as Z-City has it when it books the wound: it leaves a bruise. Less leaves
	-- nothing. (Z-City has scaled a blunt blow far down by then: a crowbar's 30 is 2 there,
	-- run w3d6; a light punch is under 1.)
	bluntMin     = 1,
	-- An edged weapon goes in rather than along (a puncture, not a cut) when the weapon says it
	-- goes at least this many times deeper than it is wide, and the blow came at the skin no
	-- flatter than stabCos (the cosine of the angle to the skin's normal).
	stabRatio    = 4, stabCos = 0.5,
	grazeCos     = 0.45,    -- ... and strikes at more than ~63 degrees from the surface normal
	-- pressure left in the circulation by blood volume (ml; Z-City: 5000 full, unconscious near 2500)
	pressureFull = 4300, pressureLow = 1700, pressureMin = 0.2,
	-- a wound's surface: seconds (times abl_drying_scale) for the blood on it to clot and to dry
	-- once it has stopped bleeding
	clotTime     = 45,
	dryTime      = 150,
	bruiseTime   = 40,      -- seconds for the bruise around a wound to come up
	internalDelay = 5,      -- seconds until a retained projectile's track has filled and bleeds outward at full rate
	grazeBleed   = 0.12,    -- share of the booked bleed a graze shows (Z-City books a graze like any other hit; skin and fat ooze)
}

-- The wounds a character carries, kept on the server for clients that were not there when they
-- were made (server/sv_woundstore.lua; abl_net_wound_replay).
C.WoundStore = {
	perBody  = 14,      -- records kept for one character (the oldest go first)
	total    = 600,     -- records kept in all (then the oldest character's oldest goes)
	age      = 1500,    -- seconds a record is kept at the most
	again    = 4,       -- seconds before the same client is answered again for the same character
	rate     = 6,       -- characters a second one client may ask about, and
	burst    = 24,      -- how many at once (a client that has just joined asks about all it sees)
	-- the client: how long after a body has come into its sight it asks (the body's bones have
	-- to be there first), and how long before it asks about the same body again
	askDelay = 0.7,
	askAgain = 15,
}

-- wound marks on the body (cl_woundfx.lua)
C.WoundFX = {
	maxPerSource = 14,      -- marks per character (entry, exit and graze marks; the oldest go first)
	lifeFade     = 4,       -- seconds over which a mark older than abl_wound_life fades before it goes
	drawDist     = 1100,
	detailDist   = 500,     -- beyond this only a mark's main layers are drawn (no stippling, bruise detail)
	exitReach    = 24,      -- units: how far along the bullet line the far surface is looked for
	-- A mark on skin that bends between bones goes along with what the skin under it does as one
	-- stiff piece (cl_woundfx.lua, Follow); it is made again from the skin as it lies once the
	-- skin has changed its shape under it by more than this (units)
	patchDrift   = 0.035,
	warmDist     = 1500,    -- players this close get their surface model built before they are hit
	gloss        = 0.34,    -- wet-blood reflection on a wound at most (of the light on it)
	-- The recess behind a wound's opening (cl_woundfx.lua, "The recess").
	cavDist      = 520,     -- units: nearer than this a wound has its recess; beyond, the painted opening alone
	cavMin       = 0.30,    -- units: how deep a recess is at the least, and at the most
	cavMax       = 1.20,
	cavLean      = 1.1,     -- how far the recess may lean along the projectile's path (sideways per unit of depth)
	-- The form (cl_woundfx.lua, "The form"): rim, lip and inside as one piece of geometry, lit.
	formSegs     = 44,      -- places round it (a torn opening has a third more)
	-- how high the rim stands over the skin, as a share of the opening's half-width: an entry's
	-- skin is pushed in and stands up a little round the hole, an exit's is turned out, the lips
	-- of a cut hardly rise; and in units, at the least and at the most
	lipEntry     = 0.38, lipExit = 0.55, lipGraze = 0.42, lipCut = 0.30,
	lipMin       = 0.035, lipMax = 0.16,
	lipCloth     = 0.55,    -- of that, in cloth (cloth puckers round a hole; it does not swell)
	-- How the form is lit: the light of the place as one light from a side over light from all
	-- round. keyFit: where that one light comes from and how strong it is are worked out from
	-- what the engine says falls on the place (render.ComputeLighting, asked for six ways a face
	-- may be turned). Without it, or where the engine says nothing of use: the sun where a trace
	-- from the wound reaches it (rimSun times the light from all round), else from above
	-- (rimShade times). The two numbers also bound what keyFit may find.
	keyFit       = true,
	rimSun       = 2.6,
	rimShade     = 0.9,
	rimGain      = 1.25,    -- how much steeper than it is the rim is lit (1: as it is)
	-- the skin as it turns into the hole stands in the hole's shade: this much of its light is left
	-- at the opening's edge, and this much at the lip, where the wound's inside begins
	rimEdge      = 0.72,
	rimLip       = 0.30,
	rimLipTint   = 0.33,    -- and of its green and blue, of that: the skin that turns in is raw and red
	-- the light inside a wound, as shares of the light on the skin round it: what comes in from
	-- all round, what its own walls throw across it, and what gets in of the one light
	inAmbient    = 0.8,
	inFill       = 0.10,
	inKey        = 0.85,
	inOwn        = 0.24,    -- and how much of its own red the inside shows over what it leaves of the picture (0: none; it is what is seen of a wound in black cloth)
	bloodGlint   = 0.7,     -- the blood standing in a wound gives the light back as a small bright point: how strongly
	rimGlint     = 0.4,     -- a wet rim gives the light back as a soft sheen: how strongly (0: not at all)
	glintDist    = 260,     -- units: nearer than this that highlight is drawn
	relief       = 1,       -- 0: the rim's light and shade are not drawn (the inside is)
	formDist     = 420,     -- units: nearer than this the rim's light and shade are drawn (the inside: cavDist)
	-- The wound as the source of its blood. What is painted round an opening (wet blood on skin,
	-- blood soaked into cloth) is blood that came out of it: it grows from nothing with what has
	-- come out, and where the body's film shows that blood (cl_film.lua) it keeps to the wound's rim.
	blotFull     = 4,       -- ml out of the opening from which the wet blood painted round it on skin is all there
	soakFull     = 14,      -- ... and the blood in the cloth round it
	blotFilm     = 0.6,     -- how large they are at the most on a body whose blood is a film, as shares of their full size
	soakFilm     = 0.6,
	-- The blood standing in an opening follows the wound's flow: to the brim while it bleeds (from
	-- there it runs over the lip, where the film takes it on), and sinking back when it stops.
	brimFlow     = 0.12,    -- ml/s through the opening from which the blood stands at its brim
	brimTau      = 0.35,    -- s over which that flow is taken (a pulse does not move it)
	brimRise     = 0.3,     -- s: how fast it wells up ...
	brimFall     = 2.5,     -- ... and how slowly it sinks back when the wound stops
	brimLevel    = 0.03,    -- how far under the lip it stands then, as a share of the wound's depth
	-- Where the film lies over the opening the picture there is blood, not skin: how much more of
	-- it the inside leaves then (red; green and blue), and what the blood standing in it leaves of
	-- it: sunk and still, and while the wound runs (red; green and blue).
	inFilmR      = 0.9,
	inFilmG      = 1.3,
	poolFilm     = { 0.5, 0.36 },
	poolFlow     = { 0.95, 0.82 },
	-- How far each layer's opening reaches along its x and its y, as shares of the layer's
	-- half-size (printed by tools/texgen with --woundmasks-only, which writes the openings as
	-- textures: <layer>_m).
	open = {
		defect1 = { 0.527, 0.488 }, defect2 = { 0.504, 0.426 }, defect3 = { 0.480, 0.512 }, defect4 = { 0.543, 0.527 },
		stellate1 = { 0.449, 0.598 }, stellate2 = { 0.449, 0.488 },
		tear1 = { 0.543, 0.246 }, tear2 = { 0.465, 0.285 }, tear3 = { 0.543, 0.426 }, tear4 = { 0.309, 0.254 },
		furrow1 = { 0.816, 0.160 }, furrow2 = { 0.816, 0.137 },
		clothhole1 = { 0.309, 0.316 }, clothhole2 = { 0.332, 0.363 }, clothhole3 = { 0.316, 0.316 },
		clothtear1 = { 0.582, 0.621 }, clothtear2 = { 0.527, 0.566 }, clothtear3 = { 0.527, 0.605 },
	},
}

-- BloodMark look: deeper blood, subtly reduced coverage.
C.BloodMarkOpacity = 0.90
local function BloodMarkDarken(palette)
    for _, value in pairs(palette) do
        if istable(value) then
            if isnumber(value[1]) and isnumber(value[2]) and isnumber(value[3]) then
                for i = 1, 3 do value[i] = value[i] * 0.85 end
            else
                BloodMarkDarken(value)
            end
        end
    end
end
BloodMarkDarken(C.Colors)
BloodMarkDarken(C.Film.palette)
BloodMarkDarken(C.Pool.palette)
if C.P22.deepColour then
    for i = 1, 3 do C.P22.deepColour[i] = C.P22.deepColour[i] * 0.85 end
end
