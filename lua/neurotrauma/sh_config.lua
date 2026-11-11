-- Every constant and curve of the module, each with the tier of its justification and the source
-- IDs of docs/NEUROTRAUMA_RESEARCH.md:
--   [S] strongly supported   [R] reasonably supported
--   [P] plausible simulation abstraction   [G] game-only approximation
-- Units: 1 game unit = 1 inch, as in the blood module. Speeds are converted to m/s and angular
-- velocities to rad/s before any curve is applied. Curves are parameterised game curves, calibrated
-- on what the engine's ragdolls actually do (PROGRESS.md); the literature gives their ordering and a
-- scale reference, never a probability the game claims to reproduce.

NeuroTrauma.Config = NeuroTrauma.Config or {}
local C = NeuroTrauma.Config

C.M_PER_UNIT = 0.0254
C.RAD = math.pi / 180

local SV = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
C.sv = {
	enabled   = CreateConVar("neuro_enabled", "1", SV, "NeuroTrauma master switch", 0, 1),
	takeover  = CreateConVar("neuro_zcity_takeover", "1", SV, "The neurological model decides what a head injury does: Z-City's instant death by a bullet in the brain box and its random fencing spasm are replaced", 0, 1),
	headshot  = CreateConVar("neuro_headshot_rules", "1", SV, "Gameplay rules for bullets in the head: one wound is survived at first, a second is death, a rifle round is a collapse into about four seconds of cardiac arrest and then death (0: the model judges every bullet by its track and energy)", 0, 1),
	rifleArrest = CreateConVar("neuro_rifle_arrest_seconds", "4", SV, "Seconds a character lies in cardiac arrest after a rifle round through the head before it dies (neuro_headshot_rules 1)", 1, 30),
	deathSpasm = CreateConVar("neuro_zcity_deathspasm", "1", SV, "With the takeover on: 1 leaves Z-City's own stiffening of a corpse to run, except on a body the model has just shown in an arrest; 0 holds it back for every death", 0, 1),
	timescale = CreateConVar("neuro_timescale", "15", SV, "How much faster than life the slow processes run (bleeding inside the skull, swelling)", 1, 120),
	dev       = CreateConVar("neuro_dev", "0", bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY), "Developer commands (superadmin)", 0, 1),
	log       = CreateConVar("neuro_log", "0", FCVAR_ARCHIVE, "Print injury events and state transitions to the server console", 0, 1),
	dominance = CreateConVar("neuro_dominance", "auto", SV, "Hemisphere that leads for language: auto (drawn for each character from handedness), left, right"),
	chat      = CreateConVar("neuro_chat", "1", SV, "Language and typing deficits change what an injured character writes in chat and reads from it", 0, 1),
	chatAdmins = CreateConVar("neuro_chat_admins", "0", SV, "1: admins are subject to the chat filter like everybody else (0: their messages pass unchanged)", 0, 1),
}

------------------------------------------------------------------------------------------
-- Capturing an injury event (sv_injury.lua)
------------------------------------------------------------------------------------------
C.Capture = {
	headMinSpeed = 35,     -- u/s: a slower head contact is resting or rolling, not an event [G]
	bodyMinSpeed = 220,    -- u/s: a body contact this hard opens a whiplash window [G]
	window       = 0.2,    -- s: how long the head's rotation is followed after a contact [G]
	debounce     = 0.3,    -- s: one event per body in this time [G]
	whipMinOmega = 5,      -- rad/s: a whiplash below this is no event [G]
	historyKept  = 8,      -- events remembered per character
	queueMax     = 48,     -- contacts taken per tick at most (a pile of bodies must not flood it)
}

-- What the head met. The ordering is physical (harder surfaces stop the head faster); the numbers
-- are ours [G]. Matched as substrings of the engine's surface property name, first hit wins.
C.Surface = {
	{ "concrete", 1.0 }, { "rock", 1.0 }, { "brick", 1.0 }, { "tile", 1.0 }, { "boulder", 1.0 }, { "asphalt", 1.0 },
	{ "metal", 1.0 }, { "solidmetal", 1.0 }, { "chain", 0.8 }, { "glass", 0.9 }, { "porcelain", 0.95 },
	{ "gravel", 0.7 }, { "wood", 0.75 }, { "plaster", 0.7 }, { "plastic", 0.6 },
	{ "dirt", 0.45 }, { "grass", 0.45 }, { "sand", 0.4 }, { "mud", 0.35 },
	{ "carpet", 0.4 }, { "rubber", 0.4 }, { "cardboard", 0.35 }, { "paper", 0.35 }, { "foliage", 0.3 },
	{ "flesh", 0.3 }, { "snow", 0.2 }, { "slime", 0.15 }, { "water", 0.15 },
}
C.SurfaceDefault = 0.8

------------------------------------------------------------------------------------------
-- From kinematics to injury loads (sv_biomech.lua). A load of 1 is "severe".
------------------------------------------------------------------------------------------
C.Biomech = {
	-- Rotation strains the brain far more than straight-line motion [S: B3]; sideways (coronal)
	-- rotation was the worst in animals, axial next, sagittal least [R: B1 B8 B6]. Weights are ours [G].
	axisCoronal  = 1.0,
	axisAxial    = 0.85,
	axisSagittal = 0.7,
	-- A whiplash counts in full only when it is as abrupt as a strike (rad/s^2). Measured: a head
	-- striking the ground 230..2100, a head whipping as the body lands 150..360 [G].
	whipAlphaFull = 700,
	-- An awake person protects the head in a fall (arms, neck); a limp one does not [P: C3 read in
	-- reverse]. That takes a fixed amount off a fall, so it saves a stumble and not a dive from a
	-- roof: this much at full consciousness, nothing at none [G].
	protectRot     = 5.0,      -- rad/s
	protectContact = 2.5,      -- m/s
	-- Estimated kinematics of a blunt hit on a standing character (no physics to measure) [G].
	-- Calibrated so that a fist (damage 8) turns the head less than a limp collapse onto concrete
	-- does, a bat (25) about as much as a head-first drop of a metre or two, a sledge (45) more.
	bluntDvPerDamage = 0.18,   -- m/s of head speed change per point of Z-City damage
	bluntLever       = 0.164,  -- m: lever arm that turns a hit into rotation about the neck
	bluntContact     = 1.3,    -- a weapon loads a small area: contact counts for more than a floor's
	bluntRotMax      = 30,     -- the estimate is not trusted beyond the hardest measured impacts (26..32)
	-- Individual tolerance: identical impacts injure people differently [S: B13 B14]; the spread is ours [G]
	tolSpread = 0.2,
}

------------------------------------------------------------------------------------------
-- From loads to injury (sv_biomech.lua, Loads). "rot" below is the weighted rotation of the head
-- in the game's own scale, rad/s: a limp collapse from standing onto concrete measures 4..12, a
-- head-first drop of 3 units 12..15, of 8 units 26..32 (PROGRESS.md, phase 20). The literature's
-- dummies turn three to four times faster in the same falls [R: B9]; the curves are set on the
-- game's numbers, the literature gives their order.
------------------------------------------------------------------------------------------
C.Load = {
	-- Transient loss of consciousness (knockout): follows rotation [S: B1 B8]
	locMid = 11.5, locK = 2.5,       -- chance 50 % at this rotation [G]
	locBase = 6, locDurK = 5,        -- seconds at locMid, e-fold per this much rotation above it [G]
	locMax = 600,
	-- Dazed without losing consciousness [S: C1 C3]
	stunMid = 6, stunK = 1.5, stunBase = 3,
	-- Structural diffuse injury (concussion -> axonal): none below diffuseFrom, 1 at diffuseFull [P]
	diffuseFrom = 7, diffuseFull = 33, diffusePow = 1.3,
	-- The whole body stopped at speed (a high fall landed on the feet or the back) [P]
	landingFrom = 14, landingFull = 34, landingMax = 0.5,
	-- Skull fracture follows the contact, alike at every site [R: B3 B10 B11]
	fracMid = 7.5, fracK = 1.5,
	-- Bruising of the brain under the impact and, less, opposite it [S: C11; split G]
	focalFrom = 3.5, focalFull = 13.5, focalPow = 1.2, focalFracture = 0.15, focalCoup = 0.75,
	-- Primary brainstem injury: only extreme rotation [R: S1 grade 3]
	stemFrom = 24, stemFull = 38,
	-- Breathing stops at impact, longer for more energy [R: R1 R2]
	apnoeaRot = 12, apnoeaPerRot = 1.6, apnoeaContact = 6, apnoeaPerContact = 1.0, apnoeaMax = 40,
	-- Forearms held up at a knockout: about two thirds of filmed knockouts, moderate force [R: C6]
	fencingP = 0.66, fencingMid = 12, fencingK = 3, fencingMin = 2, fencingMax = 8,
	-- Impact convulsion: rare, begins within 2 s, short [R: C5]; the rate is ours [G]
	convulsionP = 0.06, convulsionMin = 5, convulsionMax = 60,
	-- A lesion that grows afterwards. Fast with a fracture (epidural-like), slower with rotation
	-- (subdural-like) [S: B3 S3 S4]; odds, speed and final size are ours [G]. Minutes of the
	-- compressed clock until it would reach 1 (critical).
	-- A bump must not start one: about 1 in 70 at the rotation of a limp collapse onto concrete,
	-- 1 in 4 at twice that. The harder the impact, the larger the lesion can get.
	epiP = 0.3, epiMinutes = { 20, 90 },
	subMid = 21, subK = 3, subP = 0.6, subMinutes = { 30, 180 },
	massFinal = { 0.3, 0.6 }, massFinalSevere = 0.7,
	-- A second injury before recovery from the first counts for more [R: C8 C12 C13; size G]
	vulnAdd = 0.5, vulnMinutes = 180,
	-- Blast and hard landings on the feet: equivalent rotation [G]
	blastRotPerDamage = 0.12,
	landRotFrom = 10, landRotPer = 0.5,
	-- A bullet. Energy relative to energyRef scales what its track does [P; research section 6]
	energyRef = 600, energyMin = 0.5, energyMax = 4,
	tangentialContact = 5, tangentialPerJ = 1 / 400,
	-- What a bullet inside the skull does to the brain as a whole (sv_biomech.lua). That the
	-- trajectory decides is from the literature [S: G1 G2 G3 G4 G6], every number is ours [G].
	shotFocal = 0.55,                        -- bruising booked for a hemisphere the track crosses
	shotCavity = 0.18, shotCavityPow = 1.3,  -- the pressure peak of the temporary cavity [S: G5]: 0.14 for a 9 mm, 0.9 for a rifle
	shotCentral = 2.5, shotBoth = 1.0,       -- how much more for a track through the deep middle / through both hemispheres
	shotWaveStem = 0.5, shotWaveFrom = 1.2,  -- what the wave does to the brainstem, per unit of energy above this
	shotCentralStem = 0.45,                  -- a track through the deep middle lies on the upper brainstem [S: G1]
	shotLocP = 0.6,                          -- unconscious at once after a track of the survivable kind
	shotMassP = 0.55,                        -- such a track bleeds on
	shotMinutesCentral = { 4, 10 },          -- minutes (compressed clock) to critical: through the middle and the ventricles
	shotMinutesBoth = { 8, 25 },             -- through both hemispheres or the posterior fossa
	-- unsurvivable in the instant of the hit (sv_brain.lua, Triage): energy (as a multiple of
	-- energyRef: 2.5 = 1500 J, the rifles and slugs) from which a wound is of the explosive kind
	-- [S that the kind exists: G5; the number G]; share of the medulla lost on both sides [G]
	shotExplosive = 2.5, shotMedulla = 0.5,
	grazeStunP = 0.3,
}


------------------------------------------------------------------------------------------
-- Anatomy (sv_anatomy.lua): how an injury is written into the atlas. Shapes and sizes are in the
-- atlas frame (the head is about 2 across) and are ours [G].
------------------------------------------------------------------------------------------
C.Anatomy = {
	contusionSigma = 0.42,     -- a bruise falls off over this distance from the point of impact
	contrecoup = 0.4,          -- a midline blow: the bruise opposite, as a share of the one under it
	poleFrom = 0.25,           -- focal load from which the frontal and temporal poles are bruised too [P]
	poleShare = 0.5,
	trackReach = 0.16,         -- how far beside a wound track tissue is destroyed, at reference energy
	vesselReach = 0.07,        -- a vessel is cut if the track passes this close
	trackSkin = 1.5,           -- units from the entry wound to the brain (scalp, skull)
	daiTract = 0.6,            -- a full diffuse injury thins a tract by this times the tract's own share
	massReach = 0.6,           -- a lesion that takes up room switches off what lies this close to it
	massSuppress = 1.2,
	-- head half-extents (units) that map a point of the head into the atlas frame
	headX = 2.9, headY = 3.5, headZ = 2.8,
}

------------------------------------------------------------------------------------------
-- Blood supply (sv_vascular.lua). Flow is a share of normal. That function stops at a higher flow
-- than the one at which tissue dies is the concept of the ischaemic penumbra [N8, title only];
-- both thresholds are ours [G].
------------------------------------------------------------------------------------------
C.Vascular = {
	thrFunction = 0.5,         -- below this a region begins to fail, reversibly
	thrCore = 0.25,            -- below this it is being destroyed
	coreHours = 6,             -- hours of the compressed clock to a complete infarct at no flow [P: N9 gives 10 h for a typical large-vessel stroke]
	arrestBelow = 0.2,         -- circulation delivering less than this: the whole brain is without blood
	arrestSeconds = 120,       -- real seconds of that to destroy the most susceptible structures [G: two to three times faster than life, where it is minutes: K11]
	plateau = 45,              -- Z-City blood pressure (70 at rest) above which flow is kept normal [P: K12]
	icpWeight = 30,            -- how much of it a full rise of intracranial pressure takes away [P: K13]
	watershed = 0.3,           -- border-zone regions lose this much more when the circulation is failing [P: N5]
	leptoQuality = { 0.4, 1.0 },  -- this person's surface collaterals, drawn once [P: that they differ between people; N7 on what they decide]
	sahSmall = 0.15, sahLarge = 0.4,   -- blood around the brain from a cut branch / a cut stem
	sahVolume = 0.08, ivhVolume = 0.12, ivhAdd = 0.5,   -- room that blood takes [G]
	herniationPCA = 0.3,       -- what is left of the posterior cerebral artery pinched at the tentorium [P]
	cprFlow = 0.2,             -- the most that reaches the brain while the heart is stopped, under compressions [G]: below thrCore, so injury goes on, at a fifth of the rate
	arrestReserve = 12,        -- s over which a brain without circulation runs down what it holds: function fades from 6 s, is gone at 9 [S: R5 that it is seconds; the number G]
	arrestGrace = 30,          -- s of a stopped heart that leave no lasting injury [G]
	stoppedPulse = 9,          -- Z-City's pressure value rests below this when the heart is stopped and nobody compresses the chest (measured: 6)
	swellInfarct = 2.0,        -- swelling per infarcted share of the brain [P: N21]
	-- the fluid spaces a wound track can open: { x, y, z, radius }
	ventricles = { { 0.15, 0.0, 0.3, 0.14 }, { -0.15, 0.0, 0.3, 0.14 }, { 0, 0, 0.05, 0.08 } },
}

------------------------------------------------------------------------------------------
-- From injury to function, and what is written to Z-City (sv_brain.lua, sv_states.lua).
-- Z-City's own thresholds (read in its source): consciousness < 0.4 ragdolls, < 0.1 unconscious;
-- brain >= 0.05 sway and random falls, >= 0.3 unconscious, >= 0.6 arrest, >= 0.7 death.
------------------------------------------------------------------------------------------
C.Brain = {
	reserve = 0.35,            -- added volume the skull buffers before pressure rises [S: S5; number G]
	pressurePow = 1.6,
	swellMinutes = 30,         -- time constant of secondary swelling, compressed clock [G]
	swellDiffuse = 0.5, swellFocal = 0.6, swellHypoxic = 0.8, swellMass = 0.3, swellShock = 0.3,
	hypoxiaFrom = 8,           -- Z-City oxygen (of 30) below which the brain is being injured [G]
	hypoxiaSeconds = 120,      -- s without any oxygen to a full hypoxic injury [G]
	bloodFrom = 3800, bloodSpan = 1500,   -- ml of blood from which low pressure adds to swelling [G]
	mannitolRate = 0.004,      -- swelling drawn down per second while mannitol acts [G]
	diffuseKeep = 0.6,         -- share of a diffuse injury that does not recover within a round [G]
	diffuseMinutes = 20,       -- half-life of the part that does, compressed clock [G]
	-- consciousness lost to: diffuse injury, brainstem stress [P]
	cDiffuseFrom = 0.08, cDiffuseSpan = 0.5,
	cStemFrom = 0.2, cStemSpan = 0.28,
	confusionPerLoc = 6,       -- the confused phase lasts this many times the knockout [G]
	confusionMin = 8, confusionMax = 240,
	-- posturing belongs to deep unresponsiveness with brainstem stress [S: S8 S17]; thresholds ours [G]
	postureFrom = 0.45, postureSpan = 0.4, postureExtensor = 0.72,
	herniation = 0.7,          -- pressure from which the herniation signs appear [G]
	pupilFrom = 0.5, pupilSpan = 0.3,
	pupilSameSide = 0.73,      -- the dilated pupil is on the side of the mass in 73 % [R: S11]
	weakOpposite = 0.8,        -- weakness is opposite the mass, else on its own side [S: S6; share G]
	stemFailure = 0.95,        -- brainstem stress at which breathing and the heart stop [G]
	-- consciousness lost to: the paramedian thalamus of both sides, most of the cortex of both hemispheres [P]
	cThalFrom = 0.15, cThalSpan = 0.6,
	cThalMax = 0.88,           -- a thalamic lesion alone leaves a remnant: deeply drowsy, rousable, not the coma of the brainstem [P]
	cCortexFrom = 0.5, cCortexSpan = 0.4,
}

-- What each state writes (docs/NEUROTRAUMA_ARCHITECTURE.md, 5.5)
C.Out = {
	stunned  = { 0.70, 0.90 },   -- consciousness clamp, at the worst and at the best of the state
	confused = { 0.45, 0.70 },
	impaired = { 0.45, 0.60 },
	down     = 0.25,             -- awake but cannot stand (Z-City ragdolls below 0.4)
	unconscious = 0.05,
	brainImpaired = { 0.05, 0.25 },
	brainComa = { 0.30, 0.49 },
	brainFailure = 0.60,
}

------------------------------------------------------------------------------------------
-- Movement (sv_motor.lua, cl_anim.lua). The shapes of the postures are from the literature; all
-- of these numbers are ours [G].
------------------------------------------------------------------------------------------
C.Motor = {
	speed = 150, damp = 70,       -- how fast and how firmly a part is drawn to its place (u/s)
	arrive = 0.3,                 -- s in which it would get there
	accel = 2400,                 -- u/s2: the hardest the trunk can be pulled at full strength (gravity is 600)
	trunkLoad = 2.0,              -- the pelvis and the chest carry this many times their own weight
	trunkTilt = 0.21,             -- the line from the pelvis part to the chest part leans this much (tangent) against the body's own line
	jerkQuick = 3.0,              -- the contraction of a beat pulls this many times harder and faster than a posture
	releaseShare = 0.8,           -- its release, as a share of the contraction's strength
	releaseQuick = 2.5,
	heave = 140,                  -- u/s given to the chest by the contraction of a clonic beat
	archPosture = 5,              -- units the trunk is lifted off the line from feet to head: extensor posture
	archTonic = 7,                -- the tonic phase of a convulsion
	archStrength = 1.0, archQuick = 3.0,
	gaspLift = 7, gaspTime = 0.8, -- an agonal gasp: units the chest is heaved up, and for how long (s)
	-- A heart that has stopped: the body is let fall into the shape of one that holds nothing
	-- (sv_motor.lua, Settle). A body that has only just gone down falls open quickly, with what is
	-- left of its fall; one that has lain for a while only lets go.           { just down, lying }
	arrestFresh = 4,              -- s since the body went down within which the arrest counts as part of the fall
	arrestSettle = { 1.3, 2.0 },  -- s the limbs are drawn for
	arrestStrength = { 0.8, 0.5 },-- how firmly (a share of what a posture is drawn with)
	arrestQuick = 1.2,            -- how fast, for a body that has just gone down
	arrestProp = 7,               -- units the chest is above the pelvis from which a trunk counts as propped up, and is left to fall first
	arrestRoll = 120,             -- degrees a second at which a body that lies on its side is let roll onto its back or its face
	arrestHead = 150,             -- degrees a second at which the head rolls to the side
	breathHz = 0.27,              -- breaths a second of a body that lies unconscious and breathes
	breathLift = 3.0,             -- units its chest rises: more than life, so that it can be seen across a street
	breathStrength = 0.45,
	stirEvery = { 2.2, 4.5 },     -- s between the movements of a body that is coming round
	stirTime = 1.1,               -- s one of them lasts
	stirStrength = 0.55,
	turnShare = 0.8,              -- turning fast counts this much of running, for the risk of losing balance
	restShare = 0.35,             -- a posture at rest, as a share of its evoked strength
	rise = 2.2, ease = 0.35,      -- per second: a posture comes on quickly and eases slowly
	evokedHold = { 3, 7 },        -- s a posture holds after a stimulus
	waveFrom = 0.5,               -- intensity from which it also comes unprompted
	waveEvery = { 7, 16 },        -- s between such waves
	movedSpeed = 55,              -- u/s: a body moved faster than this is being handled
	stumbleFrom = 0.8,            -- balance below which a standing character can fall
	stumbleRate = 0.5,            -- falls per second at no balance and running speed
	stumbleTime = { 1.2, 3.2 },   -- s on the ground
	standMotor = 0.25,            -- a side weaker than this does not carry the body
	standBalance = 0.15,
	moveFloor = 0.4,              -- slowest walking, as a share of normal speed
	-- what a client draws on a standing character (degrees)
	swayAngle = 26, headDroop = 40, lean = 30, armDroop = 1,
}

------------------------------------------------------------------------------------------
-- Seizures (sv_seizure.lua). That early seizures follow head injury, more often the worse it is
-- and with bruising, bleeding and fracture, is [S: Z1 Z2 Z3]; that a tonic-clonic seizure lasts
-- about a minute and often lacks one of its phases is [S: Z5]; that weakness of one side can
-- follow is [S: Z7]. The hazard, the phase lengths and the beat are ours [G].
------------------------------------------------------------------------------------------
C.Seizure = {
	hazardPerMinute = 0.0015,     -- per minute of the compressed clock at seizure risk 1
	focalOnset = 0.6,             -- share of seizures that begin on one side
	spread = 0.5,                 -- share of those that go on to both sides
	tonicP = 0.8, clonicP = 0.9,  -- a phase can be missing
	focalTime = { 8, 30 }, tonicTime = { 6, 18 }, clonicTime = { 20, 50 },
	postictalTime = { 30, 150 },  -- unresponsive, then coming round
	clonicHz = { 3.0, 1.1 },      -- beats per second at the start and at the end of the clonic phase
	focalHz = 3.0, beatShare = 0.32, beatTime = 0.15,   -- s a contraction lasts
	tonicFlex = 1.5,              -- s at the start of a tonic phase in which the arms come up before everything straightens
	toddP = 0.3, toddDeficit = 0.6,   -- one-sided weakness after a focal onset, and how much
	convulsionTonic = { 1, 3 },   -- an impact convulsion: brief stiffening, then jerks
	refractory = 120,             -- s (real) in which no second seizure starts
}

------------------------------------------------------------------------------------------
-- Breathing and cardiac arrest (sv_cardioresp.lua). An arrest looks like this: the person drops
-- without breaking the fall, does not respond, and does not breathe or only gasps now and then
-- [S: R5]; gasping is seen in about four arrests in ten and fades within minutes [S: R3 R4];
-- a few jerks as the brain loses its blood flow are common [R: R6]. Times are ours [G].
------------------------------------------------------------------------------------------
C.Arrest = {
	locFrom = 3, locSpan = 5,          -- s after circulation stops: consciousness goes between these
	confirm = 0.8, confirmBack = 2.0,  -- s the heart must have been still / have beaten again before an arrest begins / is over (Z-City's heart can flicker)
	jerksP = 0.5, jerksAfter = { 4, 7 }, jerksTime = { 2, 5 },
	gaspP = 0.4,                       -- share of arrests with agonal gasps
	gaspFirst = { 3, 9 },              -- s to the first gasp
	gaspEvery = { 4, 9 },              -- s between gasps at first
	gaspStretch = 1.18,                -- every interval this much longer than the last
	gaspFor = { 60, 200 },             -- s until they stop
	wakeConfused = { 30, 80 },         -- s of confusion once circulation is back
	breathCycle = 24,                  -- s: one cycle of periodic breathing
	pauseShare = 0.7,                  -- share of a cycle without breath at no respiratory control
}

------------------------------------------------------------------------------------------
-- Prolonged seizures (sv_seizure.lua). The time points are those of the ILAE definition of
-- convulsive status epilepticus [S: Z8]: after t1 = 5 minutes a seizure is unlikely to stop by
-- itself, after t2 = 30 minutes lasting harm is to be expected. Seizures run in real time here, so
-- the two are real minutes. How many seizures have no end of their own, and what an untreated one
-- does after minutes, is ours [G].
------------------------------------------------------------------------------------------
local CSZ = C.Seizure
CSZ.awareP = 0.5                      -- a focal seizure leaves awareness intact in this share
CSZ.impairedTime = { 30, 90 }         -- s of staring and fumbling
CSZ.statusP = 0.1                     -- share of generalised seizures that do not stop, at seizure risk 1/3
CSZ.prolongedAfter = 120              -- s of convulsion from which a seizure is called prolonged [G]
CSZ.statusAfter = 300                 -- t1 [S: Z8]
CSZ.harmAfter = 1800                  -- t2 [S: Z8]
CSZ.harmPer10s = 0.01                 -- damage to each hippocampus per 10 s beyond t2 [P]
CSZ.subtleAfter = 480                 -- s after which little movement is left [P]
CSZ.statusMax = 2400                  -- s after which the brain is exhausted and it ends [G] (beyond t2, so that t2 can be reached)
CSZ.statusBlock = { 25, 50 }          -- s: it goes on in stretches of this length
CSZ.breathHold = 0.4                  -- share of the time without breath in the clonic phase [P: Z11 that breathing suffers]
CSZ.hypoxiaAfter = 60                  -- s of convulsion after which the oxygen store cannot stay full [P]
CSZ.hypoxiaPer = 20                    -- s per unit of Z-City oxygen (of 30) the ceiling sinks [G]
CSZ.hypoxiaFloor = 13                  -- where it stops sinking (Z-City injures the brain below 8) [G]

------------------------------------------------------------------------------------------
-- Drugs (sv_treatment.lua)
------------------------------------------------------------------------------------------
C.Med = {
	cooldown = 1.5,            -- s between two administrations by the same giver
	reach = 110,               -- units between giver and patient
	giverHand = 0.3,           -- the giver needs one hand at least this good
	midazolam = {
		onset = { 40, 110 },   -- s until it acts [G; in life a median of 3.3 min from injection to the end of convulsions: Z9]
		rise = 20,             -- s over which it comes on
		halfLife = 420,        -- s (game) for its level to halve [G]
		stopP = { 0.73, 0.4, 0.15 },   -- chance to stop a running seizure: first dose [S: Z9], later doses [S: Z11 that they are less; numbers G]
		sedation = 0.32,       -- consciousness taken per dose on board [G]
		resp = 0.1,            -- respiratory control taken, times the square of the doses on board [P]
		guard = 0.8,           -- share of the seizure hazard a full dose takes away
		maxDoses = 4,
	},
}

------------------------------------------------------------------------------------------
-- Circulation (sv_cardio.lua): thresholds of labels and the couplings between brain and heart
------------------------------------------------------------------------------------------
C.Cardio = {
	roscTime = 20,             -- s after the circulation returns that are called ROSC
	postArrest = 300,          -- s called post-arrest [G; the syndrome lasts days: K1]
	cprGap = 2.5,              -- s without a compression after which CPR counts as stopped
	labelHold = 2,             -- s a circulation label has to hold before it is taken
	cprStep = 1,               -- a rise of Z-City's pressure value by this much in one step, with the heart stopped, is a compression (the value only sinks by itself; near its ceiling of 70 a compression lifts it by little more than this)
	seizureAdrenaline = 1.2,   -- Z-City adrenaline a convulsion holds the body at (its heart rate adds 40 per unit) [P]
	cushingFrom = 0.55,        -- intracranial pressure from which the heart is slowed [S: S7 that it is; numbers G]
	cushingDrop = 28,          -- beats per minute taken at full pressure
	secondHit = 0.25,          -- share of the ischaemic damage that follows after the circulation is back [P: K2]
	secondHitMinutes = 30,     -- over this long, compressed clock
}

------------------------------------------------------------------------------------------
-- Language (sv_language.lua): from which loss a disorder shows in chat [G]
------------------------------------------------------------------------------------------
C.Language = {
	from = 0.12,               -- a channel must have lost more than this
	confusionFrom = 0.3,       -- the same for thinking as a whole
	voiceFrom = 0.3,           -- speech (language and articulation) below this: the voice is not heard
	typingChars = 80,          -- characters a message can have with hands that half work
}

------------------------------------------------------------------------------------------
-- What the body can do with the keys (sh_move.lua). Limits on shares of normal strength [G].
------------------------------------------------------------------------------------------
C.Control = {
	runLeg = 0.6, runBalance = 0.5,
	jumpLeg = 0.5, jumpBalance = 0.45,
	fireHand = 0.3,            -- the weapon hand (right) must close this well to pull a trigger
	gripHand = 0.15,           -- below this the weapon hand cannot hold what is in it: it is dropped
	aimHand = 0.3,             -- the left hand must hold this well to aim a long weapon
	veerShare = 0.9,           -- commands in eight that carry the pull, per step of unevenness
	ataxiaPunch = 1.6,         -- degrees a clumsy weapon arm throws the aim, at no coordination
	staggerInput = 0.3,        -- share of the walking keys that arrives while a character staggers
}

-- The spinal cord (sv_spine.lua) [G]
C.Spine = {
	from = 0.25,                  -- share of Z-City's "broken" value of a spine organ up to which only the bone is hurt
	sideShare = 0.5,              -- how unevenly the two halves of a level are taken by a bullet that passed to one side
	sideReach = 1.5,              -- units off the middle from which a hit counts as wholly one-sided
	breathFloor = 0.5,            -- share of breathing left with the cervical cord cut
}

-- The gameplay rules for bullets in the head (neuro_headshot_rules; sv_injury.lua, sv_trauma.lua).
-- They are rules of the game, asked for as such, and not what the literature says a bullet does.
C.Headshot = {
	collapse = 0.9,               -- s from a rifle round to the arrest: the fall
	gaspAt = 2.3,                 -- s into that arrest at which the one gasp comes
	minLoc = 30,                  -- s a character is unconscious, at least, after any bullet in the brain
	posture = { 4, 8 },           -- s the posture of the first moments lasts
	apnoea = { 3, 6 },            -- s without breath after the hit
}

-- Going down (sv_collapse.lua) [G]
C.Collapse = {
	staggerTime = { 0.55, 0.95 }, -- s a stagger lasts before it is caught or ends on the ground
	staggerGap = 1.5,             -- s after one before the next can begin
	stepSpeed = 95,               -- u/s of a step that was not meant
	throw = 1.0,                  -- scale of the movement a fall is given at the moment the ragdoll is made
	faintFrom = 0.58,             -- wakefulness below which a character whose wakefulness is falling loses its feet
	faintGap = 8,                 -- s before that can happen again
	dazeRot = 6,                  -- rotation of a hit from which a character that stays up staggers
}

-- The animation state (sh_anim.lua, sv_anim.lua) [G]
C.Anim = {
	floor = 0.25,                 -- intensity below which a mode is not entered: what is announced can be seen
	postureFloor = 0.15,          -- posturing below this is neither claimed nor driven
	collapseTime = 1.2,           -- s a body counts as collapsing after a critical state has taken it down
	dullFrom = 0.9, dullSpan = 0.5,   -- wakefulness below which a standing character looks injured, and by which it looks worst
	dazed = 0.5, confused = 0.45,     -- intensity of that look while dazed, while coming round
}

------------------------------------------------------------------------------------------
-- The pose controller of the client (cl_pose.lua): degrees and distances [G]
------------------------------------------------------------------------------------------
C.Pose = {
	lod = { 400, 900, 1800, 3000 },   -- units: full detail / no fingers / trunk and limbs / trunk only / nothing
	swayFull = 0.5,            -- loss of balance at which the sway is at its largest
	dazedSway = 0.6,           -- share of the largest sway a dazed character shows at full intensity
	armOut = 7, armTurn = 30, elbowHang = 4, wristDrop = 35,
	kneeGive = 14, footDrop = 16, footTurn = 14, limp = 12,
	stance = 13, titubation = 4, tremor = 2.4, toePoint = 30,
	staggerLean = 26,          -- degrees the trunk goes over in a stagger
	staggerDrop = 9,           -- units the hips sink as the knees give
	staggerArms = 28,          -- degrees the arms go out
	staggerShown = 0.75,       -- s in which a client lets a stagger reach its full pose
	legDrag = 14,              -- degrees a weak leg trails behind in walking
	headTurn = 32, turnSign = 1,   -- a focal seizure draws the head round to its side (degrees; which way the bone turns)
	fumbleTurn = 45,           -- the upper arm turned in, to bring a fumbling hand to the chest
}

------------------------------------------------------------------------------------------
-- The owner's senses (cl_senses.lua) [G]
------------------------------------------------------------------------------------------
C.Senses = {
	fieldAlpha = 246,          -- opacity of a field that is fully lost
	fieldEdge = 0.06,          -- width of the soft border at the middle, as a share of the screen
	neglectDim = 0.55,         -- how dark the neglected side gets at full neglect
	hearingFade = 85,          -- percent of sound taken at full hearing loss
	missShare = 0.7,           -- share of chat that goes unnoticed at no attention
}
