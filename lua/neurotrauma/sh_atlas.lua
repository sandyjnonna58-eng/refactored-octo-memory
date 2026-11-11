-- The anatomical atlas: regions of the brain, the white-matter tracts that join them, the vessels
-- that feed them. Plain data, built once at load; no entity, no per-frame work. What a character's
-- brain can still do is computed from this and from that character's own damage (sv_anatomy.lua).
--
-- Parcellation. Cortex: the gyral labels of the Desikan-Killiany atlas as FreeSurfer distributes
-- them [N1 N2], 34 per hemisphere. Three of them are split here into functional zones of our own
-- (marked "own"): the precentral and postcentral gyri by body part, after the foot - hand - mouth
-- order of the motor strip [N13] and the hand knob [N12] (the leg lies in the paracentral lobule,
-- which is a label of the atlas); the superior temporal gyrus into a front and a rear part; and the
-- supplementary motor area out of the superior frontal gyrus. Deep grey, cerebellum and brainstem
-- follow FreeSurfer's subcortical labels, with the thalamus divided by its four arterial
-- territories [N22] and the brainstem by level and by tegmentum against base [N14 N42 N67].
-- Brodmann numbers are reference labels only.
--
-- Positions are a schematic of the head, not atlas coordinates [P]: x from the midline (0) to the
-- side (1), y from the back (-1) to the front (1), z from the base (-1) to the crown (1); brainstem
-- and cerebellum reach below -1. They are used to tell which structures a wound track passes and
-- where a blow lands, and for the developer's drawing.
--
-- Every functional and vascular statement names its tier and source (docs/NEUROTRAUMA_RESEARCH.md):
--   [S] strongly supported  [R] reasonably supported  [P] plausible abstraction / standard anatomy
--   not verified here from a fetched source  [G] game-only number.
-- All weights and shares are ours [G] unless a source is named for the number itself.

local NT = NeuroTrauma
NT.Atlas = NT.Atlas or {}
local A = NT.Atlas

------------------------------------------------------------------------------------------
-- Regions. Template rows for one hemisphere:
--   key, name, lobe, kind, brodmann label, x, y, z, radius, hypoxia vulnerability, seizure
--   propensity, supply { vessel = share }
-- kind: C cortex, D deep grey, B brainstem, X cerebellum. Hypoxia: hippocampus, thalamus, cortex,
-- striatum and the cerebellar vermis are the structures named as especially susceptible [S: K2];
-- the brainstem is given a low value [P].
------------------------------------------------------------------------------------------
local HEMI = {
	-- frontal
	{ "frontalpole", "frontal pole", "frontal", "C", "10", 0.25, 0.95, 0.00, 0.20, 0.6, 0.5, { aca_frontopolar = 0.6, mca_prefrontal = 0.4 } },
	{ "superiorfrontal", "superior frontal gyrus", "frontal", "C", "8/9", 0.20, 0.55, 0.75, 0.26, 0.7, 0.5, { aca_callosomarginal = 0.7, mca_prefrontal = 0.3 }, watershed = true },
	{ "sma", "supplementary motor area (own)", "frontal", "C", "6", 0.08, 0.20, 0.82, 0.16, 0.6, 0.7, { aca_callosomarginal = 1 } },
	{ "rostralmiddlefrontal", "rostral middle frontal gyrus", "frontal", "C", "9/46", 0.60, 0.65, 0.45, 0.26, 0.6, 0.5, { mca_prefrontal = 1 } },
	{ "caudalmiddlefrontal", "caudal middle frontal gyrus (premotor, frontal eye field)", "frontal", "C", "6/8", 0.62, 0.25, 0.66, 0.20, 0.7, 0.7, { mca_precentral = 0.8, aca_callosomarginal = 0.2 }, watershed = true },
	{ "parsopercularis", "inferior frontal gyrus, opercular part", "frontal", "C", "44", 0.90, 0.30, 0.12, 0.14, 0.6, 0.5, { mca_precentral = 0.6, mca_prefrontal = 0.4 } },
	{ "parstriangularis", "inferior frontal gyrus, triangular part", "frontal", "C", "45", 0.88, 0.45, 0.12, 0.14, 0.6, 0.5, { mca_prefrontal = 1 } },
	{ "parsorbitalis", "inferior frontal gyrus, orbital part", "frontal", "C", "47", 0.80, 0.56, -0.15, 0.13, 0.6, 0.5, { mca_orbitofrontal = 1 } },
	{ "lateralorbitofrontal", "lateral orbitofrontal cortex", "frontal", "C", "11/47", 0.55, 0.60, -0.42, 0.20, 0.6, 0.5, { mca_orbitofrontal = 0.8, aca_orbitofrontal = 0.2 } },
	{ "medialorbitofrontal", "medial orbitofrontal cortex", "frontal", "C", "11/12", 0.12, 0.65, -0.40, 0.18, 0.6, 0.5, { aca_orbitofrontal = 1 } },
	{ "precentral_face", "precentral gyrus, face and mouth zone (own)", "frontal", "C", "4", 0.92, 0.10, 0.15, 0.13, 0.7, 0.9, { mca_central = 1 } },
	{ "precentral_hand", "precentral gyrus, hand zone (own)", "frontal", "C", "4", 0.70, 0.05, 0.60, 0.13, 0.7, 0.9, { mca_central = 1 } },
	{ "precentral_arm", "precentral gyrus, arm and shoulder zone (own)", "frontal", "C", "4", 0.48, 0.02, 0.80, 0.13, 0.75, 0.9, { mca_central = 0.75, aca_paracentral = 0.25 }, watershed = true },
	{ "precentral_trunk", "precentral gyrus, trunk zone (own)", "frontal", "C", "4", 0.28, 0.00, 0.90, 0.12, 0.75, 0.8, { aca_paracentral = 0.6, mca_central = 0.4 }, watershed = true },
	{ "paracentral", "paracentral lobule (leg and foot)", "frontal", "C", "4/3", 0.07, -0.05, 0.90, 0.15, 0.6, 0.8, { aca_paracentral = 1 } },
	{ "rostralanteriorcingulate", "rostral anterior cingulate cortex", "limbic", "C", "24/32", 0.07, 0.60, 0.05, 0.15, 0.6, 0.5, { aca_callosomarginal = 0.5, aca_pericallosal = 0.5 } },
	{ "caudalanteriorcingulate", "caudal anterior cingulate cortex", "limbic", "C", "24", 0.07, 0.30, 0.35, 0.15, 0.6, 0.5, { aca_pericallosal = 0.6, aca_callosomarginal = 0.4 } },
	-- parietal
	{ "postcentral_face", "postcentral gyrus, face zone (own)", "parietal", "C", "3/1/2", 0.93, -0.05, 0.20, 0.13, 0.7, 0.6, { mca_central = 0.5, mca_parietal = 0.5 } },
	{ "postcentral_hand", "postcentral gyrus, hand and arm zone (own)", "parietal", "C", "3/1/2", 0.70, -0.10, 0.62, 0.15, 0.7, 0.6, { mca_central = 0.4, mca_parietal = 0.6 } },
	{ "postcentral_trunk", "postcentral gyrus, trunk zone (own)", "parietal", "C", "3/1/2", 0.33, -0.15, 0.90, 0.13, 0.75, 0.6, { aca_paracentral = 0.5, mca_parietal = 0.5 }, watershed = true },
	{ "superiorparietal", "superior parietal lobule", "parietal", "C", "5/7", 0.40, -0.45, 0.80, 0.24, 0.7, 0.4, { mca_parietal = 0.6, aca_pericallosal = 0.2, pca_parietooccipital = 0.2 }, watershed = true },
	{ "inferiorparietal", "inferior parietal lobule (angular gyrus)", "parietal", "C", "39", 0.80, -0.55, 0.45, 0.22, 0.7, 0.4, { mca_angular = 0.85, pca_parietooccipital = 0.15 }, watershed = true },
	{ "supramarginal", "supramarginal gyrus", "parietal", "C", "40", 0.90, -0.30, 0.40, 0.17, 0.6, 0.4, { mca_parietal = 0.6, mca_angular = 0.4 } },
	{ "precuneus", "precuneus", "parietal", "C", "7/31", 0.10, -0.50, 0.65, 0.20, 0.7, 0.4, { aca_pericallosal = 0.6, pca_parietooccipital = 0.4 }, watershed = true },
	{ "posteriorcingulate", "posterior cingulate cortex", "limbic", "C", "23/31", 0.07, -0.20, 0.40, 0.15, 0.6, 0.4, { aca_pericallosal = 1 } },
	{ "isthmuscingulate", "isthmus of the cingulate gyrus", "limbic", "C", "29/30", 0.10, -0.45, 0.10, 0.12, 0.6, 0.4, { pca_parietooccipital = 0.6, aca_pericallosal = 0.4 } },
	-- temporal
	{ "superiortemporal_ant", "superior temporal gyrus, front part (own)", "temporal", "C", "22/38", 0.92, 0.15, -0.20, 0.16, 0.6, 0.8, { mca_temporal_ant = 1 } },
	{ "superiortemporal_post", "superior temporal gyrus, rear part (own)", "temporal", "C", "22", 0.93, -0.30, 0.05, 0.16, 0.6, 0.8, { mca_temporal_post = 1 } },
	{ "transversetemporal", "transverse temporal gyrus (Heschl)", "temporal", "C", "41/42", 0.75, -0.10, 0.05, 0.11, 0.6, 0.6, { mca_temporal_post = 1 } },
	{ "bankssts", "banks of the superior temporal sulcus", "temporal", "C", "21/22", 0.90, -0.40, 0.00, 0.12, 0.6, 0.6, { mca_temporal_post = 1 } },
	{ "middletemporal", "middle temporal gyrus", "temporal", "C", "21", 0.95, -0.15, -0.35, 0.22, 0.6, 0.8, { mca_temporal_post = 0.6, mca_temporal_ant = 0.4 } },
	{ "inferiortemporal", "inferior temporal gyrus", "temporal", "C", "20", 0.85, -0.20, -0.60, 0.22, 0.6, 0.8, { mca_temporal_post = 0.5, pca_temporal = 0.5 }, watershed = true },
	{ "fusiform", "fusiform gyrus", "temporal", "C", "37", 0.50, -0.35, -0.70, 0.20, 0.6, 0.6, { pca_temporal = 1 } },
	{ "temporalpole", "temporal pole", "temporal", "C", "38", 0.65, 0.40, -0.60, 0.18, 0.6, 0.9, { mca_temporal_ant = 1 } },
	{ "entorhinal", "entorhinal cortex", "temporal", "C", "28/34", 0.35, 0.10, -0.65, 0.12, 0.9, 1.0, { pca_temporal = 0.6, acha = 0.4 } },
	{ "parahippocampal", "parahippocampal gyrus", "temporal", "C", "36", 0.35, -0.20, -0.60, 0.14, 0.8, 0.9, { pca_temporal = 1 } },
	-- occipital
	{ "pericalcarine", "pericalcarine cortex (primary visual)", "occipital", "C", "17", 0.10, -0.85, 0.00, 0.14, 0.7, 0.3, { pca_calcarine = 1 } },
	{ "cuneus", "cuneus", "occipital", "C", "17/18", 0.10, -0.85, 0.30, 0.14, 0.7, 0.3, { pca_calcarine = 0.7, pca_parietooccipital = 0.3 } },
	{ "lingual", "lingual gyrus", "occipital", "C", "17/18", 0.15, -0.75, -0.30, 0.15, 0.7, 0.3, { pca_calcarine = 0.7, pca_temporal = 0.3 } },
	{ "lateraloccipital", "lateral occipital cortex", "occipital", "C", "18/19", 0.60, -0.90, 0.00, 0.22, 0.7, 0.3, { pca_calcarine = 0.5, mca_angular = 0.5 }, watershed = true },
	-- insula
	{ "insula", "insula", "insular", "C", "13/14", 0.60, 0.10, 0.05, 0.18, 0.6, 0.6, { mca_insular = 1 } },
	-- deep grey
	{ "caudate", "caudate nucleus", "deep", "D", "", 0.20, 0.30, 0.20, 0.13, 0.8, 0.2, { heubner = 0.4, mca_lsa = 0.5, aca_perf = 0.1 } },
	{ "putamen", "putamen", "deep", "D", "", 0.42, 0.15, 0.00, 0.14, 0.8, 0.2, { mca_lsa = 0.85, heubner = 0.15 } },
	{ "pallidum", "globus pallidus", "deep", "D", "", 0.30, 0.08, -0.02, 0.10, 0.8, 0.2, { mca_lsa = 0.5, acha = 0.5 } },
	{ "thal_anterior", "thalamus, anterior part (tuberothalamic territory)", "deep", "D", "", 0.12, 0.00, 0.10, 0.09, 0.8, 0.3, { pcoa_tuberothalamic = 1 } },
	{ "thal_paramedian", "thalamus, paramedian part", "deep", "D", "", 0.06, -0.10, 0.05, 0.09, 0.8, 0.3, { pca_perf = 1 } },
	{ "thal_lateral", "thalamus, lateral part (inferolateral territory)", "deep", "D", "", 0.25, -0.12, 0.05, 0.10, 0.8, 0.3, { pca_thalamogeniculate = 1 } },
	{ "thal_posterior", "thalamus, posterior part (pulvinar, lateral geniculate)", "deep", "D", "", 0.25, -0.28, 0.02, 0.10, 0.8, 0.3, { pca_postchoroidal = 0.7, acha = 0.3 } },
	{ "hippocampus", "hippocampus", "temporal", "D", "", 0.45, -0.15, -0.45, 0.13, 1.0, 1.0, { pca_temporal = 0.5, pca_postchoroidal = 0.25, acha = 0.25 } },
	{ "amygdala", "amygdala", "temporal", "D", "", 0.42, 0.10, -0.45, 0.10, 0.8, 1.0, { acha = 0.6, mca_temporal_ant = 0.4 } },
	-- brainstem and cerebellum
	-- (the midbrain is fed from three sides: paramedian perforators, and short and long branches
	-- that run around it from the posterior cerebral and superior cerebellar arteries [P]; no one
	-- of them carries the tegmentum alone)
	{ "midbrain_teg", "midbrain tegmentum", "brainstem", "B", "", 0.10, -0.20, -0.45, 0.12, 0.3, 0.0, { pca_perf = 0.45, sca = 0.3, pca_postchoroidal = 0.25 } },
	{ "pons_teg", "pontine tegmentum", "brainstem", "B", "", 0.10, -0.32, -0.80, 0.14, 0.3, 0.0, { basilar_perf = 0.7, aica = 0.15, sca = 0.15 } },
	{ "medulla_teg", "medullary tegmentum (respiratory and autonomic centres)", "brainstem", "B", "", 0.07, -0.42, -1.25, 0.11, 0.3, 0.0, { vertebral_perf = 0.7, pica = 0.3 } },
	{ "medulla_lateral", "lateral medulla", "brainstem", "B", "", 0.22, -0.42, -1.25, 0.10, 0.3, 0.0, { pica = 0.6, vertebral_perf = 0.4 } },
	{ "cerebellum_sup", "cerebellar hemisphere, upper part", "cerebellum", "X", "", 0.45, -0.65, -0.70, 0.25, 0.7, 0.0, { sca = 1 } },
	{ "cerebellum_inf", "cerebellar hemisphere, lower part", "cerebellum", "X", "", 0.45, -0.70, -1.10, 0.25, 0.7, 0.0, { pica = 0.8, aica = 0.2 } },
}

-- Structures on the midline (one each). Their vessels are named with the side they hang on.
local MID = {
	{ "vermis", "cerebellar vermis", "cerebellum", "X", "", 0.0, -0.70, -0.85, 0.16, 0.9, 0.0, { L_sca = 0.25, R_sca = 0.25, L_pica = 0.25, R_pica = 0.25 } },
	{ "hypothalamus", "hypothalamus", "deep", "D", "", 0.0, 0.10, -0.30, 0.10, 0.5, 0.0, { L_pcoa_tuberothalamic = 0.25, R_pcoa_tuberothalamic = 0.25, L_aca_perf = 0.25, R_aca_perf = 0.25 } },
}

------------------------------------------------------------------------------------------
-- Tracts: bundles of fibres. A tract carries what passes through it; it is cut by a wound track
-- that crosses it, starved by its vessel, and thinned by a diffuse injury (dai: how much of a
-- full diffuse injury it loses; the corpus callosum and the upper brainstem are the places
-- diffuse axonal injury is graded by [S: S1]).
--   key, name, x, y, z, radius, dai, supply
------------------------------------------------------------------------------------------
local TRACT_HEMI = {
	{ "corona", "corona radiata", 0.40, 0.00, 0.45, 0.17, 0.25, { mca_lsa = 0.6, mca_central = 0.4 } },
	{ "ic_ant", "internal capsule, anterior limb", 0.30, 0.25, 0.08, 0.08, 0.15, { heubner = 0.6, mca_lsa = 0.4 } },
	{ "ic_genu", "internal capsule, genu", 0.27, 0.10, 0.05, 0.07, 0.15, { mca_lsa = 0.6, acha = 0.2, pcoa_tuberothalamic = 0.2 } },
	{ "ic_post", "internal capsule, posterior limb", 0.30, -0.03, 0.05, 0.08, 0.15, { mca_lsa = 0.5, acha = 0.5 } },
	{ "peduncle", "cerebral peduncle", 0.20, -0.15, -0.45, 0.09, 0.2, { pca_perf = 0.4, pca_postchoroidal = 0.2, acha = 0.4 } },
	{ "pons_base", "base of the pons", 0.12, -0.20, -0.85, 0.12, 0.1, { basilar_perf = 1 } },
	{ "pyramid", "medullary pyramid", 0.06, -0.30, -1.30, 0.07, 0.1, { vertebral_perf = 1 } },
	{ "optic_meyer", "optic radiation, temporal loop", 0.60, -0.30, -0.30, 0.12, 0.2, { mca_temporal_post = 0.5, acha = 0.3, pca_temporal = 0.2 } },
	{ "optic_parietal", "optic radiation, parietal part", 0.50, -0.50, 0.20, 0.12, 0.2, { mca_angular = 0.6, pca_parietooccipital = 0.4 } },
	{ "arcuate", "arcuate fasciculus / superior longitudinal fasciculus", 0.70, -0.10, 0.35, 0.15, 0.4, { mca_parietal = 0.5, mca_lsa = 0.5 } },
	{ "ventral", "ventral association fibres (uncinate, inferior fronto-occipital)", 0.65, 0.10, -0.35, 0.14, 0.4, { mca_temporal_ant = 0.5, mca_lsa = 0.5 } },
	{ "fornix", "fornix", 0.05, -0.10, 0.20, 0.07, 0.5, { aca_perf = 0.5, pca_postchoroidal = 0.5 } },
	{ "aras", "ascending arousal fibres", 0.08, -0.20, -0.30, 0.08, 0.6, { pca_perf = 1 } },
	{ "scp", "superior cerebellar peduncle", 0.10, -0.45, -0.60, 0.07, 0.6, { sca = 1 } },
	{ "mcp", "middle cerebellar peduncle", 0.30, -0.45, -0.85, 0.09, 0.2, { aica = 0.6, basilar_perf = 0.4 } },
	{ "icp", "inferior cerebellar peduncle", 0.20, -0.50, -1.10, 0.07, 0.2, { pica = 1 } },
}
local TRACT_MID = {
	{ "cc_genu", "corpus callosum, genu", 0.0, 0.45, 0.30, 0.10, 1.0, { L_aca_pericallosal = 0.5, R_aca_pericallosal = 0.5 } },
	{ "cc_body", "corpus callosum, body", 0.0, 0.00, 0.45, 0.14, 1.0, { L_aca_pericallosal = 0.5, R_aca_pericallosal = 0.5 } },
	{ "cc_splenium", "corpus callosum, splenium", 0.0, -0.45, 0.30, 0.10, 1.0, { L_pca_parietooccipital = 0.5, R_pca_parietooccipital = 0.5 } },
}
-- The spinal cord, as far as the game has a spine: Z-City keeps three organs for it (neck, upper
-- and lower spine), and the cord is three levels of two halves each (sv_spine.lua). A half carries
-- the fibres of its own side of the body: they have crossed in the pyramid [P]. The cord's own
-- arteries are not in this atlas: an empty supply stands for "the circulation as a whole"
-- (sv_vascular.lua). The positions continue the schematic downward and are far outside the head.
local TRACT_CORD = {
	{ "cord_cervical", "spinal cord, cervical level", 0.04, -0.36, -1.75, 0.05, 0, {}, cord = 1 },
	{ "cord_thoracic", "spinal cord, thoracic level", 0.04, -0.36, -2.60, 0.05, 0, {}, cord = 2 },
	{ "cord_lumbar", "spinal cord, lumbar level", 0.04, -0.36, -3.40, 0.05, 0, {}, cord = 3 },
}

------------------------------------------------------------------------------------------
-- Vessels: a tree per side from the internal carotid and the vertebral artery, joined by the circle
-- of Willis. The named branches and segments are those of [N30 N31 N32 N33 N57 N58 N59]; the
-- territories were cross-checked against the two-level arterial atlas of [N5] (anterior: frontal
-- and medial lenticulostriate; middle: frontal, parietal, temporal, occipital, insular and lateral
-- lenticulostriate; posterior: temporal, occipital and thalamoperforating; vertebrobasilar:
-- inferior and superior cerebellar and basilar). Which gyrus a cortical branch feeds, and the
-- territories of the recurrent artery of Heubner and of the anterior choroidal artery, are
-- standard anatomy not verified here from a fetched source [P].
--   key, name, parent, kind, x, y, z
-- kind: T trunk, S named segment, C cortical branch (has leptomeningeal collaterals [N7]),
-- P perforator (an end artery: no collaterals [S: N40]).
------------------------------------------------------------------------------------------
local VESSEL_HEMI = {
	{ "ica", "internal carotid artery", nil, "T", 0.15, 0.15, -0.55 },
	{ "acha", "anterior choroidal artery", "ica", "P", 0.30, 0.00, -0.30 },
	{ "pcoa", "posterior communicating artery", nil, "W", 0.12, 0.00, -0.42 },
	{ "pcoa_tuberothalamic", "tuberothalamic artery", "pcoa", "P", 0.12, 0.00, -0.10 },
	-- anterior cerebral
	{ "aca_a1", "anterior cerebral artery, A1", "ica", "S", 0.08, 0.25, -0.32 },
	{ "aca_perf", "medial lenticulostriate arteries", "aca_a1", "P", 0.10, 0.25, -0.15 },
	{ "aca_a2", "anterior cerebral artery, A2", "aca_a1", "S", 0.04, 0.50, 0.00 },
	{ "heubner", "recurrent artery of Heubner", "aca_a2", "P", 0.20, 0.30, -0.10 },
	{ "aca_orbitofrontal", "orbitofrontal branch (A2)", "aca_a2", "C", 0.08, 0.65, -0.35 },
	{ "aca_frontopolar", "frontopolar branch (A2)", "aca_a2", "C", 0.10, 0.90, 0.00 },
	{ "aca_a3", "anterior cerebral artery, A3", "aca_a2", "S", 0.03, 0.45, 0.40 },
	{ "aca_callosomarginal", "callosomarginal artery (internal frontal branches)", "aca_a3", "C", 0.03, 0.30, 0.65 },
	{ "aca_a4", "anterior cerebral artery, A4 / A5 (pericallosal)", "aca_a3", "S", 0.03, 0.05, 0.52 },
	{ "aca_paracentral", "paracentral branch", "aca_a4", "C", 0.05, -0.05, 0.85 },
	{ "aca_pericallosal", "pericallosal artery (parietal branches)", "aca_a4", "C", 0.04, -0.30, 0.55 },
	-- middle cerebral
	{ "mca_m1", "middle cerebral artery, M1", "ica", "S", 0.40, 0.15, -0.30 },
	{ "mca_lsa", "lateral lenticulostriate arteries", "mca_m1", "P", 0.38, 0.15, -0.10 },
	{ "mca_temporal_ant", "anterior temporal branch", "mca_m1", "C", 0.75, 0.30, -0.45 },
	{ "mca_sup", "middle cerebral artery, M2 superior division", "mca_m1", "S", 0.72, 0.22, 0.15 },
	{ "mca_inf", "middle cerebral artery, M2 inferior division", "mca_m1", "S", 0.78, -0.12, -0.08 },
	{ "mca_insular", "insular branches (M2)", "mca_sup", "C", 0.62, 0.10, 0.05 },
	{ "mca_orbitofrontal", "orbitofrontal branch", "mca_sup", "C", 0.70, 0.58, -0.30 },
	{ "mca_prefrontal", "prefrontal branch", "mca_sup", "C", 0.75, 0.55, 0.30 },
	{ "mca_precentral", "precentral branch", "mca_sup", "C", 0.80, 0.28, 0.45 },
	{ "mca_central", "central branch", "mca_sup", "C", 0.82, 0.05, 0.45 },
	{ "mca_parietal", "postcentral and parietal branches", "mca_sup", "C", 0.85, -0.25, 0.50 },
	{ "mca_angular", "angular branch", "mca_inf", "C", 0.85, -0.55, 0.35 },
	{ "mca_temporal_post", "middle and posterior temporal branches", "mca_inf", "C", 0.92, -0.25, -0.15 },
	-- vertebrobasilar and posterior cerebral
	{ "vertebral", "vertebral artery", nil, "T", 0.10, -0.30, -1.45 },
	{ "vertebral_perf", "medullary branches (anterior spinal, paramedian)", "vertebral", "P", 0.06, -0.35, -1.28 },
	{ "pica", "posterior inferior cerebellar artery", "vertebral", "C", 0.30, -0.60, -1.15 },
	{ "basilar_half", "basilar artery, share of this side", nil, "W", 0.03, -0.18, -0.85 },
	{ "basilar_perf", "pontine perforators", "basilar_half", "P", 0.08, -0.22, -0.82 },
	{ "aica", "anterior inferior cerebellar artery", "basilar_half", "C", 0.30, -0.45, -0.92 },
	{ "sca", "superior cerebellar artery", "basilar_half", "C", 0.30, -0.50, -0.60 },
	{ "pca_p1", "posterior cerebral artery, P1", nil, "W", 0.08, -0.20, -0.45 },
	{ "pca_perf", "paramedian thalamoperforating arteries (P1)", "pca_p1", "P", 0.07, -0.15, -0.20 },
	{ "pca_p2", "posterior cerebral artery, P2", "pca_p1", "S", 0.25, -0.30, -0.45 },
	{ "pca_thalamogeniculate", "thalamogeniculate arteries (P2)", "pca_p2", "P", 0.25, -0.15, -0.10 },
	{ "pca_postchoroidal", "posterior choroidal arteries (P2)", "pca_p2", "P", 0.25, -0.30, -0.10 },
	{ "pca_p3", "posterior cerebral artery, P3", "pca_p2", "S", 0.30, -0.50, -0.40 },
	{ "pca_temporal", "inferior temporal branches (P3)", "pca_p3", "C", 0.45, -0.40, -0.65 },
	{ "pca_p4", "posterior cerebral artery, P4", "pca_p3", "S", 0.15, -0.70, -0.10 },
	{ "pca_calcarine", "calcarine artery (P4)", "pca_p4", "C", 0.10, -0.82, 0.00 },
	{ "pca_parietooccipital", "parieto-occipital artery (P4)", "pca_p4", "C", 0.12, -0.75, 0.35 },
}

-- The circle of Willis [S: N33]: how blood can reach a segment whose own feeder is shut.
-- A node receives from its sources; each link has a capacity (1 = as good as the feeder itself)
-- that is drawn once per character: how well collaterals hold decides how severe an occlusion turns
-- out [S: N7]; that they differ from person to person is standard knowledge not in the abstract [P].
--   node, { from, default capacity, spread }
A.willis = {
	{ "ica",          { { "SRC", 1.0, 0 } } },
	{ "vertebral",    { { "SRC", 1.0, 0 } } },
	{ "basilar_half", { { "vertebral", 1.0, 0 }, { "vertebral*", 0.9, 0.1 } } },                       -- both vertebrals fill the basilar
	{ "pca_p1",       { { "basilar_half", 1.0, 0 }, { "pcoa", 0.5, 0.35 } } },                         -- [N58]: P1 from the basilar, or through the PCoA
	{ "pcoa",         { { "ica", 0.6, 0.3 }, { "pca_p1", 0.6, 0.3 } } },
	-- (a perforator that leaves the communicating artery needs little: it fills from either end at
	-- full flow as long as the artery it leaves is open, whatever that artery can carry across)
	{ "pcoa_tuberothalamic", { { "ica", 1.0, 0 }, { "pca_p1", 1.0, 0 } }, via = "pcoa" },
	{ "aca_a1",       { { "ica", 1.0, 0 }, { "aca_a1*", 0.7, 0.3 } } },                                -- the anterior communicating artery joins the two sides
	{ "mca_m1",       { { "ica", 1.0, 0 }, { "aca_a1", 0.5, 0.25 }, { "pcoa", 0.35, 0.25 } } },        -- an occluded carotid: through ACoA and PCoA
}

-- Leptomeningeal neighbours: a cortical branch whose feeder is shut still gets a share through the
-- surface arteries of the neighbouring territories [S: N7]; the size of the share is ours [G].
A.lepto = {
	aca = { "mca", "pca" }, mca = { "aca", "pca" }, pca = { "mca", "aca" },
}
A.leptoShare = 0.3

-- Veins and other vessels that matter to trauma [N50 N85 S3 S4]: places a fracture or a wound
-- track can open. They carry no perfusion in the model.
A.venous = {
	{ "sss", "superior sagittal sinus", 0.0, 0.0, 1.0, 0.12, "venous" },
	{ "transverse_L", "left transverse sinus", 0.6, -0.9, -0.5, 0.10, "venous" },
	{ "transverse_R", "right transverse sinus", -0.6, -0.9, -0.5, 0.10, "venous" },
	{ "straight", "straight sinus", 0.0, -0.7, -0.2, 0.08, "venous" },
	{ "mma_L", "left middle meningeal artery (at the pterion)", 1.0, 0.25, 0.0, 0.14, "epidural" },
	{ "mma_R", "right middle meningeal artery (at the pterion)", -1.0, 0.25, 0.0, 0.14, "epidural" },
}

------------------------------------------------------------------------------------------
-- Build: both hemispheres from the templates.
------------------------------------------------------------------------------------------
A.regions, A.regionOf = {}, {}       -- [id] = region ; [key] = id
A.tracts, A.tractOf = {}, {}
A.vessels, A.vesselOf = {}, {}

local function Supply(src, side)
	local out = {}
	for k, v in pairs(src) do
		if string.sub(k, 1, 2) == "L_" or string.sub(k, 1, 2) == "R_" then out[k] = v else out[side .. "_" .. k] = v end
	end
	return out
end

local function AddRegion(row, side)
	local key = side and (side .. "_" .. row[1]) or row[1]
	local sx = side == "R" and -1 or 1
	local r = {
		id = #A.regions + 1, key = key, base = row[1], name = (side == "L" and "left " or side == "R" and "right " or "") .. row[2],
		side = side or "M", lobe = row[3], kind = row[4], brodmann = row[5],
		x = row[6] * sx, y = row[7], z = row[8], radius = row[9], hypoxia = row[10], seizure = row[11],
		supply = Supply(row[12], side or "L"), watershed = row.watershed or false,
	}
	A.regions[r.id] = r
	A.regionOf[key] = r.id
end

local function AddTract(row, side)
	local key = side and (side .. "_" .. row[1]) or row[1]
	local sx = side == "R" and -1 or 1
	local t = {
		id = #A.tracts + 1, key = key, base = row[1], name = (side == "L" and "left " or side == "R" and "right " or "") .. row[2],
		side = side or "M", x = row[3] * sx, y = row[4], z = row[5], radius = row[6], dai = row[7], supply = Supply(row[8], side or "L"),
		cord = row.cord,
	}
	A.tracts[t.id] = t
	A.tractOf[key] = t.id
end

local function AddVessel(row, side)
	local key = side .. "_" .. row[1]
	local sx = side == "R" and -1 or 1
	local base = row[1]
	local v = {
		id = #A.vessels + 1, key = key, base = base, name = (side == "L" and "left " or "right ") .. row[2], side = side,
		parent = row[3] and (side .. "_" .. row[3]) or nil, kind = row[4], x = row[5] * sx, y = row[6], z = row[7],
		major = string.sub(base, 1, 3) == "aca" and "aca" or string.sub(base, 1, 3) == "mca" and "mca" or string.sub(base, 1, 3) == "pca" and "pca"
			or (base == "heubner" and "aca") or ((base == "acha" or base == "ica" or base == "pcoa" or base == "pcoa_tuberothalamic") and "ica") or "vb",
	}
	A.vessels[v.id] = v
	A.vesselOf[key] = v.id
end

for _, side in ipairs({ "L", "R" }) do
	for _, row in ipairs(HEMI) do AddRegion(row, side) end
	for _, row in ipairs(TRACT_HEMI) do AddTract(row, side) end
	for _, row in ipairs(VESSEL_HEMI) do AddVessel(row, side) end
end
for _, row in ipairs(MID) do AddRegion(row, nil) end
for _, row in ipairs(TRACT_MID) do AddTract(row, nil) end
for _, side in ipairs({ "L", "R" }) do
	for _, row in ipairs(TRACT_CORD) do AddTract(row, side) end
end

-- children of each vessel, and for every region and tract its supply by vessel id
for _, v in ipairs(A.vessels) do v.children = {} end
for _, v in ipairs(A.vessels) do
	if v.parent then
		local p = A.vessels[A.vesselOf[v.parent]]
		v.parentId = p.id
		p.children[#p.children + 1] = v.id
	end
end
local function ResolveSupply(obj)
	local list = {}
	for key, share in pairs(obj.supply) do
		local id = A.vesselOf[key]
		if id then list[#list + 1] = { id, share } end
	end
	obj.supplyIds = list
end
for _, r in ipairs(A.regions) do ResolveSupply(r) end
for _, t in ipairs(A.tracts) do ResolveSupply(t) end

function A.Region(key) return A.regions[A.regionOf[key] or 0] end
function A.Tract(key) return A.tracts[A.tractOf[key] or 0] end
function A.Vessel(key) return A.vessels[A.vesselOf[key] or 0] end

------------------------------------------------------------------------------------------
-- Functional channels. A channel is what the brain can still do in one respect, 0..1. It is a
-- chain of stages that all have to work (their capacities multiply); a stage is a set of
-- structures that share the work: capacity = weighted sum of what each still does, divided by
-- (1 - reserve), capped at 1. The reserve is how much of a stage can be lost before anything
-- shows: a distributed function has one, a narrow passage for all fibres has almost none.
--
-- Names inside a stage: "r:" a region, "t:" a tract, and a side letter in front of the key:
--   C  the side opposite the body part (or the visual field)     I  the same side
--   D  the hemisphere dominant for language                      N  the other one
--   L / R  that side; no letter: a midline structure
-- Channels with "sides" exist once for the left and once for the right body side or field.
------------------------------------------------------------------------------------------
-- A level of the spinal cord as a stage: the half of the limb's own side, or both halves for what
-- both sides drive.
local function Cord(level, both)
	if both then return { reserve = 0.25, name = level .. " cord, both halves", { "t:L_cord_" .. level, 0.5 }, { "t:R_cord_" .. level, 0.5 } } end
	return { reserve = 0.05, name = level .. " cord", { "t:I_cord_" .. level, 1 } }
end

local function Motor(zone, zoneW, extra, cord)
	-- The pathway of voluntary movement [S: N34 N65 N86 N24 N25]: motor cortex of the opposite
	-- side with premotor and supplementary areas, then every fibre through the corona radiata, the
	-- posterior limb of the internal capsule, the cerebral peduncle, the base of the pons and the
	-- pyramid, where most fibres cross. The small share of the same side stands for the fibres
	-- that do not cross [P]. Below the pyramid: the cord, on the limb's own side, down to the
	-- level at which the limb's nerves leave it (the arm at the neck, the leg at the lower back [P]).
	local cortex = { reserve = 0.12, name = "motor cortex", { "r:C_" .. zone, zoneW }, { "r:C_caudalmiddlefrontal", 0.07 }, { "r:C_sma", 0.07 }, { "r:I_" .. zone, 0.05 } }
	if extra then cortex[#cortex + 1] = extra end
	local sum = 0
	for _, c in ipairs(cortex) do sum = sum + c[2] end
	for _, c in ipairs(cortex) do c[2] = c[2] / sum end
	local stages = {
		cortex,
		{ reserve = 0.10, name = "corona radiata", { "t:C_corona", 1 } },
		{ reserve = 0.05, name = "internal capsule", { "t:C_ic_post", 1 } },
		{ reserve = 0.10, name = "cerebral peduncle", { "t:C_peduncle", 1 } },
		{ reserve = 0.10, name = "base of the pons", { "t:C_pons_base", 1 } },
		{ reserve = 0.10, name = "pyramid", { "t:C_pyramid", 1 } },
	}
	for _, level in ipairs(cord) do stages[#stages + 1] = Cord(level) end
	return stages
end
local ARM, LEG = { "cervical" }, { "cervical", "thoracic", "lumbar" }

A.channels = {
	-- Strength of the limbs. The leg lies on the inner face of the hemisphere (anterior cerebral
	-- artery), face, hand and arm on the outer (middle cerebral artery): an anterior cerebral
	-- infarct weakens the leg most [S: N18 N19], a middle cerebral one the face and arm [S: N30 N23].
	{ key = "hand", sides = true, group = "motor", stages = Motor("precentral_hand", 0.78, { "r:C_postcentral_hand", 0.03 }, ARM) },
	{ key = "arm", sides = true, group = "motor", stages = Motor("precentral_arm", 0.75, { "r:C_precentral_hand", 0.06 }, ARM) },
	{ key = "leg", sides = true, group = "motor", stages = Motor("paracentral", 0.81, nil, LEG) },
	-- The trunk is moved by both hemispheres [S: N34]: one side lost shows little.
	{ key = "trunk", group = "motor", stages = {
		{ reserve = 0.45, name = "motor cortex", { "r:L_precentral_trunk", 0.4 }, { "r:R_precentral_trunk", 0.4 }, { "r:L_sma", 0.1 }, { "r:R_sma", 0.1 } },
		{ reserve = 0.45, name = "descending fibres", { "t:L_ic_post", 0.25 }, { "t:R_ic_post", 0.25 }, { "t:L_pons_base", 0.25 }, { "t:R_pons_base", 0.25 } },
		Cord("cervical", true), Cord("thoracic", true),
	} },
	-- The lower face follows the opposite hemisphere's outer surface; the upper face is also
	-- represented on the inner surface, which is why a middle cerebral stroke spares eye closure
	-- and an anterior cerebral one can weaken it [S: N23]. The facial nucleus itself lies in the
	-- pons of the same side [P]; corticobulbar fibres run through the genu [S: N81].
	{ key = "face", sides = true, group = "motor", stages = {
		{ reserve = 0.10, name = "motor cortex (face)", { "r:C_precentral_face", 0.80 }, { "r:C_caudalmiddlefrontal", 0.08 }, { "r:I_precentral_face", 0.12 } },
		{ reserve = 0.05, name = "internal capsule (genu)", { "t:C_ic_genu", 1 } },
		{ reserve = 0.10, name = "cerebral peduncle", { "t:C_peduncle", 1 } },
		{ reserve = 0.30, name = "facial nucleus (pons)", { "r:I_pons_teg", 1 } },
	} },
	{ key = "eyelid", sides = true, group = "motor", stages = {
		{ reserve = 0.45, name = "motor cortex (upper face)", { "r:C_precentral_face", 0.3 }, { "r:C_sma", 0.2 }, { "r:C_caudalanteriorcingulate", 0.1 }, { "r:I_precentral_face", 0.2 }, { "r:I_sma", 0.2 } },
		{ reserve = 0.30, name = "facial nucleus (pons)", { "r:I_pons_teg", 1 } },
	} },
	-- Getting a movement started: basal ganglia and the supplementary motor area [S: N44]; a loss
	-- slows and shrinks movement, it does not paralyse [P].
	{ key = "initiation", sides = true, group = "motor", stages = {
		{ reserve = 0.25, name = "basal ganglia loop", { "r:C_putamen", 0.35 }, { "r:C_caudate", 0.15 }, { "r:C_pallidum", 0.2 }, { "r:C_thal_lateral", 0.15 }, { "r:C_sma", 0.15 } },
	} },
	-- Coordination of a limb: a cerebellar hemisphere [S: N43 N73], the one of the SAME side [P], its
	-- peduncles, and the relay in the opposite thalamus.
	{ key = "coordination", sides = true, group = "motor", stages = {
		{ reserve = 0.15, name = "cerebellar hemisphere", { "r:I_cerebellum_sup", 0.5 }, { "r:I_cerebellum_inf", 0.5 } },
		{ reserve = 0.15, name = "cerebellar peduncles", { "t:I_scp", 0.5 }, { "t:I_mcp", 0.35 }, { "t:I_icp", 0.15 } },
		{ reserve = 0.40, name = "thalamic relay", { "r:C_thal_lateral", 1 } },
	} },
	-- Balance and gait: the midline of the cerebellum [S: N73], the vestibular part of the lateral
	-- medulla [S: N41], and feeling in the legs.
	{ key = "balance", group = "motor", stages = {
		{ reserve = 0.15, name = "vermis and lower cerebellum", { "r:vermis", 0.5 }, { "r:L_cerebellum_inf", 0.15 }, { "r:R_cerebellum_inf", 0.15 }, { "r:L_cerebellum_sup", 0.1 }, { "r:R_cerebellum_sup", 0.1 } },
		{ reserve = 0.35, name = "vestibular nuclei and inferior peduncles", { "r:L_medulla_lateral", 0.3 }, { "r:R_medulla_lateral", 0.3 }, { "t:L_icp", 0.2 }, { "t:R_icp", 0.2 } },
	} },
	-- Feeling of one side of the body: lateral thalamus, posterior limb, postcentral gyrus of the
	-- opposite side [S: N48 N83 N22]; pain and temperature of the body also cross the lateral
	-- medulla of the opposite side [S: N41].
	{ key = "sensation", sides = true, group = "sensory", stages = {
		{ reserve = 0.30, name = "brainstem pathways", { "r:C_medulla_lateral", 0.3 }, { "r:C_pons_teg", 0.35 }, { "r:C_midbrain_teg", 0.35 } },
		{ reserve = 0.10, name = "lateral thalamus", { "r:C_thal_lateral", 1 } },
		{ reserve = 0.10, name = "internal capsule", { "t:C_ic_post", 1 } },
		{ reserve = 0.15, name = "postcentral gyrus", { "r:C_postcentral_hand", 0.4 }, { "r:C_postcentral_face", 0.2 }, { "r:C_postcentral_trunk", 0.15 }, { "r:C_paracentral", 0.25 } },
	} },
	-- Sight of one half-field, upper and lower quarter: geniculate body, radiation and the primary
	-- visual cortex of the opposite side; damage behind the chiasm takes the same half from both
	-- eyes, most often in the occipital lobe or the radiation [S: N38 N17 N82]. That the lower
	-- bank of the calcarine fissure and the temporal loop carry the upper field is standard
	-- anatomy [P].
	{ key = "vision_upper", sides = true, group = "sensory", stages = {
		{ reserve = 0.10, name = "lateral geniculate body", { "r:C_thal_posterior", 1 } },
		{ reserve = 0.10, name = "optic radiation (temporal loop)", { "t:C_optic_meyer", 1 } },
		{ reserve = 0.05, name = "visual cortex (lower bank)", { "r:C_pericalcarine", 0.6 }, { "r:C_lingual", 0.4 } },
	} },
	{ key = "vision_lower", sides = true, group = "sensory", stages = {
		{ reserve = 0.10, name = "lateral geniculate body", { "r:C_thal_posterior", 1 } },
		{ reserve = 0.10, name = "optic radiation (parietal part)", { "t:C_optic_parietal", 1 } },
		{ reserve = 0.05, name = "visual cortex (upper bank)", { "r:C_pericalcarine", 0.6 }, { "r:C_cuneus", 0.4 } },
	} },
	-- Hearing reaches both hemispheres from each ear: one side lost is hardly noticed, both lost
	-- is cortical deafness [P]. The inner ear and the lateral pons hang on the anterior inferior
	-- cerebellar artery [P].
	{ key = "hearing", group = "sensory", stages = {
		{ reserve = 0.50, name = "auditory cortex", { "r:L_transversetemporal", 0.5 }, { "r:R_transversetemporal", 0.5 } },
		{ reserve = 0.50, name = "brainstem auditory pathway", { "r:L_pons_teg", 0.5 }, { "r:R_pons_teg", 0.5 } },
	} },
	-- Language is a network around the Sylvian fissure of the dominant hemisphere, not two
	-- centres [S: N10 N11 N35]. Production runs through the dorsal stream: inferior frontal gyrus
	-- (areas 44 and 45 [S: N63]), the junction of temporal and parietal lobe, and the fibres
	-- between; starting to speak needs the inner frontal surface (an anterior cerebral infarct on
	-- the left can leave a patient mute [S: N18]); the deep nuclei contribute a little [S: N35].
	{ key = "language_production", group = "language", stages = {
		{ reserve = 0.12, name = "dominant frontal language cortex", { "r:D_parsopercularis", 0.36 }, { "r:D_parstriangularis", 0.24 }, { "r:D_insula", 0.14 }, { "r:D_precentral_face", 0.14 }, { "r:D_rostralmiddlefrontal", 0.12 } },
		{ reserve = 0.20, name = "dominant temporo-parietal language cortex", { "r:D_superiortemporal_post", 0.4 }, { "r:D_supramarginal", 0.3 }, { "r:D_middletemporal", 0.15 }, { "r:D_inferiorparietal", 0.15 } },
		{ reserve = 0.25, name = "dorsal stream fibres", { "t:D_arcuate", 1 } },
		{ reserve = 0.35, name = "initiation (inner frontal surface)", { "r:D_sma", 0.6 }, { "r:D_caudalanteriorcingulate", 0.2 }, { "r:D_superiorfrontal", 0.2 } },
		{ reserve = 0.55, name = "deep nuclei", { "r:D_thal_anterior", 0.4 }, { "r:D_caudate", 0.3 }, { "r:D_putamen", 0.3 } },
	} },
	-- Understanding runs through the ventral stream in the temporal lobes, with a share of the
	-- other hemisphere [S: N10]; the rear of the dominant superior temporal gyrus is where a lesion
	-- costs it most [S: N36 N64].
	{ key = "language_comprehension", group = "language", stages = {
		{ reserve = 0.12, name = "temporal language cortex", { "r:D_superiortemporal_post", 0.42 }, { "r:D_middletemporal", 0.2 }, { "r:D_bankssts", 0.1 }, { "r:D_inferiorparietal", 0.12 }, { "r:N_superiortemporal_post", 0.1 }, { "r:N_middletemporal", 0.06 } },
		{ reserve = 0.35, name = "ventral stream fibres", { "t:D_ventral", 1 } },
	} },
	-- Saying back what was heard: the junction area and the fibres to the frontal lobe [S: N78].
	{ key = "language_repetition", group = "language", stages = {
		{ reserve = 0.10, name = "temporo-parietal junction", { "r:D_supramarginal", 0.6 }, { "r:D_superiortemporal_post", 0.4 } },
		{ reserve = 0.10, name = "dorsal stream fibres", { "t:D_arcuate", 1 } },
	} },
	-- Reading: the visual word area and the angular gyrus of the dominant side [S: N77 N35].
	{ key = "reading", group = "language", stages = {
		{ reserve = 0.15, name = "dominant occipito-temporal and angular cortex", { "r:D_fusiform", 0.45 }, { "r:D_inferiorparietal", 0.35 }, { "r:D_lateraloccipital", 0.2 } },
	} },
	-- Writing as language (spelling, word order), apart from the hand that types [S: N79 N61].
	{ key = "writing", group = "language", stages = {
		{ reserve = 0.15, name = "dominant parietal and frontal writing cortex", { "r:D_inferiorparietal", 0.3 }, { "r:D_supramarginal", 0.25 }, { "r:D_superiorparietal", 0.2 }, { "r:D_caudalmiddlefrontal", 0.25 } },
	} },
	-- The muscles of speech are driven from both hemispheres [S: N81]; slurring comes with loss on
	-- both sides, with the cerebellum, or with the brainstem [S: N49].
	{ key = "articulation", group = "language", stages = {
		{ reserve = 0.40, name = "motor cortex (mouth), both sides", { "r:L_precentral_face", 0.5 }, { "r:R_precentral_face", 0.5 } },
		{ reserve = 0.40, name = "corticobulbar fibres", { "t:L_ic_genu", 0.5 }, { "t:R_ic_genu", 0.5 } },
		{ reserve = 0.30, name = "cerebellum", { "r:vermis", 0.4 }, { "r:L_cerebellum_sup", 0.3 }, { "r:R_cerebellum_sup", 0.3 } },
		{ reserve = 0.30, name = "bulbar nuclei", { "r:L_medulla_lateral", 0.25 }, { "r:R_medulla_lateral", 0.25 }, { "r:L_pons_teg", 0.25 }, { "r:R_pons_teg", 0.25 } },
	} },
	-- New memories: both hippocampi and their connections [S: N69]; the thalamus too (thalamic
	-- infarcts leave a lasting loss [S: N22]). One side lost shows little [P].
	{ key = "memory", group = "cognition", stages = {
		{ reserve = 0.45, name = "hippocampal formation", { "r:L_hippocampus", 0.4 }, { "r:R_hippocampus", 0.4 }, { "r:L_entorhinal", 0.05 }, { "r:R_entorhinal", 0.05 }, { "r:L_parahippocampal", 0.05 }, { "r:R_parahippocampal", 0.05 } },
		{ reserve = 0.40, name = "fornix and thalamus", { "t:L_fornix", 0.2 }, { "t:R_fornix", 0.2 }, { "r:L_thal_anterior", 0.15 }, { "r:R_thal_anterior", 0.15 }, { "r:L_thal_paramedian", 0.15 }, { "r:R_thal_paramedian", 0.15 } },
	} },
	-- Attention: networks of frontal and parietal cortex on both sides [S: N15].
	{ key = "attention", group = "cognition", stages = {
		{ reserve = 0.30, name = "fronto-parietal attention cortex", { "r:L_superiorparietal", 0.15 }, { "r:R_superiorparietal", 0.15 }, { "r:L_caudalmiddlefrontal", 0.1 }, { "r:R_caudalmiddlefrontal", 0.1 },
			{ "r:N_supramarginal", 0.15 }, { "r:N_inferiorparietal", 0.15 }, { "r:N_parsopercularis", 0.1 }, { "r:L_rostralmiddlefrontal", 0.05 }, { "r:R_rostralmiddlefrontal", 0.05 } },
	} },
	-- Planning, judgement, drive: prefrontal cortex of both sides [S: N68]; loss of drive goes with
	-- the frontal pole, the cingulate and the superior frontal gyrus [S: N19 N62].
	{ key = "executive", group = "cognition", stages = {
		{ reserve = 0.30, name = "prefrontal cortex", { "r:L_rostralmiddlefrontal", 0.14 }, { "r:R_rostralmiddlefrontal", 0.14 }, { "r:L_lateralorbitofrontal", 0.08 }, { "r:R_lateralorbitofrontal", 0.08 },
			{ "r:L_medialorbitofrontal", 0.06 }, { "r:R_medialorbitofrontal", 0.06 }, { "r:L_frontalpole", 0.08 }, { "r:R_frontalpole", 0.08 }, { "r:L_superiorfrontal", 0.08 }, { "r:R_superiorfrontal", 0.08 },
			{ "r:L_parstriangularis", 0.03 }, { "r:R_parstriangularis", 0.03 }, { "r:L_parsorbitalis", 0.03 }, { "r:R_parsorbitalis", 0.03 } },
		{ reserve = 0.45, name = "frontal deep loops", { "r:L_caudate", 0.25 }, { "r:R_caudate", 0.25 }, { "r:L_thal_anterior", 0.15 }, { "r:R_thal_anterior", 0.15 }, { "t:L_ic_ant", 0.1 }, { "t:R_ic_ant", 0.1 } },
	} },
	{ key = "drive", group = "cognition", stages = {
		{ reserve = 0.35, name = "inner frontal cortex", { "r:L_superiorfrontal", 0.15 }, { "r:R_superiorfrontal", 0.15 }, { "r:L_rostralanteriorcingulate", 0.1 }, { "r:R_rostralanteriorcingulate", 0.1 },
			{ "r:L_caudalanteriorcingulate", 0.1 }, { "r:R_caudalanteriorcingulate", 0.1 }, { "r:L_frontalpole", 0.1 }, { "r:R_frontalpole", 0.1 }, { "r:L_sma", 0.05 }, { "r:R_sma", 0.05 } },
	} },
	-- Being awake needs the tegmentum of the upper pons and the midbrain (A.arousal below) and
	-- the paramedian thalamus of both sides, which belongs to the same system (its infarction
	-- lowers consciousness [S: N20 N39]).
	{ key = "arousal_thalamus", group = "vital", stages = {
		{ reserve = 0.42, name = "ascending arousal fibres, both sides", { "t:L_aras", 0.5 }, { "t:R_aras", 0.5 } },
		{ reserve = 0.42, name = "paramedian thalamus, both sides", { "r:L_thal_paramedian", 0.5 }, { "r:R_thal_paramedian", 0.5 } },
	} },
	-- Breathing and circulation are driven from the medulla [S: N67]; the hypothalamus and the
	-- insula colour the autonomic output [R: K3, title only].
	{ key = "respiration", group = "vital", stages = {
		{ reserve = 0.25, name = "medullary respiratory centres", { "r:L_medulla_teg", 0.5 }, { "r:R_medulla_teg", 0.5 } },
		{ reserve = 0.55, name = "pontine respiratory groups", { "r:L_pons_teg", 0.5 }, { "r:R_pons_teg", 0.5 } },
	} },
	{ key = "autonomic", group = "vital", stages = {
		{ reserve = 0.25, name = "medullary autonomic centres", { "r:L_medulla_teg", 0.4 }, { "r:R_medulla_teg", 0.4 }, { "r:L_medulla_lateral", 0.1 }, { "r:R_medulla_lateral", 0.1 } },
		{ reserve = 0.50, name = "hypothalamus and insula", { "r:hypothalamus", 0.5 }, { "r:L_insula", 0.25 }, { "r:R_insula", 0.25 } },
	} },
}

-- What a character can be doing, by what asks for it, and the channels each runs through: the
-- developer's trace and drawings (sv_braincmd.lua, cl_signal.lua, cl_brainview.lua). `out`: the
-- channels whose values are what the action gets done with. The game itself does not read this.
A.actions = {
	{ key = "walk", keys = "W A S D", name = "walking", channels = { "legL", "legR", "balance", "trunk", "coordinationL", "coordinationR" }, out = { "legL", "legR", "trunk", "balance" } },
	{ key = "run", keys = "SHIFT", name = "running", channels = { "armL", "armR" }, out = { "legL", "legR" } },
	{ key = "jump", keys = "SPACE", name = "jumping", channels = { "legL", "legR", "trunk" }, out = { "legL", "legR" } },
	{ key = "attack", keys = "MOUSE1", name = "pulling the trigger", channels = { "handR", "armR", "coordinationR", "vision_upperL", "vision_upperR", "attention" }, out = { "handR", "armR" } },
	{ key = "aim", keys = "MOUSE2", name = "aiming", channels = { "handL", "armL", "attention" }, out = { "handL", "armL" } },
	{ key = "use", keys = "E", name = "using", channels = { "handR", "armR" }, out = { "handR", "armR" } },
	{ key = "typing", keys = "CHAT", name = "typing", channels = { "language_production", "writing", "handL", "handR", "attention" }, out = { "language_production", "writing", "handL", "handR" } },
	{ key = "speaking", keys = "VOICE", name = "speaking", channels = { "language_production", "articulation" }, out = { "language_production", "articulation" } },
}
A.channelNames = {
	legL = "left leg", legR = "right leg", armL = "left arm", armR = "right arm", handL = "left hand", handR = "right hand", trunk = "trunk",
	balance = "balance", language_production = "finding and forming words", writing = "spelling", articulation = "articulation",
}

-- Unilateral neglect: after lesions of the hemisphere NOT dominant for language, chiefly its
-- lower parietal, upper temporal and lower frontal cortex [S: N15]; the opposite half of space is
-- ignored. The same lesion on the dominant side does it far less often [S: N15]; the share is ours.
A.neglect = {
	regions = { { "supramarginal", 0.3 }, { "inferiorparietal", 0.25 }, { "superiortemporal_post", 0.2 }, { "parsopercularis", 0.15 }, { "insula", 0.1 } },
	from = 0.3, dominantShare = 0.3,
}

-- Arousal from the brainstem. Coma followed lesions of the tegmentum of the upper pons, or of the
-- upper pons and the midbrain, and nearly always of both sides; lesions outside the tegmentum or
-- small ones of one side did not cause it [S: N14]. The model keeps one load for it: at each level
-- the lesser-damaged side counts for most (oneSide is the share of the worse side alone [G]), and
-- the worse level decides. A primary brainstem injury (rotation) is one number for the whole
-- brainstem and enters the same load directly (sv_brain.lua).
A.arousal = { levels = { "midbrain_teg", "pons_teg" }, oneSide = 0.35 }

-- A sum over all cortex: how much of the cerebral mantle still works (for consciousness: only a
-- loss on both sides and nearly everywhere takes it [P]).
A.cortexIds = { L = {}, R = {} }
for _, r in ipairs(A.regions) do
	if r.kind == "C" and A.cortexIds[r.side] then
		local list = A.cortexIds[r.side]
		list[#list + 1] = r.id
	end
end

-- Language dominance by handedness: the right hemisphere leads in 4 % of strong right-handers,
-- 15 % of the ambidextrous, 27 % of strong left-handers [S: N16]. Nine people in ten are taken as
-- right-handed [G].
A.dominance = { rightHanded = 0.9, rightDominantIfRight = 0.04, rightDominantIfLeft = 0.27 }

------------------------------------------------------------------------------------------
-- The channels resolved to ids, once for each language-dominant hemisphere. A channel with sides
-- becomes two: key .. "L" for the left side of the body (or the left half of the field), key .. "R".
------------------------------------------------------------------------------------------
local function Resolve(ref, bodySide, dom)
	local kind, key = string.sub(ref, 1, 1), string.sub(ref, 3)
	local letter, rest = string.sub(key, 1, 2), string.sub(key, 3)
	local other = { L = "R", R = "L" }
	local side
	if letter == "C_" then side = other[bodySide]
	elseif letter == "I_" then side = bodySide
	elseif letter == "D_" then side = dom
	elseif letter == "N_" then side = other[dom]
	elseif letter == "L_" then side = "L"
	elseif letter == "R_" then side = "R" end
	local full = side and (side .. "_" .. rest) or key
	local id = kind == "t" and A.tractOf[full] or A.regionOf[full]
	if not id then error("atlas: unknown structure " .. ref .. " -> " .. full) end
	return kind == "t", id
end

local function Compile(dom)
	local out = {}
	local function Add(def, bodySide)
		local c = { key = def.key .. (bodySide or ""), base = def.key, group = def.group, side = bodySide, stages = {} }
		for _, stg in ipairs(def.stages) do
			local s = { reserve = stg.reserve, name = stg.name, items = {} }
			for _, it in ipairs(stg) do
				local isTract, id = Resolve(it[1], bodySide or "L", dom)
				s.items[#s.items + 1] = { isTract, id, it[2] }
			end
			c.stages[#c.stages + 1] = s
		end
		out[#out + 1] = c
	end
	for _, def in ipairs(A.channels) do
		if def.sides then Add(def, "L") Add(def, "R") else Add(def, nil) end
	end
	-- neglect: the weighted damage of the listed regions of one hemisphere
	out.neglect = { L = {}, R = {} }
	for _, side in ipairs({ "L", "R" }) do
		for _, e in ipairs(A.neglect.regions) do
			out.neglect[side][#out.neglect[side] + 1] = { A.regionOf[side .. "_" .. e[1]], e[2] }
		end
	end
	return out
end
A.compiled = { L = Compile("L"), R = Compile("R") }

NT.Atlas.built = true
