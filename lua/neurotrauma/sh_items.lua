-- Items of the module. One so far: the midazolam autoinjector, the rescue medication for a seizure
-- that does not stop. It is an item of Z-City's medicine family: it derives from Z-City's own
-- medicine base and is used like its other injectors (primary on oneself, secondary on the
-- character in front, also on a ragdolled one); what the dose does is decided by the neurological
-- model (sv_treatment.lua). It is registered only when Z-City's base is there, so that without
-- Z-City there is no broken item in the menu.

local NT = NeuroTrauma

local SWEP = {
	Base = "weapon_bandage_sh",
	PrintName = "Midazolam",
	Instructions = "Midazolam autoinjector, into the thigh. Stops a convulsive seizure that does not stop by itself; it takes a minute or two to act and does not always work. It makes drowsy, and repeated doses slow the breathing. It does nothing for the injury behind the seizure. LMB to inject yourself, RMB to inject someone else.",
	Category = "ZCity Medicine",
	Spawnable = true,
	Primary = { Wait = 1, Next = 0 },
	HoldType = "normal",
	ViewModel = "",
	WorldModel = "models/weapons/w_models/w_jyringe_jroj.mdl",
	Model = "models/weapons/w_models/w_jyringe_jroj.mdl",
	AutoSwitchTo = false,
	AutoSwitchFrom = false,
	Slot = 5,
	SlotPos = 2,
	WorkWithFake = true,
	offsetVec = Vector(5, -1.5, -2.5),
	offsetAng = Angle(90, 0, -90),
	modeNames = { [1] = "midazolam" },
	modeValuesdef = { [1] = 1 },
	DeploySnd = "",
	HolsterSnd = "",
	showstats = false,
}

function SWEP:InitializeAdd()
	self:SetHold(self.HoldType)
	self.modeValues = { [1] = 1 }
end

function SWEP:Think() end

if SERVER then
	function SWEP:Heal(ent, mode)
		if not IsValid(ent) or not ent.organism then return end
		if not NT.Treatment then return end
		local owner = self:GetOwner()
		local ok, why = NT.Treatment.Administer(ent, "midazolam", owner)
		if not ok then
			-- (refused: out of reach, too soon, the giver cannot do it; the dose is kept)
			if IsValid(owner) and owner:IsPlayer() and why ~= "too soon" and owner.Notify then owner:Notify("Cannot inject: " .. tostring(why), 4) end
			return
		end
		local from = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or owner
		from:EmitSound("snd_jack_hmcd_needleprick.wav", 60, math.random(95, 105))
		self.modeValues[1] = 0
		if owner:IsPlayer() then owner:SelectWeapon("weapon_hands_sh") end
		self:Remove()
		return true
	end
end

NT.Items = NT.Items or {}
local function Register()
	if NT.Items.midazolam then return end
	if not weapons.GetStored("weapon_bandage_sh") then return end
	weapons.Register(SWEP, "weapon_midazolam")
	NT.Items.midazolam = true
end
hook.Add("InitPostEntity", "NT_Items", Register)
hook.Add("HomigradRun", "NT_Items", function() timer.Simple(0, Register) end)
