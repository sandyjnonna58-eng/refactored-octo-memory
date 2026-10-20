-- Эксперимент: жёлтая кровь; переломы, позвоночник и шея не обездвиживают - двигаться можно, но больно.
local CLASS = player.RegClass("experiment")

-- модели из аддона Akittu's Expie and Milky, толстовку на них надевает lua/autorun/akittu_sweater.lua
local models = {
	"models/akittu/stylizedexpie/akittuexpie.mdl",
	"models/akittu/stylizedexpie/akittuexpiev3.mdl",
	"models/akittu/stylizedmilky/akittumilky.mdl",
	"models/akittu/stylizedmilky/akittumilky3dmouth.mdl",
}

local role_color = Color(230, 190, 0)

-- боль в секунду за каждую сломанную часть при движении на полной скорости
local move_pain_per_fracture = 4
local move_pain_speed = 200

CLASS.NoGloves = true
CLASS.YellowBlood = true
CLASS.FractureTolerance = true

function hg.HasYellowBlood(ent)
	if not IsValid(ent) then return false end
	if ent:GetNWBool("hg_yellowblood", false) then return true end

	if ent:IsRagdoll() and hg.RagdollOwner then
		local owner = hg.RagdollOwner(ent)
		return IsValid(owner) and owner ~= ent and owner:GetNWBool("hg_yellowblood", false)
	end

	return false
end

function CLASS.Off(self)
	if CLIENT then return end

	self:SetNWBool("hg_yellowblood", false)
	self.bloodColorHitFix = BLOOD_COLOR_RED
end

function CLASS.On(self)
	if CLIENT then return end

	self:SetNWBool("hg_yellowblood", true)
	self.bloodColorHitFix = BLOOD_COLOR_YELLOW

	if zb.GiveRole then zb.GiveRole(self, "Experiment", role_color) end

	local valid = {}
	for _, model in ipairs(models) do
		if util.IsValidModel(model) then valid[#valid + 1] = model end
	end

	if #valid == 0 then
		ApplyAppearance(self)
		self:ChatPrint("Experiment: Expie/Milky models are not installed, using a normal model.")
		return
	end

	ApplyAppearance(self, nil, nil, nil, true)
	local Appearance = self.CurAppearance or hg.Appearance.GetRandomAppearance()
	Appearance.AAttachments = ""
	Appearance.AColthes = ""
	self:SetModel(valid[math.random(#valid)])
	self:SetSubMaterial()
	self:SetNetVar("Accessories", "")
	self.CurAppearance = Appearance
end

local function brokenParts(org)
	local count = 0
	if org.lleg >= 1 then count = count + 1 end
	if org.rleg >= 1 then count = count + 1 end
	if org.pelvis >= 1 then count = count + 1 end
	if org.spine1 >= hg.organism.fake_spine1 then count = count + 1 end
	if org.spine2 >= hg.organism.fake_spine2 then count = count + 1 end
	if org.spine3 >= hg.organism.fake_spine3 then count = count + 1 end
	return count
end

function CLASS.Think(self, time, dtime)
	if CLIENT then return end

	local org = self.organism
	if not org or not org.alive or org.otrub or not dtime then return end

	local broken = brokenParts(org)
	if broken == 0 then return end

	local char = hg.GetCurrentCharacter(self)
	local speed = IsValid(char) and char:GetVelocity():Length2D() or 0
	if speed < 20 then return end

	org.painadd = org.painadd + dtime * broken * move_pain_per_fracture * math.min(speed / move_pain_speed, 1.5)
end

if SERVER then
	-- труп тоже истекает жёлтой кровью
	hook.Add("RagdollDeath", "hg_experiment_yellowblood", function(ply, ragdoll)
		if IsValid(ragdoll) and IsValid(ply) and ply:GetNWBool("hg_yellowblood", false) then
			ragdoll:SetNWBool("hg_yellowblood", true)
		end
	end)

	return
end

-- у части крови нет владельца (брызги от попаданий), её красим по ближайшему эксперименту
local yellow_radius_sqr = 90 * 90
local yellowSources = {}
local nextScan = 0

hook.Add("Think", "hg_experiment_yellowblood", function()
	if CurTime() < nextScan then return end
	nextScan = CurTime() + 0.5

	yellowSources = {}
	for _, ply in player.Iterator() do
		if ply:Alive() and ply:GetNWBool("hg_yellowblood", false) then
			yellowSources[#yellowSources + 1] = hg.GetCurrentCharacter(ply)
		end
	end

	for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
		if rag:GetNWBool("hg_yellowblood", false) then yellowSources[#yellowSources + 1] = rag end
	end
end)

function hg.IsYellowBloodAt(owner, pos)
	if IsValid(owner) then return hg.HasYellowBlood(owner) end
	if not pos then return false end

	for i = 1, #yellowSources do
		local ent = yellowSources[i]
		if IsValid(ent) and ent:WorldSpaceCenter():DistToSqr(pos) < yellow_radius_sqr then return true end
	end

	return false
end
