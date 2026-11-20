-- |Z-CITY| GORE client

local limbRootBones = ZCityGore.LimbBones
local vecZero = Vector(0, 0, 0)
local vecAlmostZero = Vector(0.01, 0.01, 0.01) -- same as Z-City; exact 0 gives singular bone matrices
local vecFull = Vector(1, 1, 1)

local stumpOffset = {
	["ValveBiped.Bip01_L_Forearm"] = {Vector(0.4, 0.3, -0.3), Angle(0, 90, 0)},
	["ValveBiped.Bip01_R_Forearm"] = {Vector(0.4, 0.3, 0.3), Angle(0, 90, 0)},
	["ValveBiped.Bip01_L_Calf"] = {Vector(0.6, 0, 0), Angle(0, 90, 0)},
	["ValveBiped.Bip01_R_Calf"] = {Vector(0.6, 0, 0), Angle(0, 90, 0)},
	["ValveBiped.Bip01_Head1"] = {Vector(-0.15, 0, 0), Angle(0, 0, 0)},
}

local function collectKeepBones(ent, bone, keep)
	keep[bone] = true
	for i, child in ipairs(ent:GetChildBones(bone) or {}) do
		collectKeepBones(ent, child, keep)
	end
end

-- Every frame the bones that do not belong to the severed piece are squashed onto its root bone.
-- The list of those bones never changes for a given ragdoll, so it is built once, and one shared matrix is
-- written to all of them instead of reading + rebuilding a matrix for every bone every frame.
local hideMat = Matrix()

local function hideBody(ent)
	local limb = ent:GetNWString("SeveredLimb", "")
	local rootName = limbRootBones[limb]
	if not rootName then return end
	local rootBone = ent._hgSeverRoot
	local hidden = ent._hgSeverHidden
	-- the cached bone list belongs to one model: rebuild it if the model changed
	if hidden and ent._hgSeverModel ~= ent:GetModel() then hidden = nil end
	if not hidden then
		ent._hgSeverModel = ent:GetModel()
		rootBone = ent:LookupBone(rootName)
		if not rootBone then return end
		ent:SetupBones()
		local keep = {}
		collectKeepBones(ent, rootBone, keep)
		hidden = {}
		for boneid = 0, ent:GetBoneCount() - 1 do
			if not keep[boneid] then hidden[#hidden + 1] = boneid end
		end
		ent._hgSeverKeep = keep
		ent._hgSeverRoot = rootBone
		ent._hgSeverHidden = hidden
	end
	ent:SetupBones()
	local rootMat = ent:GetBoneMatrix(rootBone)
	if not rootMat then return rootBone end
	hideMat:SetTranslation(rootMat:GetTranslation())
	hideMat:SetAngles(rootMat:GetAngles())
	hideMat:SetScale(vecAlmostZero)
	-- Fast path: whole list in one pcall. Some bones can be unwriteable ("Bone is unwriteable", e.g. bones the
	-- model does not use, or a stale list after a model change); then find them once and drop them from the list
	-- so it never errors again.
	local ok = pcall(function()
		for i = 1, #hidden do
			ent:SetBoneMatrix(hidden[i], hideMat)
		end
	end)
	if not ok then
		local good = {}
		for i = 1, #hidden do
			if pcall(ent.SetBoneMatrix, ent, hidden[i], hideMat) then good[#good + 1] = hidden[i] end
		end
		ent._hgSeverHidden = good
	end
	return rootBone, rootMat
end

local function drawSeveredLimb(ent)
	local rootBone, rootMat = hideBody(ent)
	ent:DrawModel()
	if ent:GetNWString("SeveredLimb", "") ~= "head" then return end
	local acc = ent.GetNetVar and ent:GetNetVar("Accessories")
	if not acc or acc == "none" or not DrawAccesories then return end
	local list = istable(acc) and acc or {acc}
	for i = 1, #list do
		local name = list[i]
		local accessData = hg.Accessories and hg.Accessories[name]
		if not accessData then continue end
		if accessData.bone ~= "ValveBiped.Bip01_Head1" and accessData.placement ~= "head" and accessData.placement ~= "face" then continue end
		DrawAccesories(ent, ent, name, accessData, false, true)
	end
end

local function setupSeveredLimb(ent)
	if not IsValid(ent) then return end
	if not ent:GetNWBool("IsSeveredLimb") then return end
	if ent:GetClass() ~= "prop_ragdoll" then return end
	hg.clientSeveredLimbs = hg.clientSeveredLimbs or {}
	hg.clientSeveredLimbs[ent] = true
	ent._hgSeveredDraw = true
	ent.RenderOverride = function(self)
		if IsValid(self) then drawSeveredLimb(self) end
	end
end

hook.Add("OnEntityCreated", "zcity_gore_severed_client", function(ent)
	if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return end
	timer.Simple(0, function() setupSeveredLimb(ent) end)
end)
hook.Add("NetworkEntityCreated", "zcity_gore_severed_client", setupSeveredLimb)

hook.Add("Think", "zcity_gore_severed_client", function()
	if not istable(hg) then return end
	local ct = CurTime()
	hg.clientSeveredLimbs = hg.clientSeveredLimbs or {}
	if (hg._severScan or 0) <= ct then
		hg._severScan = ct + 0.5
		local known = hg.clientSeveredLimbs
		for _, ent in ipairs(ents.FindByClass("prop_ragdoll")) do
			if not known[ent] then setupSeveredLimb(ent) end
		end
		for ent in pairs(known) do
			if not IsValid(ent) then known[ent] = nil end
		end
	end
end)

local stumpBones = {
	head = {"ValveBiped.Bip01_Neck1", Vector(5, 0, 0)},
	larm = {"ValveBiped.Bip01_L_UpperArm", Vector(11, 0, 0)},
	rarm = {"ValveBiped.Bip01_R_UpperArm", Vector(11, 0, 0)},
	lleg = {"ValveBiped.Bip01_L_Thigh", Vector(16, 0, 0)},
	rleg = {"ValveBiped.Bip01_R_Thigh", Vector(16, 0, 0)},
}

-- (arterial spray, drips and the artery bundle itself live in cl_artery.lua)

-- Returns world pos, ang, and whether it is a severed piece (spray from its cut face)
local function arteryPos(ent, limb)
	if ent:GetNWBool("IsSeveredLimb") then
		local rootName = limbRootBones[limb]
		local bone = rootName and ent:LookupBone(rootName)
		if not bone then return end
		local mat = ent:GetBoneMatrix(bone)
		if not mat then return end
		local off = stumpOffset[rootName] or {vecZero, angle_zero}
		local pos, ang = LocalToWorld(off[1], off[2], mat:GetTranslation(), mat:GetAngles())
		return pos, ang, true
	end

	local data = stumpBones[limb]
	if not data then return end
	local bone = ent:LookupBone(data[1])
	if not bone then return end
	local mat = ent:GetBoneMatrix(bone)
	if not mat then
		local pos, ang = ent:GetBonePosition(bone)
		if not pos then return end
		local p, a = LocalToWorld(data[2], angle_zero, pos, ang or angle_zero)
		return p, a, false
	end
	local pos, ang = LocalToWorld(data[2], angle_zero, mat:GetTranslation(), mat:GetAngles())
	return pos, ang, false
end

ZCityGore.ArteryPos = arteryPos

-- A cut throws blood out of the wound (see cl_artery.lua for the burst itself)
net.Receive("hg_sever_blood", function()
	local ent = net.ReadEntity()
	local limb = net.ReadString()
	local pos = net.ReadVector()
	local force = net.ReadVector()
	if not ZCityGore.TearBurst then return end
	local dir = force:LengthSqr() > 1 and force:GetNormalized() or Vector(0, 0, 1)
	if limb == "torso" then
		-- cut in half: a ring of heavy bursts, one per chest artery
		for i = 1, #ZCityGore.TorsoArteries do
			local a = math.rad(ZCityGore.TorsoArteries[i].ang)
			local d = Vector(math.cos(a), math.sin(a), 0.35 + math.Rand(0, 0.5))
			d:Normalize()
			ZCityGore.TearBurst(pos + d * 2, d, 1.6, ent)
		end
	elseif limb == "head" then
		ZCityGore.TearBurst(pos, dir, 1.2, ent)
	else
		ZCityGore.TearBurst(pos, dir, 2.2, ent)
	end
end)

hook.Add("OnEntityCreated", "zcity_gore_block_gibs", function(ent)
	if not GetConVar("zcity_gore_block_gibs"):GetBool() then return end -- remorse: по умолчанию мясо и обрубки видны
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if ent.IsSeveredLimb or (ent.GetNWBool and ent:GetNWBool("IsSeveredLimb")) then return end
		local mdl = string.lower(tostring(ent:GetModel() or ""))
		if mdl == "" then return end
		if string.find(mdl, "headpartial", 1, true)
			or string.find(mdl, "limbspartial", 1, true)
			or string.find(mdl, "grub_nugget", 1, true)
			or string.find(mdl, "watermelon", 1, true)
			or string.find(mdl, "gibs/humans", 1, true)
			or string.find(mdl, "hgibs", 1, true)
		then
			ent:SetNoDraw(true)
		end
	end)
end)

local function shouldHideHead(ent, ply)
	if not IsValid(ent) then return false end
	if ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb") then return false end
	if ent.noHead or ent:GetNWBool("noHead") then return true end
	if IsValid(ply) and (ply.noHead or ply:GetNWBool("noHead")) then return true end
	local org = (ent.new_organism or ent.organism) or (IsValid(ply) and (ply.new_organism or ply.organism))
	return org and org.headamputated == true
end

local function hideHeadClient(ent)
	if not IsValid(ent) then return end
	local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
	if not bone then return end
	local function rec(b)
		ent:ManipulateBoneScale(b, vecZero)
		local mat = ent:GetBoneMatrix(b)
		if mat then
			mat:SetScale(vecZero)
			ent:SetBoneMatrix(b, mat)
		end
		for _, kid in ipairs(ent:GetChildBones(b) or {}) do rec(kid) end
	end
	rec(bone)
end

local function wrapGoreCalc()
	if not hg or not isfunction(hg.GoreCalc) then return false end
	-- Keep the ORIGINAL Z-City GoreCalc even if this file is refreshed
	if hg.GoreCalc ~= hg.ZCityGore_CalcWrapper then
		hg.ZCityGore_BaseGoreCalc = hg.GoreCalc
	end
	local old = hg.ZCityGore_BaseGoreCalc
	hg.ZCityGore_CalcWrapper = function(ent, ply)
		-- severed pieces are drawn by our own RenderOverride
		if IsValid(ent) and (ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb")) then return end

		-- The body's cut limb is hidden by Z-City itself (root bone scaled to ~0 + flesh stump).
		-- Do NOT touch the amputated flags here.
		local result
		if ZCityGore.CalcTorsoSevered and IsValid(ent) and ent:GetNWBool("ZCityTorsoSevered", false) then
			-- upper half of a cut torso: its legs are on the other half, no knee stumps here
			result = ZCityGore.CalcTorsoSevered(old, ent, ply)
		else
			result = old(ent, ply)
		end

		if shouldHideHead(ent, ply) then hideHeadClient(ent) end
		return result
	end
	hg.GoreCalc = hg.ZCityGore_CalcWrapper
	hg.ZCityGore_WrappedCalc = true
	return true
end

local function restoreHeadClient(ent)
	if not IsValid(ent) then return end
	if ent.IsSeveredLimb or (ent.GetNWBool and ent:GetNWBool("IsSeveredLimb")) then return end
	ent.noHead = nil
	local count = ent.GetBoneCount and ent:GetBoneCount() or 0
	for i = 0, count - 1 do
		ent:ManipulateBoneScale(i, vecFull)
	end
end

net.Receive("zcity_gore_reset", function()
	local ply = net.ReadEntity()
	restoreHeadClient(ply)
	if IsValid(LocalPlayer()) then restoreHeadClient(LocalPlayer()) end
end)

hook.Add("PlayerSpawn", "zcity_gore_reset", function(ply)
	restoreHeadClient(ply)
end)

hook.Add("HomigradRun", "zcity_gore_client", function() timer.Simple(0, wrapGoreCalc) end)
timer.Create("zcity_gore_client", 0.25, 40, function()
	if wrapGoreCalc() then timer.Remove("zcity_gore_client") end
end)

hook.Add("NetworkEntityCreated", "zcity_gore_skip_fake", function(ragdoll)
	if not IsValid(ragdoll) then return end
	if ragdoll:GetClass() == "prop_ragdoll" and ragdoll:GetNWBool("IsSeveredLimb") then
		-- let our RenderOverride win over fake ragdoll draw
		timer.Simple(0, function() setupSeveredLimb(ragdoll) end)
	end
end)
