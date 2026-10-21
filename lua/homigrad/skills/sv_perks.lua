-- cl_/sv_ грузятся раньше sh_ (по алфавиту), таблицу заполнит sh_skills.lua
hg.Skills = hg.Skills or {}
local SK = hg.Skills

util.AddNetworkString("rem_pickpocket")

-- Pickpocket: сколько держать E и с какого расстояния (за спиной - SK.IsBehind)
local steal_time = 2.5
local steal_dist = 75
local steal_max_target_speed = 90
local steal_cooldown = 30
local steal_notice_chance = 0.2

-- Second Wind: ниже какой доли выносливости срабатывает, до какой восстанавливает, перезарядка
local wind_threshold = 0.15
local wind_restore = 0.6
local wind_cooldown = 90

local tick_interval = 0.1

local colPerk = Color(230, 190, 0)
local colWarn = Color(255, 120, 120)

local noSteal = {
	weapon_hands_sh = true,
	weapon_hg_coolhands = true,
}

function SK.PickpocketTarget(ply)
	if not SK.HasPerk(ply, "pickpocket") or not ply:Alive() or ply:InVehicle() or IsValid(ply.FakeRagdoll) then return end
	if not ply:Crouching() then return end

	local tr = util.TraceLine({
		start = ply:EyePos(),
		endpos = ply:EyePos() + ply:GetAimVector() * steal_dist,
		filter = ply,
	})

	local target = tr.Entity
	if not IsValid(target) or not target:IsPlayer() or not target:Alive() or IsValid(target.FakeRagdoll) then return end
	if not SK.IsBehind(ply, target) then return end

	return target
end

local function SendProgress(ply, finish)
	net.Start("rem_pickpocket")
		net.WriteFloat(finish or 0)
	net.Send(ply)
end

local function StopSteal(ply)
	if not ply.pickpocket then return end
	ply.pickpocket = nil
	SendProgress(ply, 0)
end

local function StealableWeapons(thief, target)
	local active = target:GetActiveWeapon()
	local list = {}

	for _, wep in ipairs(target:GetWeapons()) do
		if wep ~= active and not noSteal[wep:GetClass()] and not thief:HasWeapon(wep:GetClass()) then list[#list + 1] = wep end
	end

	return list
end

-- оружие переходит целиком (патроны в магазине, обвесы), через тот же путь, что и обычный подбор
local function StealWeapon(thief, target, wep)
	target:DropWeapon(wep)
	if not IsValid(wep) then return false end

	wep.IsSpawned = false
	wep.init = false
	thief.force_pickup = true
	local can = hook.Run("PlayerCanPickupWeapon", thief, wep) ~= false
	if can then thief:PickupWeapon(wep) end
	thief.force_pickup = nil

	if IsValid(wep) and wep:GetOwner() == thief then return true end

	-- не влезло вору - тихо вернуть жертве
	if IsValid(wep) and not IsValid(wep:GetOwner()) then
		target.force_pickup = true
		target:PickupWeapon(wep)
		target.force_pickup = nil
	end

	return false
end

local function StealAmmo(thief, target)
	local types = {}
	for ammoType, count in pairs(target:GetAmmo()) do
		if count > 0 then types[#types + 1] = ammoType end
	end
	if #types == 0 then return end

	local ammoType = types[math.random(#types)]
	local amount = math.ceil(target:GetAmmoCount(ammoType) / 2)
	target:RemoveAmmo(amount, ammoType)
	thief:GiveAmmo(amount, ammoType, true)

	return amount
end

local function FinishSteal(thief, target)
	thief.pickpocketNext = CurTime() + steal_cooldown

	local weapons = StealableWeapons(thief, target)
	local stolen

	if #weapons > 0 then
		local wep = weapons[math.random(#weapons)]
		local name = wep.PrintName or wep:GetClass()
		if StealWeapon(thief, target, wep) then stolen = name end
	end

	if not stolen then
		local amount = StealAmmo(thief, target)
		if amount then stolen = amount .. " rounds" end
	end

	if not stolen then
		thief:Notify("Their pockets are empty.", 0, "pickpocket_result", 2, nil, colWarn)
		return
	end

	thief:Notify("You stole: " .. stolen .. ".", 0, "pickpocket_result", 3, nil, colPerk)

	if math.random() < steal_notice_chance then
		target:Notify("Your pockets feel lighter...", 0, "pickpocket_victim", 3, nil, colWarn)
	end
end

hook.Add("KeyPress", "rem_pickpocket", function(ply, key)
	if key ~= IN_USE or ply.pickpocket then return end
	if (ply.pickpocketNext or 0) > CurTime() then return end

	local target = SK.PickpocketTarget(ply)
	if not target then return end

	local finish = CurTime() + steal_time
	ply.pickpocket = {target = target, finish = finish}
	SendProgress(ply, finish)
end)

local function WindTick(ply)
	if not SK.HasPerk(ply, "secondwind") or not ply:Alive() then return end

	local org = ply.organism
	local stamina = org and org.stamina
	if not stamina or not stamina.max or org.otrub then return end
	if (ply.secondWindNext or 0) > CurTime() then return end
	if stamina[1] > stamina.max * wind_threshold then return end

	stamina[1] = stamina.max * wind_restore
	ply.secondWindNext = CurTime() + wind_cooldown
	ply:Notify("Second wind.", 0, "perk_secondwind", 2, nil, colPerk)
end

timer.Create("rem_perks_tick", tick_interval, 0, function()
	local now = CurTime()

	for _, ply in player.Iterator() do
		WindTick(ply)

		local steal = ply.pickpocket
		if steal then
			local target = steal.target
			local ok = ply:Alive() and ply:KeyDown(IN_USE) and ply:Crouching() and not IsValid(ply.FakeRagdoll)
				and IsValid(target) and target:Alive() and not IsValid(target.FakeRagdoll)
				and target:GetPos():Distance(ply:GetPos()) <= steal_dist + 30
				and SK.IsBehind(ply, target)
				and target:GetVelocity():Length2D() <= steal_max_target_speed

			if not ok then
				StopSteal(ply)
				ply:Notify("You were too clumsy.", 0, "pickpocket_result", 2, nil, colWarn)
			elseif now >= steal.finish then
				StopSteal(ply)
				FinishSteal(ply, target)
			end
		end
	end
end)

hook.Add("PlayerDeath", "rem_pickpocket", StopSteal)
