local MODE = MODE

MODE.name = "turfwar"
MODE.PrintName = "Turf War"

MODE.ForBigMaps = false
-- музыка идёт 3:47, раунд чуть длиннее
MODE.ROUND_TIME = 240

MODE.Chance = 0.02

MODE.OverideSpawnPos = true
MODE.LootSpawn = false

-- 0 - случайно каждый раунд, 1 - только ближний бой, 2 - только огнестрел
local variantConVar = CreateConVar("zb_turfwar_variant", "0", FCVAR_ARCHIVE, "Turf War variant: 0 - random, 1 - melee, 2 - firearms", 0, 2)

local meleeWeapons = {
	"weapon_hg_machete",
	"weapon_hatchet",
	"weapon_bat",
	"weapon_metalbat",
	"weapon_leadpipe",
	"weapon_hg_crowbar",
	"weapon_pocketknife",
	"weapon_combatknife",
	"weapon_hammer",
	"weapon_hg_axe",
	"weapon_hg_bottle",
	"weapon_chair_leg",
	"weapon_table_leg",
	"weapon_pan",
	"weapon_hg_tonfa",
	"weapon_brick",
	"weapon_sogknife",
}

local firearms = {
	"weapon_mac11",
	"weapon_uzi",
	"weapon_tec9",
	"weapon_doublebarrel_short",
	"weapon_glock17",
	"weapon_cz75",
	"weapon_deagle",
	"weapon_revolver2",
	"weapon_m1911",
	"weapon_skorpion",
	"weapon_draco",
	"weapon_remington870_sawed_off",
}

local gangs = {
	[0] = {class = "bloodz", role = "Bloodz", color = Color(190, 0, 0), pluv = "pluvred"},
	[1] = {class = "groove", role = "Groove", color = Color(0, 190, 0), pluv = "pluvgreen"},
}

function MODE:CanLaunch()
	return true
end

function MODE.GuiltCheck(Attacker, Victim, add, harm, amt)
	return 1, true
end

function MODE:PickVariant()
	local forced = variantConVar:GetInt()
	if forced == self.VARIANT_MELEE or forced == self.VARIANT_GUNS then return forced end

	return math.random(2) == 1 and self.VARIANT_MELEE or self.VARIANT_GUNS
end

util.AddNetworkString("turfwar_start")
function MODE:Intermission()
	game.CleanUpMap()

	self.Variant = self:PickVariant()
	SetGlobalInt("turfwar_variant", self.Variant)

	for i, ply in player.Iterator() do
		ply:SetupTeam(ply:Team())
	end

	net.Start("turfwar_start")
		net.WriteUInt(self.Variant, 2)
	net.Broadcast()
end

function MODE:CheckAlivePlayers()
	return zb:CheckAliveTeams(true)
end

function MODE:ShouldRoundEnd()
	local endround, winner = zb:CheckWinner(self:CheckAlivePlayers())

	return endround
end

function MODE:BoringRoundFunction()
end

function MODE:RoundStart()
end

function MODE:GetPlySpawn(ply)
end

local function GiveWeapon(ply, variant)
	if variant == MODE.VARIANT_MELEE then
		ply:Give(meleeWeapons[math.random(#meleeWeapons)])
		return
	end

	local wep = ply:Give(firearms[math.random(#firearms)])
	if IsValid(wep) then ply:GiveAmmo(wep:GetMaxClip1() * 3, wep:GetPrimaryAmmoType(), true) end
end

function MODE:GiveEquipment()
	local variant = self.Variant or self:PickVariant()

	timer.Simple(0.1, function()
		for _, ply in player.Iterator() do
			if not ply:Alive() then continue end

			local gang = gangs[ply:Team()]
			if not gang then continue end

			ply:SetSuppressPickupNotices(true)
			ply.noSound = true

			ply:SetPlayerClass(gang.class)
			zb.GiveRole(ply, gang.role, gang.color)
			ply:SetNetVar("CurPluv", gang.pluv)

			GiveWeapon(ply, variant)

			ply:Give("weapon_bandage_sh")
			ply:Give("weapon_tourniquet")

			local hands = hg.GetHandsWeaponClass(ply)
			ply:Give(hands)
			ply:SelectWeapon(hands)

			timer.Simple(0.1, function()
				if IsValid(ply) then ply.noSound = false end
			end)

			ply:SetSuppressPickupNotices(false)
		end
	end)
end

function MODE:RoundThink()
end

function MODE:GetTeamSpawn()
	return zb.TranslatePointsToVectors(zb.GetMapPoints("HMCD_TDM_T")), zb.TranslatePointsToVectors(zb.GetMapPoints("HMCD_TDM_CT"))
end

function MODE:CanSpawn()
end

util.AddNetworkString("turfwar_end")
function MODE:EndRound()
	local endround, winner = zb:CheckWinner(self:CheckAlivePlayers())

	timer.Simple(2, function()
		net.Start("turfwar_end")
			net.WriteInt(isnumber(winner) and winner or -1, 4)
		net.Broadcast()
	end)

	for _, ply in player.Iterator() do
		if ply:Team() == winner then
			ply:GiveExp(math.random(15, 30))
			ply:GiveSkill(math.Rand(0.1, 0.15))
		else
			ply:GiveSkill(-math.Rand(0.05, 0.1))
		end
	end
end

function MODE:PlayerDeath(ply)
end

-- !turfwar [melee|guns|random] - выбрать вариант и запустить режим следующим раундом
local variantArgs = {melee = 1, guns = 2, firearms = 2, random = 0}

if COMMANDS then COMMANDS.turfwar = {
	function(ply, args)
		if not ply:IsAdmin() then ply:ChatPrint("You don't have access") return end

		local variant = variantArgs[string.lower(args[1] or "random")]
		if not variant then
			ply:ChatPrint("Usage: !turfwar [melee|guns|random]")
			return
		end

		variantConVar:SetInt(variant)
		NextRound("turfwar", true)
		ply:ChatPrint("Next round: Turf War (" .. (MODE.VariantNames[variant] or "Random") .. ")")
	end, 0
} end
