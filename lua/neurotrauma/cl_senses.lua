-- Client: what the local player's own brain no longer takes in. The server sends the owner a small
-- block of losses (sv_net.lua, nt_self); nobody else is told.
--
--   sight       a lesion behind the crossing of the optic nerves takes the same part of the field
--               from both eyes: a half, or a quarter [S: N38 N17]. Shown as that part of the
--               picture gone dark, with a soft border at the middle. (The eye cannot be tracked:
--               the field is fixed to the screen, as if the player always looked at its centre.)
--   neglect     the opposite half of space is not attended to [S: N15]: that side of the picture
--               is dimmed; it is still there for the player who turns to it
--   hearing     Z-City fades all sound for ringing ears and asks a hook how much more to fade: the
--               loss is added there. One fade for everything is all the engine offers: no
--               difference between the ears, no change of what is heard.
--   reading     words of incoming chat turn into strings of letters when understanding or reading
--               is lost (the same function the server uses for what a character writes). This is
--               the one place where a deficit is applied on the owner's own machine: the server
--               sends every listener the same text, and giving one of them another would mean
--               replacing Z-City's delivery. A modified client could read normally.
--   memory      who said it is no longer known: names in chat become "someone" [G]
--   attention   a share of what is said goes by unnoticed [G]

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
local CL = NT.CL
local X = NT.Text
local C = NT.Config
local CS = C.Senses
local Clamp, max = math.Clamp, math.max

------------------------------------------------------------------------------------------
-- Sight
------------------------------------------------------------------------------------------
local STRIPS = 14

-- One quarter of the field: left or right of the middle, above or below it. w: how much is lost;
-- other: how much the quarter above or below it on the same side has lost (where both are gone
-- there is no border between them).
local function Quarter(left, upper, w, other, sw, sh)
	if w <= 0.02 then return end
	local a = CS.fieldAlpha * w
	local edge = sw * CS.fieldEdge
	local edgeY = (w - other > 0.3) and sh * CS.fieldEdge or 0
	local x0 = left and 0 or sw * 0.5 + edge
	local x1 = left and sw * 0.5 - edge or sw
	local y0 = upper and 0 or sh * 0.5 + edgeY
	local hh = sh * 0.5 - edgeY
	-- (twice: one pass leaves the picture showing through after the game's own tone mapping)
	for _ = 1, 2 do
		surface.SetDrawColor(6, 6, 7, a)
		surface.DrawRect(x0, y0, x1 - x0, hh)
	end
	-- the border at the vertical middle: strips that thin out toward it
	for i = 0, STRIPS - 1 do
		local f = (i + 0.5) / STRIPS
		surface.SetDrawColor(6, 6, 7, a * (1 - f))
		local sx = left and (sw * 0.5 - edge + edge * i / STRIPS) or (sw * 0.5 + edge - edge * (i + 1) / STRIPS)
		surface.DrawRect(sx, y0, edge / STRIPS + 1, hh)
		surface.DrawRect(sx, y0, edge / STRIPS + 1, hh)
	end
	-- and at the horizontal middle, when only this quarter is gone
	if edgeY > 0 then
		for i = 0, STRIPS - 1 do
			local f = (i + 0.5) / STRIPS
			surface.SetDrawColor(6, 6, 7, a * (1 - f))
			local sy = upper and (sh * 0.5 - edgeY + edgeY * i / STRIPS) or (sh * 0.5 + edgeY - edgeY * (i + 1) / STRIPS)
			surface.DrawRect(left and 0 or sw * 0.5 + edge, sy, sw * 0.5 - edge, edgeY / STRIPS + 1)
			surface.DrawRect(left and 0 or sw * 0.5 + edge, sy, sw * 0.5 - edge, edgeY / STRIPS + 1)
		end
	end
end

local function DrawFields()
	local s = CL.self
	if not s then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local nl, nr = s.neglectL * CS.neglectDim, s.neglectR * CS.neglectDim
	local ul, ll, ur, lr = max(s.visUL, nl), max(s.visLL, nl), max(s.visUR, nr), max(s.visLR, nr)
	if ul + ll + ur + lr <= 0.05 then return end
	local sw, sh = ScrW(), ScrH()
	cam.Start2D()
	Quarter(true, true, ul, ll, sw, sh)
	Quarter(true, false, ll, ul, sw, sh)
	Quarter(false, true, ur, lr, sw, sh)
	Quarter(false, false, lr, ur, sw, sh)
	cam.End2D()
end

-- after Z-City's own screen effects (its last sub-hook), or as a plain screen effect without it
hook.Add("Post Post Pre Post Processing", "NT_Field", DrawFields)
hook.Add("RenderScreenspaceEffects", "NT_Field", function()
	if istable(hg) and istable(hg.postprocess) then return end
	DrawFields()
end)

------------------------------------------------------------------------------------------
-- Hearing
------------------------------------------------------------------------------------------
hook.Add("ModifyTinnitusFactor", "NT_Hearing", function()
	local s = CL.self
	if not s or s.hearing <= 0.05 then return end
	return s.hearing * CS.hearingFade
end)

------------------------------------------------------------------------------------------
-- Reading, memory, attention: incoming chat
------------------------------------------------------------------------------------------
CL.misread = 0
hook.Add("HG_OnPlayerChat", "NT_Reading", function(ply, text, bTeam, bDead, plyColor, plyName, bWhisper)
	local s = CL.self
	if not s or not istable(text) or not isstring(text[1]) then return end
	if ply == LocalPlayer() then return end
	local first = string.sub(text[1], 1, 1)
	if first == "!" or first == "/" then return end
	-- unnoticed
	if s.attention > 0.3 and math.random() < (s.attention - 0.3) * CS.missShare then
		CL.misread = CL.misread + 1
		return true
	end
	local loss = max(s.comprehension, s.reading)
	if loss > 0.1 then
		text[1] = X.Misread(text[1], loss, NT.RNG(X.Hash(text[1]) + math.floor(CurTime())))
		CL.misread = CL.misread + 1
	end
	if s.memory >= 0.6 then
		chat.AddText(plyColor or color_white, "someone", color_white, ": " .. text[1])
		return true
	end
end)
