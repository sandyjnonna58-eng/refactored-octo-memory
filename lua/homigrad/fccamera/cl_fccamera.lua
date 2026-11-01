-- Камера Far Cry для мачете - клиент (описание в sh_fccamera.lua): видоискатель рисуется сам (виньетка, уголки,
-- точки фокуса, зум, курс, расстояние), отметки игроков и NPC, силуэты отмеченных сквозь стены.
-- Звуки берутся из sound/rem_fccam/ (личный контент-пак), если их нет - стандартные звуки HL2.
hg = hg or {}
hg.FCCamera = hg.FCCamera or {}
local CAM = hg.FCCamera

CAM.Tagged = CAM.Tagged or {}
CAM.LocalUp = CAM.LocalUp or false
CAM.ZoomStep = 1
CAM.ZoomMul = 1

local ZOOM = {0.55, 0.28, 0.14} -- доля обычного FOV на каждой ступени
local FOCUS_TIME = 0.45          -- сколько держать цель в прицеле, чтобы отметить
local MAX_DIST = 9000
local AIM_DEG = 3                -- насколько точно надо навести (при зуме уже)
local TAG_COL = Color(255, 75, 50)
local LINE_COL = Color(235, 235, 235, 170)

local SOUNDS = {
	open = {"rem_fccam/closebinoculars.wav", "items/flashlight1.wav"},
	close = {"rem_fccam/closebinoculars.wav", "items/flashlight1.wav"},
	tag = {"rem_fccam/markerplaced.wav", "npc/scanner/scanner_photo1.wav"},
	untag = {"rem_fccam/markerremoved.wav", "buttons/button16.wav"},
	zoom1 = {"rem_fccam/zoomfirst.wav", "buttons/lightswitch2.wav"},
	zoom2 = {"rem_fccam/zoomfinal.wav", "buttons/lightswitch2.wav"},
}
local resolved = {}
local function Snd(kind)
	local path = resolved[kind]
	if path == nil then
		path = false
		for _, p in ipairs(SOUNDS[kind]) do
			if file.Exists("sound/" .. p, "GAME") then path = p break end
		end
		resolved[kind] = path
	end
	if path then surface.PlaySound(path) end
end

surface.CreateFont("RemFCCam", {font = "Share Tech Mono", size = math.max(ScreenScale(7), 16), weight = 500, antialias = true})
surface.CreateFont("RemFCCamSmall", {font = "Share Tech Mono", size = math.max(ScreenScale(5.5), 13), weight = 500, antialias = true})

local function SetUp(up, silent)
	if CAM.LocalUp == up then return end
	CAM.LocalUp = up
	CAM.UpSince = CurTime()
	CAM.ZoomStep = 1
	CAM.Focus, CAM.FocusTime = nil, 0
	net.Start("rem_fccam")
	net.WriteBool(up)
	net.SendToServer()
	if not silent then Snd(up and "open" or "close") end
end

-- голова цели (у игрока - его текущее тело: сам или рэгдолл)
local function Body(ent)
	if ent:IsPlayer() and hg.GetCurrentCharacter then
		local c = hg.GetCurrentCharacter(ent)
		if IsValid(c) then return c end
	end
	return ent
end

local function HeadPos(ent)
	local body = Body(ent)
	local b = body:LookupBone("ValveBiped.Bip01_Head1")
	local m = b and body:GetBoneMatrix(b)
	if m then return m:GetTranslation(), body end
	return ent:EyePos(), body
end

local function Alive(ent)
	if not IsValid(ent) then return false end
	if ent:IsPlayer() then return ent:Alive() end
	return ent:Health() > 0
end

-- кого можно отметить: живые игроки и NPC / некстботы
local npcCache, npcCacheTime = {}, 0
local function Candidates(lply)
	if CurTime() > npcCacheTime then
		npcCacheTime = CurTime() + 0.5
		npcCache = {}
		for _, e in ipairs(ents.GetAll()) do
			if (e:IsNPC() or e:IsNextBot()) and e:Health() > 0 then npcCache[#npcCache + 1] = e end
		end
	end
	local list = {}
	for _, p in ipairs(player.GetAll()) do
		if p ~= lply and p:Alive() and not p:IsDormant() then list[#list + 1] = p end
	end
	for _, e in ipairs(npcCache) do
		if IsValid(e) and not e:IsDormant() then list[#list + 1] = e end
	end
	return list
end

local function AimedTarget(lply)
	local eye = lply:EyePos()
	local aim = lply:EyeAngles():Forward()
	local maxCos = math.cos(math.rad(math.max(AIM_DEG * CAM.ZoomMul * 1.8, 0.6)))
	local own = Body(lply)
	local best, bestDot
	for _, ent in ipairs(Candidates(lply)) do
		local head, body = HeadPos(ent)
		local d = head - eye
		local dist = d:Length()
		if dist > MAX_DIST or dist < 1 then continue end
		local dot = aim:Dot(d / dist)
		if dot < maxCos or (bestDot and dot <= bestDot) then continue end
		local tr = util.TraceLine({start = eye, endpos = head, filter = {lply, own}, mask = MASK_SHOT})
		if tr.Hit and tr.Fraction < 0.98 and tr.Entity ~= ent and tr.Entity ~= body then continue end
		best, bestDot = ent, dot
	end
	return best
end

local function SetTag(ent, on)
	if on then
		CAM.Tagged[ent] = CurTime()
		Snd("tag")
	else
		CAM.Tagged[ent] = nil
		Snd("untag")
	end
end

local wasX, wasLMB, wasRMB = false, false, false
local nextClean = 0
hook.Add("Think", "rem_fccam_cl", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	local free = not ply:IsTyping() and not gui.IsGameUIVisible() and not gui.IsConsoleVisible() and not IsValid(vgui.GetKeyboardFocus())
	local x = free and input.IsKeyDown(KEY_X)
	if x and not wasX then
		if CAM.LocalUp then SetUp(false) elseif CAM.Allowed(ply) then SetUp(true) end
	end
	wasX = x

	-- сервер опустил камеру (сменил оружие, упал, тейкдаун...) или сами уже не можем
	if CAM.LocalUp and (not CAM.Allowed(ply) or (CurTime() - (CAM.UpSince or 0) > 0.6 and not ply:GetNW2Bool("rem_fccam", false))) then
		SetUp(false)
	end

	local lmb = free and input.IsMouseDown(MOUSE_LEFT)
	local rmb = free and input.IsMouseDown(MOUSE_RIGHT)
	if CAM.LocalUp then
		local target = AimedTarget(ply)
		if target ~= CAM.Focus then CAM.Focus, CAM.FocusTime = target, 0 end
		if IsValid(target) and not CAM.Tagged[target] then
			CAM.FocusTime = CAM.FocusTime + FrameTime()
			if CAM.FocusTime >= FOCUS_TIME then SetTag(target, true) end
		end
		if lmb and not wasLMB and IsValid(target) then
			SetTag(target, not CAM.Tagged[target])
			CAM.FocusTime = -10 -- снятая отметка не ставится сама обратно, пока не отвёл камеру
		end
		if rmb and not wasRMB then
			CAM.ZoomStep = CAM.ZoomStep % #ZOOM + 1
			Snd(CAM.ZoomStep == #ZOOM and "zoom2" or "zoom1")
		end
	end
	wasLMB, wasRMB = lmb, rmb

	local want = CAM.LocalUp and ZOOM[CAM.ZoomStep] or 1
	CAM.ZoomMul = Lerp(math.min(FrameTime() * 14, 1), CAM.ZoomMul, want)
	if math.abs(CAM.ZoomMul - want) < 0.002 then CAM.ZoomMul = want end

	if CurTime() > nextClean then
		nextClean = CurTime() + 0.25
		for ent in pairs(CAM.Tagged) do
			if not Alive(ent) then CAM.Tagged[ent] = nil end
		end
	end
end)

-- зум (вызывается из CalcView в cl_camera.lua)
function CAM.FilterView(ply, view)
	if not istable(view) or CAM.ZoomMul >= 0.999 then return end
	view.fov = (view.fov or 90) * CAM.ZoomMul
	return view
end

hook.Add("AdjustMouseSensitivity", "rem_fccam_zoom", function()
	if CAM.ZoomMul < 0.999 then return CAM.ZoomMul end
end)

hook.Add("HUDShouldDraw", "rem_fccam_crosshair", function(name)
	if CAM.LocalUp and name == "CHudCrosshair" then return false end
end)

-- силуэты отмеченных сквозь стены
local silMat = CreateMaterial("rem_fccam_sil", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$model"] = 1,
	["$additive"] = 1,
	["$nocull"] = 1,
	["$ignorez"] = 1,
})
hook.Add("PostDrawTranslucentRenderables", "rem_fccam_sil", function(depth, sky)
	if depth or sky or not next(CAM.Tagged) then return end
	local pulse = 0.55 + math.sin(CurTime() * 4) * 0.1
	cam.IgnoreZ(true)
	render.SuppressEngineLighting(true)
	render.MaterialOverride(silMat)
	render.SetColorModulation(1 * pulse, 0.3 * pulse, 0.2 * pulse)
	for ent in pairs(CAM.Tagged) do
		if not Alive(ent) or ent:IsDormant() then continue end
		local body = Body(ent)
		if IsValid(body) then body:DrawModel() end
	end
	render.SetColorModulation(1, 1, 1)
	render.MaterialOverride()
	render.SuppressEngineLighting(false)
	cam.IgnoreZ(false)
end)

-- камера в руках у других (перед лицом)
local camModel
hook.Add("PostDrawOpaqueRenderables", "rem_fccam_prop", function(depth, sky)
	if depth or sky then return end
	local lply = LocalPlayer()
	for _, p in ipairs(player.GetAll()) do
		if not p:GetNW2Bool("rem_fccam", false) or p:IsDormant() or not p:Alive() then continue end
		if p == lply and GetViewEntity() == lply then continue end
		local body = Body(p)
		local att = body:GetAttachment(body:LookupAttachment("eyes"))
		if not att then continue end
		if not IsValid(camModel) then
			camModel = ClientsideModel("models/maxofs2d/camera.mdl", RENDERGROUP_OPAQUE)
			if not IsValid(camModel) then return end
			camModel:SetNoDraw(true)
		end
		local ang = p:EyeAngles()
		camModel:SetPos(att.Pos + ang:Forward() * 7 - ang:Up() * 1.5)
		camModel:SetAngles(ang)
		camModel:SetupBones()
		camModel:DrawModel()
	end
end)

-- видоискатель
local function Vignette(w, h)
	local steps, band = 18, math.ceil(math.min(w, h) * 0.018)
	for i = 0, steps - 1 do
		local a = math.floor(200 * (1 - i / steps) ^ 2)
		surface.SetDrawColor(0, 0, 0, a)
		local o = i * band
		surface.DrawRect(o, o, w - o * 2, band)
		surface.DrawRect(o, h - o - band, w - o * 2, band)
		surface.DrawRect(o, o + band, band, h - o * 2 - band * 2)
		surface.DrawRect(w - o - band, o + band, band, h - o * 2 - band * 2)
	end
end

local AF = { {0, -2}, {-2, -1}, {-1, -1}, {0, -1}, {1, -1}, {2, -1}, {-3, 0}, {-2, 0}, {-1, 0}, {1, 0}, {2, 0}, {3, 0},
	{-2, 1}, {-1, 1}, {0, 1}, {1, 1}, {2, 1}, {0, 2} }

local DIRS = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}

local function Ring(x, y, r, frac, col)
	surface.SetDrawColor(col)
	local seg = 32
	for i = 0, math.floor(seg * frac) - 1 do
		local a1, a2 = (i / seg) * math.pi * 2 - math.pi / 2, ((i + 1) / seg) * math.pi * 2 - math.pi / 2
		surface.DrawLine(x + math.cos(a1) * r, y + math.sin(a1) * r, x + math.cos(a2) * r, y + math.sin(a2) * r)
	end
end

local function DrawViewfinder(lply)
	local w, h = ScrW(), ScrH()
	local cx, cy = w / 2, h / 2
	Vignette(w, h)

	-- уголки
	local x1, x2, y1, y2 = w * 0.16, w * 0.84, h * 0.2, h * 0.8
	local len, t = w * 0.05, 2
	surface.SetDrawColor(LINE_COL)
	surface.DrawRect(x1, y1, len, t) surface.DrawRect(x1, y1, t, len * 0.8)
	surface.DrawRect(x2 - len, y1, len, t) surface.DrawRect(x2 - t, y1, t, len * 0.8)
	surface.DrawRect(x1, y2 - t, len, t) surface.DrawRect(x1, y2 - len * 0.8, t, len * 0.8)
	surface.DrawRect(x2 - len, y2 - t, len, t) surface.DrawRect(x2 - t, y2 - len * 0.8, t, len * 0.8)

	-- точки фокуса
	local sx, sy, s = w * 0.0625, h * 0.111, math.max(math.floor(h * 0.008), 4)
	surface.SetDrawColor(235, 235, 235, 90)
	for _, p in ipairs(AF) do
		surface.DrawOutlinedRect(cx + p[1] * sx - s, cy + p[2] * sy - s, s * 2, s * 2)
	end
	surface.SetDrawColor(LINE_COL)
	surface.DrawOutlinedRect(cx - s * 1.6, cy - s * 1.6, s * 3.2, s * 3.2)
	surface.DrawRect(cx - 1, cy - 1, 2, 2)

	-- текст: зум, курс, наклон, расстояние, запись
	local ang = EyeAngles()
	local yaw = (90 - ang.y) % 360
	local dir = DIRS[math.floor((yaw + 22.5) / 45) % 8 + 1]
	local tr = util.TraceLine({start = EyePos(), endpos = EyePos() + ang:Forward() * MAX_DIST, filter = {lply, Body(lply)}, mask = MASK_SHOT})
	local dist = tr.Hit and string.format("%.1fm", tr.HitPos:Distance(EyePos()) / 52.49) or "--.-m"
	local zoom = string.format("x%.1f", 1 / CAM.ZoomMul)
	local tags = 0
	for _ in pairs(CAM.Tagged) do tags = tags + 1 end

	draw.SimpleText(zoom, "RemFCCam", x1, y2 + h * 0.02, LINE_COL, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	draw.SimpleText(string.format("%s %03d°  %+03d°", dir, math.floor(yaw), math.floor(-ang.p)), "RemFCCam", cx, y2 + h * 0.02, LINE_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	draw.SimpleText(dist, "RemFCCam", x2, y2 + h * 0.02, LINE_COL, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	draw.SimpleText("TAGS " .. tags, "RemFCCamSmall", x1, y1 - h * 0.035, LINE_COL, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	if math.floor(CurTime() * 1.5) % 2 == 0 then
		surface.SetDrawColor(220, 30, 30, 230)
		local r = math.max(h * 0.006, 4)
		surface.DrawRect(x2 - h * 0.075, y1 - h * 0.03, r * 2, r * 2)
	end
	draw.SimpleText("REC", "RemFCCamSmall", x2, y1 - h * 0.035, LINE_COL, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)

	-- цель в фокусе: кольцо заполняется до отметки
	local f = CAM.Focus
	if IsValid(f) then
		local head = HeadPos(f)
		local sc = head:ToScreen()
		if sc.visible then
			local r = math.max(h * 0.03, 18)
			if CAM.Tagged[f] then
				surface.SetDrawColor(TAG_COL)
				surface.DrawOutlinedRect(sc.x - r, sc.y - r, r * 2, r * 2, 2)
			else
				Ring(sc.x, sc.y, r, math.Clamp(CAM.FocusTime / FOCUS_TIME, 0, 1), TAG_COL)
				surface.SetDrawColor(235, 235, 235, 120)
				surface.DrawOutlinedRect(sc.x - r, sc.y - r, r * 2, r * 2)
			end
		end
	end
end

-- метки над отмеченными (видны всегда)
local tri = {{}, {}, {}}
local function DrawTags(lply)
	local eye = EyePos()
	for ent in pairs(CAM.Tagged) do
		if not Alive(ent) or ent:IsDormant() then continue end
		local head = HeadPos(ent)
		local dist = head:Distance(eye)
		local sc = (head + Vector(0, 0, 10 + dist / 60)):ToScreen()
		if not sc.visible then continue end
		local s = math.Clamp(14 - dist / 400, 7, 14)
		tri[1].x, tri[1].y = sc.x - s, sc.y - s * 1.6
		tri[2].x, tri[2].y = sc.x + s, sc.y - s * 1.6
		tri[3].x, tri[3].y = sc.x, sc.y
		draw.NoTexture()
		surface.SetDrawColor(TAG_COL.r, TAG_COL.g, TAG_COL.b, 230)
		surface.DrawPoly(tri)
		draw.SimpleTextOutlined(string.format("%dm", math.Round(dist / 52.49)), "RemFCCamSmall", sc.x, sc.y - s * 1.7, TAG_COL, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 1, Color(0, 0, 0, 200))
	end
end

hook.Add("HUDPaint", "rem_fccam_hud", function()
	local lply = LocalPlayer()
	if not IsValid(lply) then return end
	if CAM.LocalUp then DrawViewfinder(lply) end
	if next(CAM.Tagged) then DrawTags(lply) end
end)
