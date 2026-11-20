-- |Z-CITY| GORE
-- Wait until Homigrad exists. This addon must not load before Z-City.

if SERVER then
	AddCSLuaFile("zcity_gore/sh_gore.lua")
	AddCSLuaFile("zcity_gore/sh_cmenu.lua")
	AddCSLuaFile("zcity_gore/cl_gore.lua")
	AddCSLuaFile("zcity_gore/cl_artery.lua")
	AddCSLuaFile("zcity_gore/cl_torso.lua")
end

local booted = false

local function BootGore()
	if booted then return true end
	if not istable(hg) or not istable(hg.organism) then return false end

	booted = true
	include("zcity_gore/sh_gore.lua")
	include("zcity_gore/sh_cmenu.lua") -- c-menu "Amputate Limb" (limbs, head, torso)
	if SERVER then
		include("zcity_gore/sv_gore.lua")
		include("zcity_gore/sv_torso.lua") -- needs sv_gore (severed limb table, tether)
		include("zcity_gore/sv_npc.lua") -- NPC dismemberment, needs sv_gore and sv_torso
	else
		include("zcity_gore/cl_gore.lua")
		include("zcity_gore/cl_artery.lua") -- artery renderer, tearing, spray (needs cl_gore)
		include("zcity_gore/cl_torso.lua") -- needs cl_artery
	end
	return true
end

hook.Add("HomigradRun", "zcity_gore_boot", function()
	timer.Simple(0, BootGore)
end)
hook.Add("InitPostEntity", "zcity_gore_boot", function()
	timer.Simple(0.2, BootGore)
end)
timer.Create("zcity_gore_boot", 0.25, 60, function()
	if BootGore() then timer.Remove("zcity_gore_boot") end
end)
