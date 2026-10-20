player_manager.AddValidModel( "Akittu's Expie", "models/akittu/stylizedexpie/akittuexpie.mdl" )
list.Set( "PlayerOptionsModel", "Akittu's Expie", "models/akittu/stylizedexpie/akittuexpie.mdl" )
player_manager.AddValidHands( "Akittu's Expie", "models/akittu/stylizedexpie/akittuexpiecarms.mdl", 0, "00000000" )

hook.Add("PreDrawPlayerHands", "Akittu Expie hands", function(hands, vm, ply, wpn)
    if IsValid(hands) and hands:GetModel() == "models/akittu/stylizedexpie/akittuexpiecarms.mdl" then
        hands:SetSkin(ply:GetSkin())

        local handClawsGroup = 1
        local modelClawsGroup = ply:GetBodygroup(6)

        local handPawsGroup = 2
        local modelPawsGroup = ply:GetBodygroup(7)

        local handRightBandageGroup = 3
        local modelRightBandageGroup = ply:GetBodygroup(12)

        local handLeftBandageGroup = 4
        local modelLeftBandageGroup = ply:GetBodygroup(13)

        if modelClawsGroup == 1 then
            hands:SetBodygroup(handClawsGroup, 1)
        else 
            hands:SetBodygroup(handClawsGroup, 0)
        end

        if modelPawsGroup == 1 then
            hands:SetBodygroup(handPawsGroup, 1)
        else 
            hands:SetBodygroup(handPawsGroup, 0)
        end

        if modelRightBandageGroup == 1 then
            hands:SetBodygroup(handRightBandageGroup, 1)
        elseif modelRightBandageGroup == 2 then
            hands:SetBodygroup(handRightBandageGroup, 2)
        else
            hands:SetBodygroup(handRightBandageGroup, 0)
        end

        if modelLeftBandageGroup == 1 then
            hands:SetBodygroup(handLeftBandageGroup, 1)
        elseif modelLeftBandageGroup == 2 then
            hands:SetBodygroup(handLeftBandageGroup, 2)
        else
            hands:SetBodygroup(handLeftBandageGroup, 0)
        end

    end
end)

player_manager.AddValidModel( "Akittu's Expie V3", "models/akittu/stylizedexpie/akittuexpiev3.mdl" )
list.Set( "PlayerOptionsModel", "Akittu's Expie V3", "models/akittu/stylizedexpie/akittuexpiev3.mdl" )
player_manager.AddValidHands( "Akittu's Expie V3", "models/akittu/stylizedexpie/akittuexpiecarms.mdl", 0, "00000000" )

local Category = "Wemi"        

local NPC =
{
	Name = "Akittu's Expie (Friendly)",                         
	Class = "npc_citizen",                           
	Health = "100",                                  
	KeyValues = { citizentype = 4 },                 
	Model = "models/akittu/stylizedexpie/akittuexpie_npc.mdl",  
	Weapons = { "weapon_ar2","weapon_smg1","weapon_pistol","weapon_shotgun","weapon_rpg" },         
	Category = Category
}

list.Set( "NPC", "Akittu's Expie (Friendly)", NPC )                       

local NPC =
{
	Name = "Akittu's Expie (Hostile)",                          
	Class = "npc_combine_s",                         
	Health = "100",   
	Numgrenades = "4",                                                            
	Model = "models/akittu/stylizedexpie/akittuexpie_npc_hostile.mdl",   
	Weapons = { "weapon_ar2","weapon_smg1","weapon_pistol","weapon_shotgun","weapon_rpg" },         
	Category = Category
}

list.Set( "NPC", "Akittu's Expie (Hostile)", NPC )    