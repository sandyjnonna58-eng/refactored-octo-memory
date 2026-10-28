local PANEL = {}
local curent_panel 
local red_select = Color(192,0,0)
local menu_music_default_path = "sound/rem_mainmenu.mp3"
local menu_music_appearance_path = "sound/rem_appearencemenu.mp3"
local menu_music_flags = "noblock noplay"
local menu_music_volume = 0.25
local menu_music_fade_speed = 1.8
local menu_music_station
local menu_music_station_path
local menu_music_station_lerp = 0
local menu_music_pending_station
local menu_music_pending_path
local menu_music_pending_lerp = 0
local menu_music_target_path = menu_music_default_path

DISCORD_URL = "https://discord.gg/475EmEdTgH"

local SOUND_MENU_SELECT = "ui/rem_select.wav"
local SOUND_MENU_HOVER = "ui/rem_hover.wav"
local SOUND_TYPEWRITER = "shitty/tap-resonant.wav"
local SOUND_TYPEWRITER_LEVEL = 55
local SOUND_TYPEWRITER_VOLUME = 0.25
local SOUND_TYPEWRITER_PITCH = 102

local function PlayTypewriterSound()
    local ply = LocalPlayer and LocalPlayer()
    if IsValid(ply) then
        ply:EmitSound(SOUND_TYPEWRITER, SOUND_TYPEWRITER_LEVEL, SOUND_TYPEWRITER_PITCH, SOUND_TYPEWRITER_VOLUME)
        return
    end
    surface.PlaySound(SOUND_TYPEWRITER)
end

local function StopMainMenuMusic()
    if menu_music_station then
        menu_music_station:Stop()
        menu_music_station = nil
    end
    menu_music_station_path = nil
    menu_music_station_lerp = 0
    if menu_music_pending_station then
        menu_music_pending_station:Stop()
        menu_music_pending_station = nil
    end
    menu_music_pending_path = nil
    menu_music_pending_lerp = 0
    menu_music_target_path = menu_music_default_path
end

local function QueueMainMenuMusic(owner, path)
    path = path or menu_music_default_path
    menu_music_target_path = path

    if not IsValid(owner) or MainMenu ~= owner then return end
    if menu_music_station and menu_music_station_path == path and not menu_music_pending_station then return end
    if menu_music_pending_station and menu_music_pending_path == path then return end

    sound.PlayFile(path, menu_music_flags, function(station)
        if not station then return end
        if not IsValid(owner) or MainMenu ~= owner or menu_music_target_path ~= path then
            station:Stop()
            return
        end

        if menu_music_pending_station and menu_music_pending_station ~= station then
            menu_music_pending_station:Stop()
        end

        menu_music_pending_station = station
        menu_music_pending_path = path
        menu_music_pending_lerp = 0
        station:EnableLooping(true)
        station:SetVolume(0)
        station:Play()
    end)
end

local function UpdateMainMenuMusic(owner)
    if not IsValid(owner) or MainMenu ~= owner then
        StopMainMenuMusic()
        return
    end

    if menu_music_station and menu_music_station_path ~= menu_music_target_path and not menu_music_pending_station then
        QueueMainMenuMusic(owner, menu_music_target_path)
    end

    local fadeStep = FrameTime() * menu_music_fade_speed

    if menu_music_pending_station then
        menu_music_pending_lerp = math.min(1, menu_music_pending_lerp + fadeStep)
        menu_music_pending_station:SetVolume(menu_music_volume * menu_music_pending_lerp)

        if menu_music_station then
            menu_music_station_lerp = math.max(0, menu_music_station_lerp - fadeStep)
            menu_music_station:SetVolume(menu_music_volume * menu_music_station_lerp)

            if menu_music_station_lerp <= 0.001 then
                menu_music_station:Stop()
                menu_music_station = menu_music_pending_station
                menu_music_station_path = menu_music_pending_path
                menu_music_station_lerp = menu_music_pending_lerp
                menu_music_pending_station = nil
                menu_music_pending_path = nil
                menu_music_pending_lerp = 0
            end
        elseif menu_music_pending_lerp >= 0.999 then
            menu_music_station = menu_music_pending_station
            menu_music_station_path = menu_music_pending_path
            menu_music_station_lerp = 1
            menu_music_pending_station = nil
            menu_music_pending_path = nil
            menu_music_pending_lerp = 0
        end
    elseif menu_music_station then
        menu_music_station_lerp = math.min(1, menu_music_station_lerp + fadeStep)
        menu_music_station:SetVolume(menu_music_volume * menu_music_station_lerp)
    elseif menu_music_target_path then
        QueueMainMenuMusic(owner, menu_music_target_path)
    end
end

local function MenuUnit(num)
    return math.floor(num * math.min(ScrW(), ScrH()) / 1000)
end

local function CreateMainMenuFonts()
    surface.CreateFont("ZCity_Menu_Tiny", {
        font = "Verily Serif Mono",
        size = ScreenScale(8),
        weight = 200
    })

    surface.CreateFont("ZCity_Menu_Small", {
        font = "Verily Serif Mono",
        size = ScreenScale(20),
        weight = 200
    })
end

hook.Add("OnScreenSizeChanged", "ZCity_MainMenu_Fonts", CreateMainMenuFonts)
CreateMainMenuFonts()

local Selects = {
    {Title = "Disconnect", BypassTransition = true, Func = function(luaMenu) luaMenu:PlayDisconnectCutscene() end},
    {Title = "Main Menu", Func = function(luaMenu) gui.ActivateGameUI() luaMenu:Close() end},
    {Title = "Loadout",
    GamemodeOnly = true,
    Func = function(luaMenu,pp) 
        if hg.DrawLoadoutMenu then
            hg.DrawLoadoutMenu(pp)
        end
    end},
    {Title = "Achievements", Func = function(luaMenu,pp) 
        hg.DrawAchievmentsMenu(pp)
    end},
    {Title = "Skills", Func = function(luaMenu,pp)
        if hg.DrawSkillsMenu then hg.DrawSkillsMenu(pp) end
    end},
    {Title = "Information", Func = function(luaMenu,pp)
        hg.DrawInformation(pp)
    end},
    {Title = "Keybinds", Func = function(luaMenu,pp)
        hg.DrawKeybinds(pp)
    end},
    {Title = "Settings", Func = function(luaMenu,pp) 
        hg.DrawSettings(pp) 
    end},
    {Title = "Appearance", Func = function(luaMenu,pp) hg.CreateApperanceMenu(pp) end},
    {Title = "Return", Func = function(luaMenu) luaMenu:Close() end},
}

local splasheh = {
    'LIKE HOMICIDED',
    'PLUV PLUV PLUVISKI',
    'LULU IS NOT DEAD | !PLUV',
    'THE TRAITOR WAS KILLED',
    'NAB HOMICIDE SERVER',
    'ALSO TRY MODDED HOMICIDE 2',
    'HOP ON Z-CITY',
    'JOHN Z-CITY',
    ':pluvrare:',
    'SAW51 IS REAL',
    'MORE SMALLTOWN',
    'MORE CLUE2022',
    'BACKROOMS == CLUE',
    'HELL IS NEAR',
    'I WISH YOU GOOD HEALTH, JASON STATHAM'
}

--print(string.upper('I wish you good health, Jason Statham'))
surface.CreateFont("ZC_MM_Title", {
    font = "Verily Serif Mono",
    size = ScreenScale(40),
    weight = 800,
    antialias = true
})
-- local Title = markup.Parse("error")

local Pluv = Material("pluv/pluvkid.jpg")

function PANEL:InitializeMarkup()
	local mapname = game.GetMap()
	local prefix = string.find(mapname, "_")
	if prefix then
		mapname = string.sub(mapname, prefix + 1)
	end
	local gm = splasheh[math.random(#splasheh)] .. " | " .. string.NiceName(mapname) 

    if hg.PluvTown.Active then
        local text = "<font=ZC_MM_Title><colour=199,2,2>    </colour>City</font>\n<font=ZCity_Menu_Tiny><colour=105,105,105>" .. gm .. "</colour></font>"

        self.SelectedPluv = table.Random(hg.PluvTown.PluvMats)

        return markup.Parse(text)
    end

    local text = "<font=ZC_MM_Title><colour=199,2,2,255>Z</colour>-City</font>\n<font=ZCity_Menu_Tiny><colour=105,105,105>" .. gm .. "</colour></font>"
    return markup.Parse(text)
end

local color_red = Color(255,25,25,45)
local clr_gray = Color(255,255,255,25)
local clr_verygray = Color(10,10,19,235)
local appearance_preview = {
    width = 340,
    height = 920,
    right = 0,
    top = 210,
    enter_time = 1.35,
    enter_delay = 0.35,
    exit_time = 0.7,
    exit_delay = 0.05,
    ambient = Color(0, 0, 0, 255),
    light_right = Color(115, 115, 115, 255),
    light_left = Color(85, 85, 85, 255),
    light_front = Color(92, 92, 92, 255),
    light_back = Color(0, 0, 0, 255),
    light_top = Color(55, 55, 55, 255),
    light_bottom = Color(0, 0, 0, 255),
    fov = 13,
    cam_pos = Vector(100, 0, 65),
    look_ang = Angle(11, 180, 0),
    entity_ang = Angle(0, 0, 0),
    head_yaw = -45,
    head_pitch = 0,
    head_mouse_yaw = 7,
    head_mouse_pitch = 4,
    sequence = "idle_suitcase"
}
local disconnect_cutscene = {
    ui_fade_time = 0.45,
    walk_delay = 0.08,
    walk_time = 2.5,
    walk_distance = 135,
    walk_sequence = "walk_all",
    walk_playback_rate = 1,
    walk_ang = Angle(0, 90, 0),
    black_fade_time = 0.7,
    disconnect_delay = 0.05
}
local menu_profile = {
    left = 30,
    top = 90,
    min_width = 360,
    height = 160,
    medal_size = 50
}
local menu_live = {
    drift_x = 14,
    drift_y = 10,
    shake_x = 1,
    shake_y = 1,
    title_x = 30,
    title_y = 25,
    title_mouse_x = 10,
    title_mouse_y = 7,
    title_float_x = 4,
    title_float_y = 3,
    title_hover_scale = 0.08,
    button_hover_scale = 0.008,
    button_drift_x = 4,
    button_drift_y = 1,
    button_shake_x = 0,
    button_shake_y = 0,
    profile_drift_x = 9,
    profile_drift_y = 6,
    bottom_drift_x = 10,
    bottom_drift_y = 6,
    logo_drift_x = 7,
    logo_drift_y = 4,
    enter_x = 18,
    enter_y = 12,
    bg_drift_x = 22,
    bg_drift_y = 12
}
local menu_profile_fallback_band = {
    icon = Material("vgui/mats_jack_awards/10")
}
local menu_profile_fallback_medal = {
    icon = Material("vgui/mats_jack_awards/pt")
}
local menu_news = {
    top = 24,
    height = 36,
    speed = 100,
    refresh = 2
}

local function MenuCanStartNet(messageName)
    return util.NetworkStringToID(messageName) ~= 0
end

hg.Leaderboard = hg.Leaderboard or {Rows = {}, NextRequest = 0}

function hg.Leaderboard.Request(limit)
    if not MenuCanStartNet("zb_sql_leaderboard") then return end
    if (hg.Leaderboard.NextRequest or 0) > CurTime() then return end
    hg.Leaderboard.NextRequest = CurTime() + 3

    net.Start("zb_sql_leaderboard")
        net.WriteUInt(math.Clamp(limit or 10, 1, 10), 8)
    net.SendToServer()
end

function hg.Leaderboard.Get(limit)
    hg.Leaderboard.Request(limit)

    local rows = hg.Leaderboard.Rows or {}
    if limit and #rows > limit then
        local trimmed = {}
        for i = 1, limit do
            trimmed[i] = rows[i]
        end
        return trimmed
    end

    return rows
end

function hg.Leaderboard.GetAwards(row)
    if not row or not zb or not zb.Experience or not zb.Experience.GetAwards then return menu_profile_fallback_band, menu_profile_fallback_medal end
    return zb.Experience.GetAwards({skill = row.skill or 0, exp = row.xp or 0})
end

function hg.Leaderboard.GetMedalName(row)
    local _, medal = hg.Leaderboard.GetAwards(row)
    return string.upper((medal and medal.name) or "UNRANKED")
end

if not hg.Leaderboard.NetHooked then
    net.Receive("zb_sql_leaderboard", function()
        local count = net.ReadUInt(8)
        local rows = {}

        for i = 1, count do
            rows[i] = {
                steamid = net.ReadString(),
                name = net.ReadString(),
                skill = net.ReadFloat(),
                xp = net.ReadUInt(32),
                kills = net.ReadUInt(16),
                deaths = net.ReadUInt(16),
                kd = net.ReadFloat()
            }
        end

        hg.Leaderboard.Rows = rows
    end)

    hg.Leaderboard.NetHooked = true
end

local function CleanupPreviewAccessories(ent)
    if not IsValid(ent) or not ent.modelAccess then return end
    for k, v in pairs(ent.modelAccess) do
        if IsValid(v) then
            v:Remove()
        end
        ent.modelAccess[k] = nil
    end
end

function PANEL:GetPreviewAppearance()
    if not hg or not hg.Appearance then return end
    local appearance
    if hg.Appearance.LoadAppearanceFile and hg.Appearance.SelectedAppearance then
        appearance = hg.Appearance.LoadAppearanceFile(hg.Appearance.SelectedAppearance:GetString())
    end
    appearance = appearance or (hg.Appearance.GetRandomAppearance and hg.Appearance.GetRandomAppearance())
    if not appearance or not hg.Appearance.PlayerModels then return end
    local tMdl = hg.Appearance.PlayerModels[1][appearance.AModel] or hg.Appearance.PlayerModels[2][appearance.AModel]
    if not tMdl or not tMdl.mdl then return end
    return table.Copy(appearance), tMdl
end

function PANEL:GetProfileInfo()
    local ply = LocalPlayer()
    if not IsValid(ply) then
        return "Unknown", "0 XP", nil
    end

    local username = ply:GetNWString("PlayerName", "")
    if username == "" then
        username = ply:Nick()
    end

    local xp = tostring(math.floor(tonumber(ply.exp) or 0)) .. " XP"
    return username, xp, ply
end

function PANEL:GetLiveMouse()
    local mx, my = gui.MouseX(), gui.MouseY()
    if mx <= 0 and my <= 0 then
        mx = ScrW() * 0.5
        my = ScrH() * 0.5
    end
    local nx = math.Clamp((mx / ScrW() - 0.5) * 2, -1, 1)
    local ny = math.Clamp((my / ScrH() - 0.5) * 2, -1, 1)
    return mx, my, nx, ny
end

function PANEL:GetLiveOffset(xAmount, yAmount)
    local _, _, nx, ny = self:GetLiveMouse()
    return nx * xAmount, ny * yAmount
end

function PANEL:GetLiveShake(seedX, seedY, xAmount, yAmount)
    local t = RealTime()
    return math.sin(t * 1.8 + seedX) * xAmount, math.cos(t * 2.4 + seedY) * yAmount
end

function PANEL:Think()
    UpdateMainMenuMusic(self)

    if self.DisconnectBlackStart then
        local blackFrac = math.Clamp((CurTime() - self.DisconnectBlackStart) / math.max(disconnect_cutscene.black_fade_time, 0.001), 0, 1)
        self.DisconnectBlackAlpha = 255 * blackFrac
    end

    if self.DisconnectWalkStart and CurTime() >= self.DisconnectWalkStart then
        local walkFrac = math.Clamp((CurTime() - self.DisconnectWalkStart) / disconnect_cutscene.walk_time, 0, 1)
        if walkFrac < 1 and CurTime() > (self.NextFootstep or 0) then
            self.NextFootstep = CurTime() + 0.38
            local vol = 1 - walkFrac
            if LocalPlayer and IsValid(LocalPlayer()) then
                LocalPlayer():EmitSound("player/footsteps/concrete" .. math.random(1,4) .. ".wav", 0, 100, vol)
            end
        end
    end

    self.LiveLerp = LerpFT(0.08, self.LiveLerp or 0, 1)
    self:ThinkWDMenu()
end

function PANEL:CreateAppearancePreview()
    local tbl, tMdl = self:GetPreviewAppearance()
    if not tbl or not tMdl then return end

    if hg.Appearance and hg.Appearance.PrecacheModels then
        hg.Appearance.PrecacheModels()
    end

    local holderW = MenuUnit(appearance_preview.width)
    local holderH = MenuUnit(appearance_preview.height)
    local targetX = ScrW() - holderW - MenuUnit(appearance_preview.right)
    local targetY = MenuUnit(appearance_preview.top)

    self.previewHolder = vgui.Create("DPanel", self)
    local holder = self.previewHolder
    holder:SetSize(holderW, holderH)
    holder:SetPos(targetX, ScrH())
    holder:SetAlpha(0)
    holder.TargetX = targetX
    holder.TargetY = targetY
    holder.ClosedY = ScrH()
    holder:SetMouseInputEnabled(false)
    holder.Paint = function() end
    holder.Think = function(this)
        if not this.AppearanceFollow then return end
        local x, y = this:GetPos()
        local targetPosX = this.TargetX or x
        local targetPosY = this.TargetY or y
        local nextX = LerpFT(0.18, x, targetPosX)
        local nextY = LerpFT(0.18, y, targetPosY)
        if math.abs(targetPosX - nextX) < 1 then
            nextX = targetPosX
        end
        if math.abs(targetPosY - nextY) < 1 then
            nextY = targetPosY
        end
        this:SetPos(math.Round(nextX), math.Round(nextY))
    end

    local preview = vgui.Create("DModelPanel", holder)
    self.previewModel = preview
    preview.OwnerMenu = self
    preview:Dock(FILL)
    preview:SetModel(util.IsValidModel(tostring(tMdl.mdl)) and tostring(tMdl.mdl) or "models/player/group01/female_01.mdl")
    preview:SetFOV(appearance_preview.fov)
    preview:SetLookAng(appearance_preview.look_ang)
    preview:SetCamPos(appearance_preview.cam_pos)
    preview:SetAmbientLight(appearance_preview.ambient)
    preview:SetDirectionalLight(BOX_RIGHT, appearance_preview.light_right)
    preview:SetDirectionalLight(BOX_LEFT, appearance_preview.light_left)
    preview:SetDirectionalLight(BOX_FRONT, appearance_preview.light_front)
    preview:SetDirectionalLight(BOX_BACK, appearance_preview.light_back)
    preview:SetDirectionalLight(BOX_TOP, appearance_preview.light_top)
    preview:SetDirectionalLight(BOX_BOTTOM, appearance_preview.light_bottom)
    preview:SetMouseInputEnabled(false)
    preview.AppearanceTable = tbl

    local oldPaint = preview.Paint
    preview.Paint = function(pnl, w, h)
        DisableClipping(true)
        oldPaint(pnl, w, h)
        DisableClipping(false)
    end

    function preview:LayoutEntity(ent)
        local appearance = self.AppearanceTable
        if not appearance or not hg or not hg.Appearance or not hg.Appearance.PlayerModels then return end

        local modelData = hg.Appearance.PlayerModels[1][appearance.AModel] or hg.Appearance.PlayerModels[2][appearance.AModel]
        if not modelData or not modelData.mdl then return end

        local colorData = appearance.AColor or color_white
        ent:SetNWVector("PlayerColor", Vector((colorData.r or 255) / 255, (colorData.g or 255) / 255, (colorData.b or 255) / 255))

        local targetPos = Vector(0, 0, 0)
        if self.OwnerMenu and self.OwnerMenu.DisconnectCutscene then
            if self.OwnerMenu.DisconnectWalkStart and CurTime() >= self.OwnerMenu.DisconnectWalkStart then
                local walkFrac = math.Clamp((CurTime() - self.OwnerMenu.DisconnectWalkStart) / disconnect_cutscene.walk_time, 0, 1)
                targetPos = Vector(0, walkFrac * disconnect_cutscene.walk_distance, 0)
            end
        end
        ent:SetPos(targetPos)

        local targetEntityAngle = self.EntityAngleOverride or appearance_preview.entity_ang
        self.EntityAngle = LerpAngle(RealFrameTime() * 6, self.EntityAngle or targetEntityAngle, targetEntityAngle)
        ent:SetAngles(self.EntityAngle)

        local sequenceName = self.SequenceNameOverride or appearance_preview.sequence
        local seq = ent:LookupSequence(sequenceName)
        
        if self.OwnerMenu and self.OwnerMenu.DisconnectCutscene and (not seq or seq < 0) then
            local fallbacks = {"walk_suitcase", "walk_all", "walk", "walk_all_suitcase"}
            for _, v in ipairs(fallbacks) do
                seq = ent:LookupSequence(v)
                if seq and seq >= 0 then
                    sequenceName = v
                    break
                end
            end
        end

        if (not seq or seq < 0) and sequenceName != appearance_preview.sequence then
            sequenceName = appearance_preview.sequence
            seq = ent:LookupSequence(sequenceName)
        end
        if seq and seq >= 0 then
            if self.ActiveSequenceName != sequenceName then
                ent:ResetSequence(seq)
                self.ActiveSequenceName = sequenceName
            end
            ent:SetPlaybackRate(self.SequencePlaybackRate or 1)
            ent:FrameAdvance(RealFrameTime() * (self.SequencePlaybackRate or 1))
        end

        local owner = self.OwnerMenu
        local nx, ny = 0, 0
        if IsValid(owner) and owner.GetLiveMouse then
            local _, _, newNX, newNY = owner:GetLiveMouse()
            nx, ny = newNX, newNY
        end
        local targetYaw = appearance_preview.head_yaw - nx * appearance_preview.head_mouse_yaw
        local targetPitch = appearance_preview.head_pitch - ny * appearance_preview.head_mouse_pitch
        self.HeadYawLerp = LerpFT(0.08, self.HeadYawLerp or appearance_preview.head_yaw, targetYaw)
        self.HeadPitchLerp = LerpFT(0.08, self.HeadPitchLerp or appearance_preview.head_pitch, targetPitch)
        ent:SetPoseParameter("head_yaw", self.HeadYawLerp)
        ent:SetPoseParameter("head_pitch", self.HeadPitchLerp)
        
        if self.OwnerMenu and self.OwnerMenu.DisconnectCutscene then
            ent:SetPoseParameter("move_x", 1)
            ent:SetPoseParameter("move_y", 0)
        end
        
        ent:SetSubMaterial()
        self:SetCamPos(self.CamPosOverride or appearance_preview.cam_pos)
        self:SetFOV(self.FOVOverride or appearance_preview.fov)
        self:SetLookAng(self.LookAngOverride or appearance_preview.look_ang)

        if ent:GetModel() != modelData.mdl then
            CleanupPreviewAccessories(ent)
            ent:SetModel(modelData.mdl)
            self:SetModel(modelData.mdl)
            self.ActiveSequenceName = nil
        end

        local clothes = appearance.AClothes or {}
        local mats = ent:GetMaterials()
        for k, v in SortedPairs(modelData.submatSlots or {}) do
            local slot = 1
            for i = 1, #mats do
                if mats[i] == v then
                    slot = i - 1
                    break
                end
            end
            local sexID = modelData.sex and 2 or 1
            local clothMat = hg.Appearance.Clothes[sexID] and hg.Appearance.Clothes[sexID][clothes[k]]
            ent:SetSubMaterial(slot, clothMat or (hg.Appearance.Clothes[sexID] and hg.Appearance.Clothes[sexID].normal) or nil)
        end

        local facemapSlot = hg.Appearance.FacemapsModels and hg.Appearance.FacemapsModels[modelData.mdl]
        for i = 1, #mats do
            if facemapSlot and hg.Appearance.FacemapsSlots[mats[i]] and hg.Appearance.FacemapsSlots[mats[i]][appearance.AFacemap] then
                ent:SetSubMaterial(i - 1, hg.Appearance.FacemapsSlots[mats[i]][appearance.AFacemap])
            end
        end

        appearance.ABodygroups = appearance.ABodygroups or {}
        for k, v in SortedPairs(ent:GetBodyGroups()) do
            if not appearance.ABodygroups[v.name] then continue end
            local bodygroupData = hg.Appearance.Bodygroups[v.name]
            local bodygroupSet = bodygroupData and bodygroupData[modelData.sex and 2 or 1] and bodygroupData[modelData.sex and 2 or 1][appearance.ABodygroups[v.name]]
            if not bodygroupSet then continue end
            for i = 0, #v.submodels do
                if bodygroupSet[1] == v.submodels[i] then
                    ent:SetBodygroup(k - 1, i)
                    break
                end
            end
        end
    end

    function preview:PostDrawModel(ent)
        local appearance = self.AppearanceTable
        if not appearance or not appearance.AAttachments then return end
        for _, attach in ipairs(appearance.AAttachments) do
            local accessoryData = hg.Accessories and hg.Accessories[attach]
            if accessoryData then
                DrawAccesories(ent, ent, attach, accessoryData, false, true)
            end
        end
        ent:SetupBones()
    end

    function preview:OnRemove()
        if IsValid(self.Entity) then
            CleanupPreviewAccessories(self.Entity)
        end
    end

    timer.Simple(0, function()
        if not IsValid(holder) then return end
        holder:MoveTo(targetX, targetY, appearance_preview.enter_time, 0, appearance_preview.enter_delay)
        holder:AlphaTo(255, appearance_preview.enter_time * 0.75, appearance_preview.enter_delay)
    end)
end

function PANEL:Init()
    self:SetAlpha(0)
    self:SetSize(ScrW(), ScrH())
    self:Center()
    self:SetTitle("")
    self:SetDraggable(false)
    self:SetBorder(false)
    self:SetColorBG(clr_verygray)
    self:SetDraggable(false)
    self:ShowCloseButton(false)
    curent_panel = nil
    self.Title, self.TitleShadow = self:InitializeMarkup()
    self.LiveLerp = 0
    self.DisconnectCutscene = false
    self.DisconnectBackgroundAlpha = 255
    self.DisconnectBlackAlpha = 0
    self:UseDefaultMenuMusic()

    timer.Simple(0, function()
        if self.First then
            self:First()
        end
    end)

    self:CreateAppearancePreview()
    self:CreateWDMenu()

    self.panelparrent = vgui.Create("DPanel", self)
    self.panelparrent:SetPos(0, 0)
    self.panelparrent:SetSize(ScrW(), ScrH())
    self.panelparrent:MoveToBack()
    self.panelparrent.Paint = function(this, w, h) end
end

function PANEL:First( ply )
    self:AlphaTo( 255, 0.1, 0, nil )
end

function PANEL:Paint(w,h)
    local backgroundAlpha = math.Clamp(self.DisconnectBackgroundAlpha or 255, 0, 255)
    local WD = hg.WDMenu
    if backgroundAlpha > 0 then
        -- сцены со сбоями (cl_menu_wd.lua)
        local oldMul = surface.GetAlphaMultiplier()
        surface.SetAlphaMultiplier(oldMul * backgroundAlpha / 255)
        -- под видеофоном точечные сцены не нужны
        if IsValid(self.wdVideo) then
            surface.SetDrawColor(0, 0, 0, 255)
            surface.DrawRect(0, 0, w, h)
        else
            WD.DrawBackground(w, h)
        end
        surface.SetAlphaMultiplier(oldMul)
    end
    if (self.DisconnectBlackAlpha or 0) > 0 then
        surface.SetDrawColor(0, 0, 0, self.DisconnectBlackAlpha)
        surface.DrawRect(0, 0, w, h)
    end
end

-- список, карусель и загрузка - поверх дочерних панелей (видеофона); в разделах меню их нет
function PANEL:PaintOver(w, h)
    local WD = hg.WDMenu
    if IsValid(self.wdInput) and self.wdInput:IsVisible() then
        local a = self.wdInput:GetAlpha()
        self.WDRects = WD.DrawList(self.WDItems, self.WDSelected, a)
        self.WDZones = WD.DrawCarousel(self.WDCards, self.WDCard, a, self.WDHover and self.WDHover.zone)
        WD.DrawProfile(LocalPlayer():Nick(), a)
    end
    if self.WDBootStart and not WD.DrawBoot(RealTime() - self.WDBootStart, LocalPlayer():Nick()) then
        self.WDBootStart = nil
    end
end

function PANEL:PlayDisconnectCutscene()
    if self.DisconnectCutscene then return end
    self.DisconnectCutscene = true
    self.DisconnectFadeStart = CurTime()
    self.DisconnectBackgroundAlpha = 255
    self.DisconnectBlackAlpha = 0
    self:SetKeyboardInputEnabled(false)
    self:SetMouseInputEnabled(false)

    StopMainMenuMusic()

    if IsValid(self.previewHolder) then
        self.previewHolder:SetVisible(true)
        self.previewHolder:SetAlpha(255)
    end

    if IsValid(self.previewModel) then
        self.previewModel.SequenceNameOverride = disconnect_cutscene.walk_sequence
        self.previewModel.SequencePlaybackRate = disconnect_cutscene.walk_playback_rate
        self.previewModel.EntityAngleOverride = disconnect_cutscene.walk_ang
        self.previewModel.ActiveSequenceName = nil
    end

    for _, child in ipairs(self:GetChildren()) do
        if child != self.previewHolder then
            child:AlphaTo(0, disconnect_cutscene.ui_fade_time, 0, function()
                if IsValid(child) then
                    child:SetVisible(false)
                end
            end)
        end
    end

    local function startBlackFade()
        if not IsValid(self) then return end
        self.DisconnectBlackStart = CurTime()
        self.DisconnectBlackAlpha = 0
        timer.Simple(disconnect_cutscene.black_fade_time + disconnect_cutscene.disconnect_delay, function()
            if IsValid(self) then
                RunConsoleCommand("disconnect")
            end
        end)
    end

    self.DisconnectWalkStart = CurTime() + disconnect_cutscene.ui_fade_time + disconnect_cutscene.walk_delay

    timer.Simple(disconnect_cutscene.ui_fade_time + disconnect_cutscene.walk_delay + disconnect_cutscene.walk_time, function()
        if IsValid(self) then
            startBlackFade()
        end
    end)
end

function PANEL:ResetCurrentPanel()
    curent_panel = nil
end

-- меню в стиле хакерского терминала (cl_menu_wd.lua): рисуется в PANEL:Paint, мышь ловит прозрачная панель на весь экран
local wd_cards = {
    {title = "Join our Discord", badge = "D", mat = Material("rem_wd/card_discord.png", "smooth"),
        text = "Want to find people to play with, report a bug or share your clips? Join our community on Discord and become part of the family.",
        url = function() return DISCORD_URL end},
    {title = "Customize your look", badge = "A", mat = Material("rem_wd/card_appearance.png", "smooth"),
        text = "Pick your face, clothes and accessories. Your character is the first thing other players see in the city.",
        select = "Appearance"},
    {title = "Level up your skills", badge = "+", mat = Material("rem_wd/card_skills.png", "smooth"),
        text = "Every fight, every escape and every day you survive gives you experience. Spend it on perks that fit the way you play.",
        select = "Skills"},
    {title = "Achievements", badge = "!", mat = Material("rem_wd/card_achievements.png", "smooth"),
        text = "Do the strange things, the brave things and the stupid things. See what you have unlocked and what is still waiting.",
        select = "Achievements"},
    {title = "Settings and keybinds", badge = "#", mat = Material("rem_wd/card_settings.png", "smooth"),
        text = "Tune graphics, sound and effects, and set up your keys before you hit the streets.",
        select = "Settings"},
}

local CARD_TIME_AUTO = 8 -- карточки листаются сами

local function FindSelect(title)
    for _, v in ipairs(Selects) do
        if v.Title == title then return v end
    end
end

local function InRect(r, x, y)
    return r and x >= r[1] and x <= r[1] + r[3] and y >= r[2] and y <= r[2] + r[4]
end

function PANEL:CreateWDMenu()
    self.WDItems = {}
    -- в Selects первый пункт - нижний
    for i = #Selects, 1, -1 do
        local v = Selects[i]
        if v.GamemodeOnly and engine.ActiveGamemode() != "zcity" then continue end
        self.WDItems[#self.WDItems + 1] = {text = v.Title, tbl = v}
    end
    self.WDCards = wd_cards
    self.WDSelected = 1
    self.WDCard = 1
    self.WDCardTime = RealTime()

    -- загрузка и экран входа - один раз за сессию
    if not hg.WDMenu.BootDone then
        hg.WDMenu.BootDone = true
        self.WDBootStart = RealTime()
    end

    local luaMenu = self
    local input = vgui.Create("DPanel", self)
    self.wdInput = input
    input:SetPos(0, 0)
    input:SetSize(ScrW(), ScrH())
    input.Paint = function() end
    input.OnMousePressed = function(this, code)
        if code ~= MOUSE_LEFT then return end
        luaMenu:WDClick()
    end

    -- личный видеофон (cl_menu_wd.lua): HTML-панель за всем остальным
    if hg.WDMenu.HasPrivateVideo() then
        local video = vgui.Create("DHTML", self)
        self.wdVideo = video
        video:SetPos(0, 0)
        video:SetSize(ScrW(), ScrH())
        video:SetMouseInputEnabled(false)
        video:SetKeyboardInputEnabled(false)
        video:SetHTML(hg.WDMenu.PrivateVideoHTML())
        video:MoveToBack()
    end

    local avatar = vgui.Create("AvatarImage", self)
    self.wdAvatar = avatar
    local sh = ScrH()
    avatar:SetPos(math.floor(sh * 0.018), math.floor(sh * 0.011))
    avatar:SetSize(math.floor(sh * 0.031), math.floor(sh * 0.031))
    avatar:SetPlayer(LocalPlayer(), 64)
    avatar:SetMouseInputEnabled(false)
end

function PANEL:WDBooting()
    return self.WDBootStart and RealTime() - self.WDBootStart < hg.WDMenu.BootLength
end

function PANEL:WDClick()
    if self:WDBooting() then
        self.WDBootStart = nil
        return
    end
    local hover = self.WDHover
    if not hover then return end
    if hover.item then
        local item = self.WDItems[hover.item]
        if item then self:ActivateSelect(item.text, item.tbl) end
    elseif hover.zone == "prev" or hover.zone == "next" then
        surface.PlaySound(SOUND_MENU_HOVER)
        self.WDCard = (self.WDCard - 1 + (hover.zone == "next" and 1 or -1)) % #wd_cards + 1
        self.WDCardTime = RealTime()
    elseif hover.zone == "access" then
        local card = wd_cards[self.WDCard]
        if card.url then
            surface.PlaySound(SOUND_MENU_SELECT)
            gui.OpenURL(card.url())
        elseif card.select and FindSelect(card.select) then
            self:ActivateSelect(card.select, FindSelect(card.select))
        end
    end
end

function PANEL:OnKeyCodePressed(code)
    if self:WDBooting() then self.WDBootStart = nil end
end

function PANEL:ThinkWDMenu()
    if not IsValid(self.wdInput) then return end

    -- персонаж справа нужен только редактору внешности (и прощальной сценке)
    if IsValid(self.previewHolder) and self.previewHolder:IsVisible() and curent_panel ~= "appearance" and not self.DisconnectCutscene then
        self.previewHolder:SetVisible(false)
    end

    -- аватар не должен торчать поверх загрузки
    if self.wdInput:IsVisible() and IsValid(self.wdAvatar) then self.wdAvatar:SetVisible(not self:WDBooting()) end

    if RealTime() - (self.WDCardTime or 0) > CARD_TIME_AUTO then
        self.WDCard = self.WDCard % #wd_cards + 1
        self.WDCardTime = RealTime()
    end

    local hover
    if self.wdInput:IsVisible() and self.wdInput:IsHovered() and not self.SwitchingPanel and not self:WDBooting() then
        local mx, my = gui.MouseX(), gui.MouseY()
        for i, r in ipairs(self.WDRects or {}) do
            if InRect(r, mx, my) then hover = {item = i} break end
        end
        if not hover then
            for _, name in ipairs({"prev", "next", "access"}) do
                if InRect(self.WDZones and self.WDZones[name], mx, my) then hover = {zone = name} break end
            end
        end
    end
    if hover and hover.item and hover.item ~= self.WDSelected then
        surface.PlaySound(SOUND_MENU_HOVER)
        self.WDSelected = hover.item
    end
    self.WDHover = hover
    self.wdInput:SetCursor(hover and "hand" or "arrow")
    -- пока мышь над карусель, сама она не листается
    if self.WDZones and InRect(self.WDZones.panel, gui.MouseX(), gui.MouseY()) then self.WDCardTime = RealTime() end
end

function PANEL:ActivateSelect(strTitle, tbl)
    local luaMenu = self
    if luaMenu.DisconnectCutscene then return end
    if luaMenu.SwitchingPanel then return end
    surface.PlaySound(SOUND_MENU_SELECT)

    if tbl.BypassTransition then
        tbl.Func(luaMenu)
        return
    end

    if strTitle == "Appearance" and IsValid(luaMenu.previewHolder) then
        luaMenu.previewHolder:SetVisible(true)
        luaMenu.previewHolder:SetAlpha(255)
    end

    for _, child in ipairs(luaMenu:GetChildren()) do
        -- видеофон остаётся и за разделами меню
        if child ~= luaMenu.panelparrent and child ~= luaMenu.wdVideo and not (strTitle == "Appearance" and child == luaMenu.previewHolder) then
            child:AlphaTo(0, 0.2, 0, function()
                if IsValid(child) then child:SetVisible(false) end
            end)
        end
    end

    luaMenu.SwitchingPanel = true
    local oldPanel = luaMenu.panelparrent
    local function openPanel()
        if IsValid(luaMenu.panelparrent) then
            luaMenu.panelparrent:Remove()
        end
        luaMenu.panelparrent = vgui.Create("DPanel", luaMenu)

        luaMenu.panelparrent:SetPos(0, 0)
        luaMenu.panelparrent:SetSize(ScrW(), ScrH())
        luaMenu.panelparrent:MoveToFront()
        luaMenu.panelparrent.Paint = function(this, w, h) end
        curent_panel = string.lower(strTitle)
        tbl.Func(luaMenu, luaMenu.panelparrent)
        luaMenu.SwitchingPanel = false
    end

    if IsValid(oldPanel) then
        oldPanel:AlphaTo(0, 0.2, 0, openPanel)
    else
        openPanel()
    end
end

function PANEL:Close()
    if self.DisconnectCutscene then return end
    StopMainMenuMusic()
    if IsValid(self.previewModel) and IsValid(self.previewModel.Entity) then
        CleanupPreviewAccessories(self.previewModel.Entity)
    end
    if IsValid(self.previewHolder) then
        self.previewHolder.AppearanceFollow = false
        self.previewHolder:MoveTo(self.previewHolder.TargetX or self.previewHolder:GetX(), self.previewHolder.ClosedY or ScrH(), appearance_preview.exit_time, 0, appearance_preview.exit_delay)
        self.previewHolder:AlphaTo(0, appearance_preview.exit_time * 0.75, appearance_preview.exit_delay)
    end
    self:AlphaTo(0, appearance_preview.exit_time, 0, function()
        if IsValid(self) then
            self:Remove()
        end
    end)
    self:SetKeyboardInputEnabled(false)
    self:SetMouseInputEnabled(false)
end

function PANEL:OnRemove()
    StopMainMenuMusic()
end

function PANEL:SetMenuMusic(path)
    QueueMainMenuMusic(self, path)
end

function PANEL:UseDefaultMenuMusic()
    self:SetMenuMusic(menu_music_default_path)
end

function PANEL:UseAppearanceMenuMusic()
    self:SetMenuMusic(menu_music_appearance_path)
end

vgui.Register( "ZMainMenu", PANEL, "ZFrame")

hook.Add("OnPauseMenuShow","OpenMainMenu",function()
    local run = hook.Run("OnShowZCityPause")
    if run != nil then
        return run
    end

    if MainMenu and IsValid(MainMenu) then
        if MainMenu.DisconnectCutscene then
            return false
        end
        MainMenu:Close()
        MainMenu = nil
        return false
    end

    MainMenu = vgui.Create("ZMainMenu")
    MainMenu:MakePopup()
    return false
end)
