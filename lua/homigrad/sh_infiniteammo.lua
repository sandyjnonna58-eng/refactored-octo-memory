-- Серверная настройка "бесконечные патроны": магазин тратится и перезаряжается как обычно,
-- но в запасе к каждому оружию всегда минимум reserve_mags полных магазинов.
-- Расходники (спички и т.п.) помечены SWEP.NoInfiniteAmmo.
local hg_infiniteammo = ConVarExists("hg_infiniteammo") and GetConVar("hg_infiniteammo") or CreateConVar("hg_infiniteammo", 0, FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY, "Infinite ammo: always at least 2 spare magazines for every gun", 0, 1)

if CLIENT then return end

local reserve_mags = 2
local check_interval = 0.5

timer.Create("rem_infiniteammo", check_interval, 0, function()
	if not hg_infiniteammo:GetBool() then return end

	for _, ply in player.Iterator() do
		if not ply:Alive() then continue end

		-- несколько стволов под один патрон: запас по самому большому магазину
		local need = {}
		for _, wep in ipairs(ply:GetWeapons()) do
			local ammoType = wep:GetPrimaryAmmoType()
			local clip = wep:GetMaxClip1()

			if not wep.NoInfiniteAmmo and ammoType and ammoType >= 0 and clip and clip > 0 then
				need[ammoType] = math.max(need[ammoType] or 0, clip * reserve_mags)
			end
		end

		for ammoType, amount in pairs(need) do
			if ply:GetAmmoCount(ammoType) < amount then ply:SetAmmo(amount, ammoType) end
		end
	end
end)
