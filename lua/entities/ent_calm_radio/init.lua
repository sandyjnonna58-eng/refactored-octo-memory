AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

util.AddNetworkString("rem_radio_menu")
util.AddNetworkString("rem_radio_set")

resource.AddSingleFile("materials/entities/ent_calm_radio.png")
for _, track in ipairs(ENT.Playlist) do resource.AddSingleFile(track.path) end

-- 1 - ставить ссылку могут только админы
local url_admin_only = CreateConVar("hg_radio_url_admin_only", "0", FCVAR_ARCHIVE, "Only admins can put a music URL into the calming radio", 0, 1)

local tick_interval = 1
-- в секунду: паническая атака (0..1, активна с 0.45) и депрессия (0..1)
local panic_relief = 0.04
local depression_relief = 0.015
local notify_cooldown = 60
local use_distance = 150
local set_cooldown = 1

local ACTION_URL, ACTION_DEFAULT, ACTION_NEXT = 0, 1, 2

function ENT:Initialize()
	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)

	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end

	self:SetTrack(math.random(#self.Playlist))
end

function ENT:StartTrack(index)
	self:SetTrack((index - 1) % #self.Playlist + 1)
	self:SetTrackStart(CurTime())
end

function ENT:Use(activator)
	if not IsValid(activator) or not activator:IsPlayer() then return end

	-- Alt+E - меню со ссылкой
	if activator:KeyDown(IN_WALK) then
		net.Start("rem_radio_menu")
			net.WriteEntity(self)
		net.Send(activator)
		return
	end

	self:SetOn(not self:GetOn())
	if self:GetOn() then self:StartTrack(self:GetTrack()) end
	self:EmitSound("buttons/lightswitch2.wav", 60)
end

net.Receive("rem_radio_set", function(len, ply)
	local radio = net.ReadEntity()
	local action = net.ReadUInt(2)

	if not IsValid(radio) or radio:GetClass() ~= "ent_calm_radio" or not ply:Alive() then return end
	if ply:EyePos():Distance(radio:WorldSpaceCenter()) > use_distance then return end
	if (ply.radioSetNext or 0) > CurTime() then return end
	ply.radioSetNext = CurTime() + set_cooldown

	if action == ACTION_URL then
		local url = string.Trim(net.ReadString())
		if not radio.ValidURL(url) then
			ply:Notify("That doesn't look like a direct music link.", 0, "calm_radio_url", 3)
			return
		end
		if url_admin_only:GetBool() and not ply:IsAdmin() then
			ply:Notify("Only admins can put a link into the radio.", 0, "calm_radio_url", 3)
			return
		end

		radio:SetURL(url)
		radio:SetOn(true)
	elseif action == ACTION_DEFAULT then
		radio:SetURL("")
		radio:SetOn(true)
		radio:StartTrack(radio:GetTrack())
	elseif action == ACTION_NEXT then
		radio:SetURL("")
		radio:SetOn(true)
		radio:StartTrack(radio:GetTrack() + 1)
	end

	radio:EmitSound("buttons/lightswitch2.wav", 60)
end)

function ENT:Think()
	if self:GetOn() then
		-- музыка по умолчанию: трек закончился - следующий
		local track = self.Playlist[self:GetTrack()]
		if self:GetURL() == "" and track and CurTime() >= self:GetTrackStart() + track.length then
			self:StartTrack(self:GetTrack() + 1)
		end

		local center = self:WorldSpaceCenter()

		for _, ply in player.Iterator() do
			local org = ply.organism
			if ply:Alive() and org and ply:WorldSpaceCenter():Distance(center) <= self.CalmRange then
				-- panicattack тянется к panicattackadd, поэтому гасим оба
				org.panicattackadd = math.max((org.panicattackadd or 0) - panic_relief * tick_interval, 0)
				org.panicattack = math.max((org.panicattack or 0) - panic_relief * tick_interval, 0)
				org.depression = math.max((org.depression or 0) - depression_relief * tick_interval, 0)

				local troubled = (org.panicattack or 0) > 0.1 or (org.depression or 0) > 0.1
				if troubled and (ply.calmRadioNotify or 0) < CurTime() then
					ply.calmRadioNotify = CurTime() + notify_cooldown
					ply:Notify("The music slowly calms you down.", 0, "calm_radio", 3, nil, Color(180, 220, 255))
				end
			end
		end
	end

	self:NextThink(CurTime() + tick_interval)
	return true
end
