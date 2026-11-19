-- Техника Glide (lua/glide, lua/entities/base_glide_* и gtav_*): у Glide поза седока - ManipulateBoneAngles из
-- ENT:GetSeatBoneManipulations (мотоциклы - ноги на подножках на ходу, стоит - на земле; квадроцикл Blazer, гидроцикл
-- Seashark, Thruster, пассажиры мотоциклов - свои позы ног), но Z-City её выключил целиком (lua/glide/sh_anims.lua,
-- PrePlayerDraw "Glide.ManipulatePlayerBones" - do return end): там же руки, а руки ставит IK Z-City (cl_tpik.lua - обе на
-- руль/руль-рогатку), и сброс обнулял ВСЕ кости. Возвращаем только ноги (бедро, голень, стопа) и сбрасываем только их,
-- когда слез. У обычных машин Glide поза ног не задана - там ничего не меняется. Выкл.: rem_glide_legs 0.
local cv = CreateClientConVar("rem_glide_legs", "1", true, false, "Glide vehicles: riders' legs posed by Glide (motorcycles, quads, jet skis)", 0, 1)

local LEGS = {
	["ValveBiped.Bip01_L_Thigh"] = true, ["ValveBiped.Bip01_L_Calf"] = true, ["ValveBiped.Bip01_L_Foot"] = true,
	["ValveBiped.Bip01_R_Thigh"] = true, ["ValveBiped.Bip01_R_Calf"] = true, ["ValveBiped.Bip01_R_Foot"] = true,
}
local zero = Angle()
local posed = setmetatable({}, {__mode = "k"}) -- [игрок] = {кость = true}

local function Reset(ply, bones)
	if IsValid(ply) then
		for b in pairs(bones) do ply:ManipulateBoneAngles(b, zero, false) end
	end
	posed[ply] = nil
end

hook.Add("Think", "rem_glide_legs", function()
	if not Glide then return end
	local on = cv:GetBool()
	for _, ply in player.Iterator() do
		local veh = on and ply:Alive() and ply.GlideGetVehicle and ply:GlideGetVehicle()
		local pose = IsValid(veh) and veh.GetSeatBoneManipulations and veh:GetSeatBoneManipulations(ply:GlideGetSeatIndex())
		local bones = posed[ply]
		if istable(pose) then
			bones = bones or {}
			posed[ply] = bones
			for name, ang in pairs(pose) do
				if LEGS[name] then
					local b = ply:LookupBone(name)
					if b then
						ply:ManipulateBoneAngles(b, ang, false)
						bones[b] = true
					end
				end
			end
		elseif bones then
			Reset(ply, bones)
		end
	end
end)
