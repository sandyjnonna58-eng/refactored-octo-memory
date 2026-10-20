-- код немного написан на гпт хуйне, но руки золотые чуть чуть его изменили немного.
-- так что так воооот ^w^

if SERVER then
    AddCSLuaFile()
    return
end

local SWEATER_MODEL = "models/sweaterport/expiesweater.mdl"

local EXPIE_MODELS = {
    ["models/akittu/stylizedexpie/akittuexpie.mdl"] = true,
    ["models/akittu/stylizedexpie/akittuexpiev3.mdl"] = true,
    ["models/akittu/stylizedmilky/akittumilky.mdl"] = true,
    ["models/akittu/stylizedmilky/akittumilky3dmouth.mdl"] = true,
}

local sweaterEnabled = CreateClientConVar( "exipe_sweater", "1", true, false, "ZCITY UWU SWEATOR FOR EXPIE ^w^ ENABLER")

local playerSweaters = {}
local ragdollSweaters = {}
local drawingSweater = false

local function IsExpie(ent)
    if not IsValid(ent) then return false end

    local model = string.lower(ent:GetModel() or "")
    return EXPIE_MODELS[model] == true
end

local function RemoveSweater(cache, ent)
    local sweater = cache[ent]

    if IsValid(sweater) then
        sweater:Remove()
    end

    cache[ent] = nil
end

local function ClearAllSweaters()
    for ent in pairs(playerSweaters) do
        RemoveSweater(playerSweaters, ent)
    end

    for ent in pairs(ragdollSweaters) do
        RemoveSweater(ragdollSweaters, ent)
    end
end

local function CreateSweater(parent, cache)
    if not IsValid(parent) then return nil end

    local sweater = ClientsideModel(
        SWEATER_MODEL,
        RENDERGROUP_OPAQUE
    )

    if not IsValid(sweater) then
        print("где нахуй? " .. SWEATER_MODEL)
        return nil
    end

    sweater:SetParent(parent)
    sweater:AddEffects(EF_BONEMERGE)
    sweater:AddEffects(EF_BONEMERGE_FASTCULL)
    sweater:SetNoDraw(true)

    cache[parent] = sweater
    return sweater
end

local function DrawSweater(parent, cache)
    if drawingSweater or not sweaterEnabled:GetBool() then return end
    if not IsValid(parent) then return end

    local sweater = cache[parent]

    if not IsValid(sweater) then
        sweater = CreateSweater(parent, cache)
    end

    if not IsValid(sweater) then return end

    sweater:SetParent(parent)
    sweater:SetupBones()

    drawingSweater = true
    local ok, err = pcall(function()
        sweater:DrawModel()
    end)
    drawingSweater = false

    if not ok then
        print("akittu_sweater: " .. tostring(err))
    end
end

hook.Add("PostPlayerDraw", "drawtheshit", function(ply)
    if not sweaterEnabled:GetBool() then
        RemoveSweater(playerSweaters, ply)
        return
    end

    if drawingSweater then return end

    if not IsValid(ply) or not ply:Alive() then
        RemoveSweater(playerSweaters, ply)
        return
    end

    if not IsExpie(ply) then
        RemoveSweater(playerSweaters, ply)
        return
    end

    DrawSweater(ply, playerSweaters)
end)

hook.Add("PostDrawOpaqueRenderables", "AkittuExpieRagdollSweater",
    function(drawingDepth, drawingSkybox)
        if drawingSweater or drawingSkybox then return end

        if not sweaterEnabled:GetBool() then
            for ent in pairs(ragdollSweaters) do
                RemoveSweater(ragdollSweaters, ent)
            end
            return
        end

        for _, ragdoll in ipairs(ents.FindByClass("prop_ragdoll")) do
            if not IsValid(ragdoll) then continue end

            if IsExpie(ragdoll) then
                DrawSweater(ragdoll, ragdollSweaters)
            else
                RemoveSweater(ragdollSweaters, ragdoll)
            end
        end
    end
)

cvars.AddChangeCallback("exipe_sweater",
    function(_, _, newValue)
        if tonumber(newValue) == 0 then
            ClearAllSweaters()
        end
    end,
    "AkittuExpieSweaterToggle"
)

hook.Add("EntityRemoved", "cleanupshit", function(ent)
    RemoveSweater(playerSweaters, ent)
    RemoveSweater(ragdollSweaters, ent)
end)

hook.Add("ShutDown", "removeshit", function()
    ClearAllSweaters()
end)
