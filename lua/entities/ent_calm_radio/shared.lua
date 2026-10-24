ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "Calming Radio"
ENT.Instructions = "E - turn on / off. Alt+E - put a music URL / next track. While it plays, people nearby calm down: panic attacks fade, depression goes away."
ENT.Category = "ZCity Other"
ENT.Spawnable = true
ENT.Model = "models/props_lab/citizenradio.mdl"
ENT.IconOverride = "entities/ent_calm_radio.png"

-- в этом радиусе музыка успокаивает
ENT.CalmRange = 450

-- музыка по умолчанию: по кругу, у всех в одном месте трека (длина в секундах нужна серверу для переключения)
ENT.Playlist = {
	{path = "sound/rem_sexualdeviants.mp3", name = "Sexual Deviants", length = 270.1},
	{path = "sound/rem_newroundcommence.mp3", name = "New Round Commence", length = 98.9},
	{path = "sound/rem_appearencemenu.mp3", name = "Appearance Menu", length = 170.3},
}

-- ссылка: только прямой поток/файл (mp3, ogg...), а не страница вроде YouTube; до 400 символов
function ENT.ValidURL(url)
	return isstring(url) and #url <= 400 and string.match(url, "^https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+$") ~= nil
end

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "On")
	self:NetworkVar("String", 0, "URL")
	self:NetworkVar("Int", 0, "Track")
	self:NetworkVar("Float", 0, "TrackStart")
end
