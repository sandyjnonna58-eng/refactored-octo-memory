-- |Z-CITY| GORE torso (client)
-- The split itself (bone hiding, caps, physics) is done on the server and replicated.
-- This file does what only the client can: keep Z-City from drawing knee stumps on the upper half and
-- keep track of the lower halves. The 5 chest arteries between the halves, their tearing and the
-- bleeding are drawn by the shared artery renderer (cl_artery.lua).

local CALF_BONES = {"ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_R_Calf"}

-- Called by the GoreCalc wrapper (cl_gore.lua) for the upper half of a cut torso.
-- The cut flags both legs as amputated, so Z-City would draw a knee stump for each one at the
-- (hidden) thigh. The legs are on the lower half, so run Z-City's code with the leg flags off
-- and put the hidden calf scale back afterwards.
function ZCityGore.CalcTorsoSevered(old, ent, ply)
	local org = ent.new_organism or ent.organism
	if not org then return old(ent, ply) end

	local saved = {}
	for i = 1, #CALF_BONES do
		local bone = ent:LookupBone(CALF_BONES[i])
		if bone then saved[#saved + 1] = {bone, ent:GetManipulateBoneScale(bone)} end
	end

	local ll, rl = org.llegamputated, org.rlegamputated
	org.llegamputated, org.rlegamputated = false, false
	local ok, res = pcall(old, ent, ply)
	org.llegamputated, org.rlegamputated = ll, rl

	for i = 1, #saved do
		ent:ManipulateBoneScale(saved[i][1], saved[i][2])
	end

	if not ok then error(res, 0) end
	return res
end

-- ---------------------------------------------------------------------------
-- Lower halves currently around (cl_artery.lua draws and bleeds them)
-- ---------------------------------------------------------------------------
local lowers = ZCityGore.ClientLowers
local nextScan = 0

hook.Add("Think", "zcity_gore_torso_scan", function()
	local ct = CurTime()
	if ct < nextScan then return end
	nextScan = ct + 0.5
	for _, ent in ipairs(ents.FindByClass("prop_ragdoll")) do
		if not lowers[ent] and ent:GetNWBool("ZCityTorsoLowerPart") then lowers[ent] = true end
	end
end)
