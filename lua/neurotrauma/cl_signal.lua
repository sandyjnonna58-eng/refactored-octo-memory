-- Client: the developer's live trace of a signal. brain_show_signal [target] (superadmin,
-- neuro_dev 1) shows, for what the watched character is doing right now, the way from the key to
-- the limb: the intention, every stage of the channel (cortex, the descending fibres, the spinal
-- cord) with what it still carries, the signal that is left, what arrives at the limb, and what
-- the game makes of it. The numbers are the server's (the stream of cl_brainview.lua, sixteenths);
-- this file only draws them. It is a picture of the model's own arithmetic, not of neurons.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
local A, C = NT.Atlas, NT.Config

surface.CreateFont("NT_Signal", { font = "Consolas", size = 14, weight = 700, antialias = true })
surface.CreateFont("NT_SignalSmall", { font = "Consolas", size = 13, weight = 500, antialias = true })

local index = {}
local function Index(dom)
	local t = index[dom]
	if t then return t end
	t = {}
	for i, c in ipairs(A.compiled[dom]) do t[c.key] = i end
	index[dom] = t
	return t
end

local function Colour(v)
	return 230 * (1 - v) + 40, 200 * v + 30, 60
end

local WHITE, DIM, HEAD = Color(235, 235, 240), Color(150, 150, 160), Color(150, 195, 255)
local height = 60         -- of what was drawn last: the size of the panel behind it

-- one stage of a chain: a box with its name and what it carries; returns where the next begins
local function Box(x, y, name, v, maxX, x0)
	local text = string.format("%s %d%%", name, math.floor(v * 100 + 0.5))
	surface.SetFont("NT_SignalSmall")
	local w = surface.GetTextSize(text) + 12
	if x + w > maxX then x, y = x0, y + 22 end
	local r, g, b = Colour(v)
	surface.SetDrawColor(r * 0.35, g * 0.35, b * 0.35, 235)
	surface.DrawRect(x, y, w, 18)
	surface.SetDrawColor(r, g, b, 255)
	surface.DrawOutlinedRect(x, y, w, 18)
	draw.SimpleText(text, "NT_SignalSmall", x + 6, y + 2, WHITE)
	return x + w, y
end

local function Arrow(x, y, text)
	draw.SimpleText(text or ">", "NT_SignalSmall", x + 4, y + 2, DIM)
	surface.SetFont("NT_SignalSmall")
	return x + surface.GetTextSize(text or ">") + 8
end

hook.Add("HUDPaint", "NT_Signal", function()
	local BV = NT.BrainView
	if not BV or BV.Mode() ~= "signal" then return end
	local d = BV.Data()
	local sw, sh = ScrW(), ScrH()
	local x0, y = 24, math.floor(sh * 0.30)
	local maxX = math.min(sw - 24, 1500)
	surface.SetDrawColor(8, 9, 12, 225)
	local top = y
	surface.DrawRect(x0 - 10, y - 10, maxX - x0 + 20, height)
	draw.SimpleText("signal: " .. (d and d.name or "waiting for the server (neuro_dev 1, superadmin)"), "NT_Signal", x0, y, HEAD)
	y = y + 22
	if not d or CurTime() - d.t > 3 then return end
	local dom = d.has and d.dom or "L"
	local comp, idx = A.compiled[dom], Index(dom)
	local awake = d.has and d.awake or 1
	local intent = awake >= 0.4 and 1 or awake / 0.4
	if not d.has then
		draw.SimpleText("no neurological record (uninjured): every stage carries all of it", "NT_SignalSmall", x0, y, DIM)
		y = y + 18
	end
	local any = false
	for i, a in ipairs(A.actions) do
		if bit.band(d.actions or 0, bit.lshift(1, i - 1)) ~= 0 then
			any = true
			draw.SimpleText(string.format("%s   %s", a.keys, string.upper(a.name)), "NT_Signal", x0, y, Color(255, 230, 90))
			y = y + 20
			for _, ck in ipairs(a.out) do
				local ci = idx[ck]
				local c = ci and comp[ci]
				if c then
					draw.SimpleText(A.channelNames[ck] or ck, "NT_SignalSmall", x0 + 8, y + 2, WHITE)
					local rowX = x0 + 150
					local x = rowX
					x, y = Box(x, y, "intention", intent, maxX, rowX)
					local signal = intent
					for s, stg in ipairs(c.stages) do
						x = Arrow(x, y)
						local cap = d.has and d.stg and d.stg[ci] and d.stg[ci][s] or 1
						signal = signal * cap
						x, y = Box(x, y, stg.name, cap, maxX, rowX)
					end
					x = Arrow(x, y, "=")
					local out = d.has and d.out and d.out[ck]
					x, y = Box(x, y, out and "arrives" or "signal", out or signal, maxX, rowX)
					y = y + 24
				end
			end
			-- what the game makes of it
			local o = d.has and d.out or nil
			if a.key == "walk" or a.key == "run" or a.key == "jump" then
				local run, jump = true, true
				local speed = 1
				if o then
					run, jump = NT.Control(o.legL, o.legR, o.handL, o.handR, o.balance, 0)
					speed = C.Motor.moveFloor + (1 - C.Motor.moveFloor) * (d.moveQ or 15) / 15
				end
				draw.SimpleText(string.format("=> movement: walking at %d%% of normal speed | may run: %s | may jump: %s", math.floor(speed * 100 + 0.5), run and "yes" or "no", jump and "yes" or "no"),
					"NT_SignalSmall", x0 + 8, y, HEAD)
				y = y + 22
			elseif a.key == "attack" or a.key == "aim" then
				local fire, aim = true, true
				if o then
					local _
					_, _, fire, aim = NT.Control(o.legL, o.legR, o.handL, o.handR, o.balance, 0)
				end
				draw.SimpleText(string.format("=> may pull the trigger: %s | may aim a long weapon: %s", fire and "yes" or "no", aim and "yes" or "no"), "NT_SignalSmall", x0 + 8, y, HEAD)
				y = y + 22
			end
			y = y + 6
		end
	end
	if not any then
		draw.SimpleText("no input: nothing is asked of the body (walk, run, jump, fire, aim, use, type, speak)", "NT_SignalSmall", x0, y, DIM)
		y = y + 20
		if d.has and d.out then
			local o = d.out
			draw.SimpleText(string.format("what would arrive: legs L %d%% R %d%% | arms L %d%% R %d%% | hands L %d%% R %d%% | trunk %d%% | balance %d%%",
				o.legL * 100, o.legR * 100, o.armL * 100, o.armR * 100, o.handL * 100, o.handR * 100, o.trunk * 100, o.balance * 100), "NT_SignalSmall", x0, y, WHITE)
			y = y + 20
		end
	end
	height = y - top + 16
end)
