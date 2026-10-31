-- Клиент: звуки, которые сервер прислал уже в наших координатах (см. sv_world.lua).

net.Receive("zcinf_sound", function()
	local kind = net.ReadUInt(2)
	local snd = net.ReadString()
	local pos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
	local level = net.ReadUInt(9)
	local pitch = net.ReadUInt(8)
	local volume = net.ReadFloat()
	local dsp = net.ReadUInt(8)
	local channel = net.ReadInt(8)
	local flags = net.ReadUInt(10)

	if kind == 1 then
		sound.Play(snd, pos, level, pitch, volume, dsp)
	else
		EmitSound(snd, pos, 0, channel, volume, level, flags, pitch, dsp)
	end
end)

ZCInf.Mark("sounds")
