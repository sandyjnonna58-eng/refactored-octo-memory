-- Оглушающее радио: то же радио (ent_calm_radio), но песни с диким басом на рандом рвут перепонки,
-- в ушах пищит, а у самого радио начинается лоботомия
ENT.Base = "ent_calm_radio"
ENT.Type = "anim"
ENT.PrintName = "Deafening Radio"
ENT.Instructions = "E - turn on / off. Alt+E - put a music URL. Stand close and your eardrums burst, your ears ring, and the bass starts a lobotomy."
ENT.Category = "ZCity Other"
ENT.Spawnable = true
ENT.IconOverride = "entities/ent_loud_radio.png"

-- звон в ушах в этом радиусе, лоботомия - ближе
ENT.CalmRange = 650
ENT.LobotomyRange = 300

-- басы ловим чаще, чем обычное радио думает
ENT.ClientThinkInterval = 0.03

ENT.Playlist = {
	{path = "sound/rem_loud_funkshenanigans.mp3", name = "FUNK SHENANIGANS", length = 85.1},
	{path = "sound/rem_loud_yatebyamognu.mp3", name = "YA TEBYA MOGNU", length = 81.4},
}
