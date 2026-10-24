include("shared.lua")

-- 0 - не слушать ссылки, которые ставят другие (тогда у себя играет музыка по умолчанию)
local allow_urls = CreateClientConVar("hg_radio_urls", "1", true, false, "Play music URLs that players put into radios", 0, 1)

local fade_near, fade_far = 150, 900
local label_distance = 300
local labelOffset = Vector(0, 0, 25)
local labelColor = Color(225, 225, 225)

local ACTION_URL, ACTION_DEFAULT, ACTION_NEXT = 0, 1, 2

-- что сейчас должно играть: ссылка или трек по умолчанию с моментом старта (для синхронизации)
local function WantedSource(self)
	if not self:GetOn() then return end

	local url = self:GetURL()
	if url ~= "" and allow_urls:GetBool() then return "url:" .. url, url end

	local track = self.Playlist[self:GetTrack()]
	if track then return "track:" .. self:GetTrack() .. ":" .. self:GetTrackStart(), nil, track end
end

local function Stop(self)
	if IsValid(self.radioStation) then self.radioStation:Stop() end
	self.radioStation = nil
	self.radioSource = nil
end

local function Start(self, source, url, track)
	self.radioSource = source
	self.radioLoading = source

	local function callback(station, errCode, errStr)
		if not IsValid(self) then
			if IsValid(station) then station:Stop() end
			return
		end
		-- пока грузилось, источник сменился
		if self.radioLoading ~= source or self.radioSource ~= source then
			if IsValid(station) then station:Stop() end
			return
		end
		self.radioLoading = nil

		if not IsValid(station) then
			if url and self.radioFailedURL ~= url then
				self.radioFailedURL = url
				chat.AddText(Color(255, 120, 120), "Radio: couldn't play this link (" .. tostring(errStr or errCode) .. ").")
			end
			return
		end

		self.radioStation = station
		station:SetPos(self:GetPos())
		station:Set3DFadeDistance(fade_near, fade_far)

		if track then
			-- все слышат одно и то же место трека
			local offset = CurTime() - self:GetTrackStart()
			if offset > 0 and offset < track.length then station:SetTime(offset) end
		end

		station:Play()
	end

	if url then
		sound.PlayURL(url, "3d noblock noplay", callback)
	else
		sound.PlayFile(track.path, "3d noblock noplay", callback)
	end
end

function ENT:Think()
	local source, url, track = WantedSource(self)

	if source ~= self.radioSource then
		Stop(self)
		if source then Start(self, source, url, track) end
	end

	local station = self.radioStation
	if IsValid(station) then
		station:SetPos(self:GetPos())
		station:SetVolume(GetConVar("snd_musicvolume"):GetFloat() * 0.8 + 0.2)
	end

	self:SetNextClientThink(CurTime() + 0.1)
	return true
end

function ENT:OnRemove()
	Stop(self)
end

function ENT:Draw()
	self:DrawModel()

	if not self:GetOn() or LocalPlayer():GetPos():DistToSqr(self:GetPos()) > label_distance * label_distance then return end

	local url = self:GetURL()
	local track = self.Playlist[self:GetTrack()]
	local text = (url ~= "" and allow_urls:GetBool()) and "radio - link" or ("radio - " .. (track and track.name or ""))

	cam.Start3D2D(self:GetPos() + labelOffset, Angle(0, LocalPlayer():EyeAngles().y - 90, 90), 0.08)
		draw.SimpleTextOutlined(text, "RemUI_Title", 0, 0, labelColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
	cam.End3D2D()
end

-- Alt+E: ссылка на музыку, музыка по умолчанию, следующий трек (стиль hg.RemUI)
local menu

local function Send(radio, action, url)
	net.Start("rem_radio_set")
		net.WriteEntity(radio)
		net.WriteUInt(action, 2)
		if action == ACTION_URL then net.WriteString(url) end
	net.SendToServer()
end

net.Receive("rem_radio_menu", function()
	local radio = net.ReadEntity()
	if not IsValid(radio) or not hg.RemUI then return end
	if IsValid(menu) then menu:Remove() end

	local UI = hg.RemUI
	local U = UI.U

	menu = UI.Frame(ScrW() * 0.36, U(300), "RADIO", "Direct link to an mp3 / ogg file or stream (not YouTube)")
	menu:SetKeyboardInputEnabled(true)

	local entry = vgui.Create("DTextEntry", menu)
	entry:Dock(TOP)
	entry:SetTall(U(34))
	entry:SetFont("RemUI_Small")
	entry:SetText(radio:GetURL())
	entry:SetPlaceholderText("https://...")
	entry.Paint = function(self, w, h)
		UI.PaintCard(w, h, UI.CardStrong)
		self:DrawTextEntryText(UI.Text, UI.Accent, UI.White)
	end
	entry:RequestFocus()

	local row = vgui.Create("DPanel", menu)
	row:Dock(TOP)
	row:DockMargin(0, U(10), 0, 0)
	row:SetTall(U(40))
	row.Paint = nil

	local function Play()
		if not IsValid(radio) then return end
		Send(radio, ACTION_URL, entry:GetValue())
		menu:Close()
	end
	entry.OnEnter = Play

	local play = UI.TextButton(row, "Play link", {font = "RemUI_Medium", color = UI.Accent, onClick = Play})
	play:Dock(LEFT)

	local default = UI.TextButton(row, "Default music", {onClick = function()
		if IsValid(radio) then Send(radio, ACTION_DEFAULT) end
		menu:Close()
	end})
	default:Dock(LEFT)
	default:DockMargin(U(20), 0, 0, 0)

	local nextTrack = UI.TextButton(row, "Next track", {onClick = function()
		if IsValid(radio) then Send(radio, ACTION_NEXT) end
		menu:Close()
	end})
	nextTrack:Dock(LEFT)
	nextTrack:DockMargin(U(20), 0, 0, 0)

	local hint = vgui.Create("DPanel", menu)
	hint:Dock(BOTTOM)
	hint:SetTall(U(22))
	hint.Paint = function(self, w, h)
		draw.SimpleText("Don't want other people's links? hg_radio_urls 0", "RemUI_Tiny", 0, h / 2, UI.TextDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
end)
