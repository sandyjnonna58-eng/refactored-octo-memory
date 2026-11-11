-- Client: the developer panel. neuro_debug 1 asks the server for the neurological record of the
-- character under the crosshair (or one's own); the server answers only superadmins while
-- neuro_dev is on (sv_debug.lua). Shows the last injury events with their kinematics, the injury
-- and function variables, the state and its overlays, and the last transitions with their reasons.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma

local cv = CreateClientConVar("neuro_debug", "0", false, false, "NeuroTrauma developer panel (superadmin, neuro_dev 1)", 0, 1)
local lines, got = {}, 0

local function Ask(on)
	net.Start("nt_debug")
	net.WriteBool(on)
	net.SendToServer()
end

cvars.AddChangeCallback("neuro_debug", function(_, _, new) Ask(tonumber(new) == 1) end, "nt_debug")
hook.Add("InitPostEntity", "NT_DebugAsk", function() if cv:GetBool() then Ask(true) end end)

net.Receive("nt_debug", function()
	local n = net.ReadUInt(6)
	lines = {}
	for i = 1, n do lines[i] = net.ReadString() end
	got = CurTime()
end)

surface.CreateFont("NT_Debug", { font = "Consolas", size = 15, weight = 500, antialias = true })

-- long lines are broken at the bars the server writes between groups of values
local function Wrap(s, max)
	local out = {}
	while #s > max do
		local cut = max
		for i = max, math.floor(max * 0.5), -1 do
			if string.sub(s, i, i) == "|" then cut = i break end
		end
		out[#out + 1] = string.sub(s, 1, cut)
		s = "      " .. string.sub(s, cut + 1)
	end
	out[#out + 1] = s
	return out
end

hook.Add("HUDPaint", "NT_Debug", function()
	if not cv:GetBool() then return end
	local x, y = 24, 120
	local shown = {}
	if CurTime() - got > 3 then
		shown[1] = "NeuroTrauma: no answer (needs neuro_dev 1 and superadmin)"
	else
		for _, l in ipairs(lines) do
			for _, w in ipairs(Wrap(l, 168)) do shown[#shown + 1] = w end
		end
	end
	surface.SetDrawColor(0, 0, 0, 170)
	surface.DrawRect(x - 8, y - 8, 1380, #shown * 17 + 16)
	for i, l in ipairs(shown) do
		-- (a line in capitals is the name of a section)
		local head = i == 1 or (string.match(l, "^[A-Z]+$") ~= nil)
		draw.SimpleText(l, "NT_Debug", x, y + (i - 1) * 17, head and Color(140, 190, 255) or color_white)
	end
end)
