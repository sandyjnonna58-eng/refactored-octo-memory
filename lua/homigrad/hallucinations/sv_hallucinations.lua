-- Галлюцинации в темноте - всё видит и слышит только сам игрок (cl_hallucinations.lua).
-- Сервер только раздаёт шейдеры и даёт админу команду для проверки.
util.AddNetworkString("rem_hallucinate")

for _, name in ipairs({"fisheye", "videoglitch"}) do
	resource.AddSingleFile("materials/effects/shaders/merc_" .. name .. ".vmt")
	resource.AddSingleFile("shaders/fxc/merc_" .. name .. "_ps20b.vcs")
end

-- !hallucinate [секунды] [ник] - галлюцинации на полную, где бы человек ни стоял
COMMANDS = COMMANDS or {}
COMMANDS.hallucinate = {function(ply, args)
	local seconds = math.Clamp(tonumber(args[1]) or 60, 1, 600)
	local target = ply

	if args[2] then
		target = nil
		for _, other in player.Iterator() do
			if string.find(string.lower(other:Nick()), string.lower(args[2]), 1, true) then target = other break end
		end
	end

	if not IsValid(target) then ply:ChatPrint("Player not found.") return end

	net.Start("rem_hallucinate")
		net.WriteFloat(seconds)
	net.Send(target)
	ply:ChatPrint("Hallucinations for " .. target:Nick() .. ": " .. seconds .. "s")
end, 1, "seconds; player"}
