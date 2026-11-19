-- Мотоциклы Glide (lua/glide, gtav_sanchez / gtav_bati801 / gtav_wolfsbane и наследники base_glide_motorcycle):
-- у Glide поза седока - ManipulateBoneAngles из ENT:GetSeatBoneManipulations (ноги на подножках на ходу, стоит - ноги
-- на земле), но Z-City её выключил целиком (lua/glide/sh_anims.lua, PrePlayerDraw "Glide.ManipulatePlayerBones" -
-- do return end): там же руки, а руки ставит IK Z-City (cl_tpik.lua - теперь обе на руль), и сброс обнулял ВСЕ кости.
-- Возвращаем только ноги (бедро, голень, стопа) и сбрасываем только их, когда слез. Выкл.: rem_glide_bike_legs 0.
local cv = CreateClientConVar("rem_glide_bike_legs", "1", true, false, "Glide motorcycles: riders' legs posed by Glide (feet on the pegs while riding)", 0, 1)

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

hook.Add("Think", "rem_glide_bike_legs", function()
	if not Glide or not Glide.VEHICLE_TYPE then return end
	local on = cv:GetBool()
	for _, ply in player.Iterator() do
		local veh = on and ply:Alive() and ply.GlideGetVehicle and ply:GlideGetVehicle()
		local pose = IsValid(veh) and veh.VehicleType == Glide.VEHICLE_TYPE.MOTORCYCLE and veh.GetSeatBoneManipulations
			and veh:GetSeatBoneManipulations(ply:GlideGetSeatIndex())
		if pose then
			local bones = posed[ply] or {}
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
		elseif posed[ply] then
			Reset(ply, posed[ply])
		end
	end
end)
