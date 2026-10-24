if not SERVER then return end


CreateConVar(
    "deatheffect_spectator", "1",
    bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY, FCVAR_ARCHIVE),
    "allow players to enter spectator mode on the death screen",
    0, 1
)
CreateConVar(
    "deatheffect_compat", "0",
    bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY, FCVAR_ARCHIVE),
    "remove all cinematic effects before the option screen appears, for better compatibility with other mods",
    0, 1
)
CreateConVar(
    "deatheffect_options_delay", "4",
    bit.bor(FCVAR_REPLICATED, FCVAR_NOTIFY, FCVAR_ARCHIVE),
    "how many seconds it takes for the respawn/spectator options to show up",
    0, 60
)


util.AddNetworkString("DeathEffect_Respawn")
util.AddNetworkString("DeathEffect_UpdateCam")
util.AddNetworkString("DeathEffect_EnterSpectator")
util.AddNetworkString("DeathEffect_CompatUnblock")
util.AddNetworkString("DeathEffect_Config")
util.AddNetworkString("DeathEffect_Cause")

-- причина смерти: от неё зависит цвет экрана смерти и звук
local KILLER_MEMORY = 60
local KILLING_BLOW_TIME = 3
-- смерть мозга: только если умер во время эпилептического припадка, который идёт уже столько секунд
local BRAIN_DEATH_SEIZURE_TIME = 20
-- шокер остановил сердце: сколько секунд такая смерть считается смертью от электричества
local ELECTRO_MEMORY = 180

local function DeathEffect_DamageOwner(ent)
    if not IsValid(ent) then return end
    if ent:IsPlayer() then return ent end
    if ent:IsRagdoll() and hg and hg.RagdollOwner then
        local owner = hg.RagdollOwner(ent)
        if IsValid(owner) and owner:IsPlayer() then return owner end
    end
end

local function DeathEffect_RecordDamage(ent, dmgInfo)
    local ply = DeathEffect_DamageOwner(ent)
    if not ply or not ply:Alive() then return end

    local attacker = dmgInfo:GetAttacker()
    local now = CurTime()
    ply.DeathEffect_LastDamage = {type = dmgInfo:GetDamageType(), attacker = attacker, time = now}

    if IsValid(attacker) and attacker ~= ply and (attacker:IsPlayer() or attacker:IsNPC() or attacker:IsNextBot()) then
        ply.DeathEffect_LastKiller = {ent = attacker, npc = not attacker:IsPlayer(), time = now}
    end

    -- самоубийство засчитывается, только если игрок сам себя ударил (падения не считаются)
    if attacker == ply and bit.band(dmgInfo:GetDamageType(), DMG_FALL + DMG_CRUSH) == 0 then
        ply.DeathEffect_LastSelfHit = now
    end
end

hook.Add("EntityTakeDamage", "DeathEffect_Cause", function(ent, dmgInfo)
    DeathEffect_RecordDamage(ent, dmgInfo)
end)

hook.Add("HomigradDamage", "DeathEffect_Cause", function(ply, dmgInfo)
    DeathEffect_RecordDamage(ply, dmgInfo)
end)

local function DeathEffect_GetCause(ply, attacker)
    local now = CurTime()

    -- шокер остановил сердце, или добило электричество
    if ply.DeathEffect_ElectroHeart and now - ply.DeathEffect_ElectroHeart <= ELECTRO_MEMORY then return "shock" end
    local last = ply.DeathEffect_LastDamage
    if last and now - last.time <= KILLING_BLOW_TIME and bit.band(last.type, DMG_SHOCK + DMG_DISSOLVE + DMG_ENERGYBEAM) ~= 0 then return "shock" end

    if IsValid(attacker) and attacker:IsPlayer() and attacker ~= ply then return "player" end

    -- умер мозг: припадок шёл 20+ секунд
    local org = ply.organism
    if org and org.seizureActive and now - (org.seizureStart or now) >= BRAIN_DEATH_SEIZURE_TIME then return "brain" end

    local selfHit = ply.DeathEffect_LastSelfHit
    if selfHit and now - selfHit <= KILLING_BLOW_TIME then return "suicide" end

    local killer = ply.DeathEffect_LastKiller
    if killer and now - killer.time <= KILLER_MEMORY then
        return killer.npc and "npc" or "player"
    end
    if IsValid(attacker) and (attacker:IsNPC() or attacker:IsNextBot()) then return "npc" end

    -- истёк кровью от своих же ран
    if selfHit and now - selfHit <= KILLER_MEMORY then return "suicide" end

    local char = hg and hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or ply
    if ply:WaterLevel() >= 3 or (IsValid(char) and char:WaterLevel() >= 3) then return "drown" end
    if ply:IsOnFire() or (IsValid(char) and char:IsOnFire()) then return "fire" end

    local dmg = ply.DeathEffect_LastDamage
    if dmg and now - dmg.time <= KILLING_BLOW_TIME then
        local t = dmg.type
        if bit.band(t, DMG_BLAST) ~= 0 then return "explosion" end
        if bit.band(t, DMG_BURN + DMG_SLOWBURN) ~= 0 then return "fire" end
        if bit.band(t, DMG_DROWN) ~= 0 then return "drown" end
        if bit.band(t, DMG_POISON + DMG_NERVEGAS + DMG_ACID + DMG_RADIATION + DMG_PARALYZE) ~= 0 then return "poison" end
        if bit.band(t, DMG_SHOCK + DMG_DISSOLVE + DMG_ENERGYBEAM) ~= 0 then return "shock" end
        if bit.band(t, DMG_FALL + DMG_CRUSH) ~= 0 then return "fall" end
    end

    -- кровопотеря, остановка сердца, мозг, таймер смерти
    return "organism"
end

local function DeathEffectRoundActive()
    if zb and zb.ROUND_STATE ~= nil then
        return zb.ROUND_STATE == 1
    end

    return true
end

local function DeathEffect_GetTimerName(ply)
    if not IsValid(ply) then return nil end

    local id = ply:SteamID64()
    if id and id ~= "" then
        return "DeathEffect_AutoUnblock_" .. id
    end
    return "DeathEffect_AutoUnblock_EI" .. ply:EntIndex()
end

local function DeathEffect_ClearBlock(ply, removeTimer)
    if not IsValid(ply) then return end
    ply:SetNWBool("DeathEffect_BlockRespawn", false)
    ply.DeathEffect_DeathTime = nil
    if removeTimer ~= false then
        local tname = DeathEffect_GetTimerName(ply)
        if tname then timer.Remove(tname) end
    end
end



hook.Add("PlayerDeathThink", "DeathEffect_BlockRespawn", function(ply)
    if ply:GetNWBool("DeathEffect_BlockRespawn", false) then


        local dt = ply.DeathEffect_DeathTime
        if not dt then

            ply.DeathEffect_DeathTime = CurTime() - 11
            return false
        end
        if (CurTime() - dt) > 12 then
            DeathEffect_ClearBlock(ply, true)
            return
        end
        return false
    else

        if ply.DeathEffect_DeathTime and ply:Alive() then
            ply.DeathEffect_DeathTime = nil
        end
    end
end)


timer.Create("DeathEffect_StuckSweep", 5, 0, function()
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:GetNWBool("DeathEffect_BlockRespawn", false) and not ply:Alive() then
            local dt = ply.DeathEffect_DeathTime
            if not dt then
                ply.DeathEffect_DeathTime = CurTime() - 11
            elseif (CurTime() - dt) > 12 then
                DeathEffect_ClearBlock(ply, true)
            end
        end
    end
end)

hook.Add("PlayerDeath", "DeathEffect_OnDeath", function(ply, inflictor, attacker)
    local cause = DeathEffect_GetCause(ply, attacker)
    ply.DeathEffect_LastDamage = nil
    ply.DeathEffect_LastKiller = nil
    ply.DeathEffect_LastSelfHit = nil
    ply.DeathEffect_ElectroHeart = nil

    if not ply:IsBot() then
        net.Start("DeathEffect_Cause")
            net.WriteString(cause)
        net.Send(ply)
    end

    if ply:IsBot() then
        ply:SetNWBool("DeathEffect_BlockRespawn", false)

        timer.Simple(0, function()
            if IsValid(ply) and not ply:Alive() then
                ply:Spawn()
            end
        end)

        return
    end

    if not DeathEffectRoundActive() then
        ply:SetNWBool("DeathEffect_BlockRespawn", false)
        return
    end

    local realish = CurrentRound and CurrentRound().name == "realish"

    ply:SetNWBool("DeathEffect_BlockRespawn", true)
    ply.DeathEffect_DeathTime = CurTime()




    local failsafeDelay = realish and 3 or 12
    local tname = DeathEffect_GetTimerName(ply)
    if tname then
        timer.Create(tname, failsafeDelay, 1, function()
            if IsValid(ply) and ply:GetNWBool("DeathEffect_BlockRespawn", false) and not ply:Alive() then
                DeathEffect_ClearBlock(ply, false)
            end
        end)
    end

    net.Start("DeathEffect_Config")
        net.WriteBool(not realish and GetConVar("deatheffect_spectator"):GetBool())
        net.WriteBool(GetConVar("deatheffect_compat"):GetBool())
        net.WriteFloat(realish and 0 or GetConVar("deatheffect_options_delay"):GetFloat())
        net.WriteBool(realish)
    net.Send(ply)
end)

hook.Add("PlayerSpawn", "DeathEffect_OnSpawn", function(ply)
    DeathEffect_ClearBlock(ply, true)
    ply.DeathEffect_LastDamage = nil
    ply.DeathEffect_LastKiller = nil
    ply.DeathEffect_LastSelfHit = nil
    ply.DeathEffect_ElectroHeart = nil
end)

hook.Add("PlayerDisconnected", "DeathEffect_Cleanup", function(ply)
    local tname = DeathEffect_GetTimerName(ply)
    if tname then timer.Remove(tname) end
end)


net.Receive("DeathEffect_Respawn", function(len, ply)
    if IsValid(ply) and not ply:Alive() then
        DeathEffect_ClearBlock(ply, true)
        ply:UnSpectate()
        ply:Spawn()
    end
end)


net.Receive("DeathEffect_CompatUnblock", function(len, ply)
    if IsValid(ply) then
        DeathEffect_ClearBlock(ply, true)
    end
end)

net.Receive("DeathEffect_EnterSpectator", function(len, ply)
    if IsValid(ply) and not ply:Alive() then
        DeathEffect_ClearBlock(ply, true)
        ply.viewmode = 3
        ply:Spectate(OBS_MODE_ROAMING)
        ply:SetMoveType(MOVETYPE_NOCLIP)
    end
end)


net.Receive("DeathEffect_UpdateCam", function(len, ply)
    if IsValid(ply) and not ply:Alive() and ply:GetNWBool("DeathEffect_BlockRespawn", false) then
        local camPos = net.ReadVector()
        local camAng = net.ReadAngle()
        ply:SetPos(camPos)
        ply:SetEyeAngles(camAng)
    end
end)