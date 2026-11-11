-- Client: the developer's view of the respiratory system. The lungs, the airways and the diaphragm
-- drawn inside a body, breathing with it, and the state they are drawn from in words.
--
-- It is a developer's tool and behaves like one: it needs resp_dev 1 on the server and a superadmin
-- (or the listen server's host); its switches are not saved, so nothing is on after a restart; and
-- while it is on a line on the screen says so. With resp_view 0 this file draws nothing, asks the
-- server for nothing and keeps no entity; the breathing state and Z-City's chest work regardless.
-- Together with the skeleton view (skel_view 1) the lungs are seen in the rib cage: both are drawn
-- through the body into the same depth, so ribs hide lung and lung hides spine as they should.
--
--   resp_view 0 | 1 | 2          off | through the body | as part of the world (what shows has come through the surface)
--   resp_view_who aim|all|self   the body looked at (it stays until another is looked at) | every body near | one's own
--   resp_view_lungs 0..1         how solid the lungs are (less than 1: the airways show through them; 0: not drawn)
--   resp_view_airways 0|1        the windpipe and the bronchi
--   resp_view_diaphragm 0|1      the diaphragm
--   resp_view_hold -1 | 0..1     the diaphragm's travel set by hand instead of by the breathing clock
--                                (0 breathed out, 0.3 a quiet breath in, 1 the deepest): the shape at rest
--   resp_view_info 0|1           the state in words, and the shape of the breath
--   resp_check                   the module looked over, in the console

local RS = HemoRespiratory
RS.NoJIT()
RS.View = RS.View or {}
local V = RS.View
local C, CK, CL, RG, DR = RS.Config, RS.Clock, RS.CL, RS.Rig, RS.Draw
local SK = HemoSkeleton

local cvView = CreateClientConVar("resp_view", "0", false, false, "Respiratory: the lung view. 0 off, 1 through the body, 2 as part of the world (superadmin, resp_dev 1)", 0, 2)
local cvWho = CreateClientConVar("resp_view_who", "aim", false, false, "Lung view: aim (the body looked at), all (every body near), self")
local cvLungs = CreateClientConVar("resp_view_lungs", "1", false, false, "Lung view: how solid the lungs are, 0 (not drawn) .. 1", 0, 1)
local cvAirways = CreateClientConVar("resp_view_airways", "1", false, false, "Lung view: the windpipe and the bronchi", 0, 1)
local cvDiaphragm = CreateClientConVar("resp_view_diaphragm", "1", false, false, "Lung view: the diaphragm", 0, 1)
local cvHold = CreateClientConVar("resp_view_hold", "-1", false, false, "Lung view: the diaphragm's travel set by hand, 0 (out) .. 1 (the deepest breath); -1: the breathing clock", -1, 1)
local cvInfo = CreateClientConVar("resp_view_info", "1", false, false, "Lung view: the state in words", 0, 1)

V.targets = V.targets or {}

function V.Allowed()
	local me = LocalPlayer()
	return IsValid(me) and RS.DevAllowed(me) and not RS.Quiet
end
function V.On() return cvView:GetInt() > 0 and V.Allowed() end

------------------------------------------------------------------------------------------
-- Whom to show (the skeleton view's rule)
------------------------------------------------------------------------------------------
local function IsBody(e)
	return IsValid(e) and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) and not e:IsDormant()
end

-- (the scene can be drawn more than once a frame: what is looked at is asked of the main view)
local mainEye, mainAng, mainFrame = Vector(), Angle(), -1
hook.Add("RenderScene", "RS_View", function(origin, angles)
	if cvView:GetInt() == 0 then return end
	mainEye:Set(origin)
	mainAng:Set(angles)
	mainFrame = FrameNumber()
end)
local function Eye()
	if mainFrame == FrameNumber() then return mainEye, mainAng end
	return EyePos(), EyeAngles()
end

local sticky
local nextPick = 0
local function Pick()
	local me = LocalPlayer()
	local who = string.lower(cvWho:GetString())
	local eye, eyeAng = Eye()
	local VC = C.View
	local list = {}
	if who == "self" then
		list[1] = SK.BodyOf(me)
	elseif who == "all" then
		local seen = {}
		for _, e in ipairs(ents.GetAll()) do
			if IsBody(e) then
				local b = SK.BodyOf(e)
				if IsValid(b) and not seen[b] and (b ~= me or me:ShouldDrawLocalPlayer()) and not b:GetNoDraw() then
					seen[b] = true
					local d = b:WorldSpaceCenter():DistToSqr(eye)
					if d < VC.dist * VC.dist then list[#list + 1] = b b.RS_viewDist = d end
				end
			end
		end
		table.sort(list, function(a, b) return a.RS_viewDist < b.RS_viewDist end)
		for i = #list, VC.shown + 1, -1 do list[i] = nil end
	else
		local fwd = eyeAng:Forward()
		local tr = util.TraceLine({ start = eye, endpos = eye + fwd * VC.dist, filter = me, mask = MASK_SHOT })
		if IsBody(tr.Entity) then
			sticky = SK.BodyOf(tr.Entity)
		else
			-- (a body the trace does not stop at: the one whose middle lies nearest the line of sight)
			local best, bd
			for _, c in ipairs(ents.GetAll()) do
				if IsBody(c) and c ~= me then
					local b = SK.BodyOf(c)
					if IsValid(b) and not b:GetNoDraw() then
						local to = b:WorldSpaceCenter() - eye
						local along = to:Dot(fwd)
						if along > 0 and along < VC.dist then
							local off = (to - fwd * along):Length()
							if off < 26 and (not bd or along < bd) then best, bd = b, along end
						end
					end
				end
			end
			if best then sticky = best end
		end
		-- (a body that has become another entity: a player laid down as a ragdoll, or up again)
		if IsValid(sticky) and sticky:IsPlayer() then sticky = SK.BodyOf(sticky) end
		if IsValid(sticky) and sticky:IsRagdoll() and sticky:GetNoDraw() then
			local owner = CL.OwnerOf(sticky)
			if IsValid(owner) then sticky = SK.BodyOf(owner) end
		end
		if IsValid(sticky) and not sticky:IsDormant() then list[1] = sticky else sticky = nil end
	end
	-- the server is asked about those shown, and let go of the others
	local keep = {}
	for _, b in ipairs(list) do keep[b:EntIndex()] = true CL.Watch(b, true) end
	for ei in pairs(CL.watched) do
		if not keep[ei] then local e = Entity(ei) if IsValid(e) then CL.Watch(e, false) else CL.watched[ei] = nil end end
	end
	V.targets = list
end
V.Pick = Pick

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
local lastFrame = -1
local opts = {}
hook.Add("PostDrawTranslucentRenderables", "RS_View", function(depth, sky)
	if depth or sky or cvView:GetInt() == 0 then return end
	if not V.Allowed() then return end
	-- (a reflection in water is no place for a developer's view, and would cost a whole drawing of it)
	local rt = render.GetRenderTarget()
	if rt and string.find(string.lower(rt:GetName()), "reflection", 1, true) then return end
	local frame = FrameNumber()
	if frame ~= lastFrame then
		lastFrame = frame
		local now = RealTime()
		if now >= nextPick then nextPick = now + 0.1 Pick() end
	end
	if not RG.Ready() then return end
	local hold = cvHold:GetFloat()
	opts.xray = cvView:GetInt() == 1
	opts.hold = hold >= 0 and hold or nil
	opts.lungs = cvLungs:GetFloat()
	opts.airways = cvAirways:GetBool()
	opts.diaphragm = cvDiaphragm:GetBool()
	for _, body in ipairs(V.targets) do
		if IsValid(body) then DR.Body(body, opts) end
	end
end)

------------------------------------------------------------------------------------------
-- The words on the screen
------------------------------------------------------------------------------------------
surface.CreateFont("RS_View", { font = "Tahoma", size = 15, weight = 600, antialias = true })
surface.CreateFont("RS_ViewSmall", { font = "Tahoma", size = 13, weight = 500, antialias = true })

local function Text(s, font, x, y, col)
	draw.SimpleText(s, font, x + 1, y + 1, Color(0, 0, 0, 220))
	draw.SimpleText(s, font, x, y, col)
	return y + (font == "RS_View" and 17 or 15)
end

local LABEL_COL = { NORMAL = Color(150, 230, 160), FAST = Color(235, 225, 120), SHALLOW = Color(235, 225, 120), IRREGULAR = Color(255, 190, 110), LABOURED = Color(255, 170, 100),
	OBSTRUCTED = Color(255, 120, 90), AGONAL = Color(255, 90, 90), HELD = Color(150, 200, 255), NOT_BREATHING = Color(255, 70, 70) }

-- The shape of one breath of a clock, and where in it the clock stands.
local function Curve(c, x, y, w, h, now)
	surface.SetDrawColor(0, 0, 0, 150)
	surface.DrawRect(x, y, w, h)
	surface.SetDrawColor(255, 255, 255, 40)
	surface.DrawOutlinedRect(x, y, w, h)
	if c.mode ~= CK.BREATHING then
		local v = c.mode == CK.HELD and C.Breath.heldAt or 0
		surface.SetDrawColor(150, 200, 255, 220)
		surface.DrawLine(x + 2, y + h - 3 - v * (h - 6), x + w - 2, y + h - 3 - v * (h - 6))
		return
	end
	surface.SetDrawColor(240, 170, 180, 230)
	local px, py
	for i = 0, 48 do
		local p = i / 48
		local qx, qy = x + 2 + p * (w - 4), y + h - 3 - CK.Wave(p, c.rate, c.sym) * (h - 6)
		if px then surface.DrawLine(px, py, qx, qy) end
		px, py = qx, qy
	end
	local p = CK.PhaseAt(c, now)
	surface.SetDrawColor(255, 255, 255, 230)
	surface.DrawLine(x + 2 + p * (w - 4), y + 2, x + 2 + p * (w - 4), y + h - 2)
end

-- What there is to say of a body's breathing, as lines.
local ctl = {}
function V.Lines(body)
	local lines = {}
	local hold = cvHold:GetFloat()
	DR.Controls(body, hold >= 0 and hold or nil, ctl)
	local c, rec = ctl.clock, ctl.rec
	local name = string.match(body:GetModel() or "?", "([^/]+)%.mdl$") or "?"
	if c then
		local a, b = CK.Shares(c.rate)
		lines[#lines + 1] = string.format("%s  %s | %s, %.1f breaths a minute, depth %.2f%s | in %.0f%% out %.0f%% pause %.0f%% | heard %.1f s ago", tostring(body), name, CK.ModeName[c.mode] or "?", c.rate, c.depth,
			c.sym and " (even: the brain module moves this chest)" or "", a * 100, b * 100, (1 - a - b) * 100, RealTime() - c.got)
	else
		lines[#lines + 1] = string.format("%s  %s | no breathing clock: %s", tostring(body), name, CL.OwnerOf(body) and "none heard from the server yet" or "not the body of a living character")
	end
	lines[#lines + 1] = string.format("  breath: left %.2f right %.2f | diaphragm: left %.2f right %.2f of its travel (%s) | in place: left %.2f right %.2f", ctl.vl, ctl.vr, ctl.dl, ctl.dr,
		ctl.src == "hand" and "set by hand" or (ctl.src == "clock" and "from the clock" or "at rest"), ctl.fl, ctl.fr)
	if rec then
		lines[#lines + 1] = string.format("  %s | airway open %.2f%s, windpipe damage %.2f | left: damage %.2f puncture %.2f let go %.2f can do %.2f | right: %.2f %.2f %.2f %.2f", rec.label, rec.patency,
			rec.blocked and (" BLOCKED (" .. tostring(rec.why) .. ")") or "", rec.trachea, rec.damageL, rec.breachL, rec.collapseL, rec.shareL, rec.damageR, rec.breachR, rec.collapseR, rec.shareR)
		lines[#lines + 1] = string.format("  air in the pleural space %.2f (needle %.2f) | lungs could load the blood %.2f | oxygen %.2f of %.2f | wants %.0f%% more air: going to %.1f a minute, depth %.2f | brain: %s%s | %d asked change(s)",
			rec.pneumothorax, rec.needle, rec.exchange, rec.oxygen, rec.ceiling, rec.want * 100, rec.targetRate, rec.targetDepth, rec.control and string.format("drives %.2f, pattern %d", rec.control, rec.pattern) or "no record",
			rec.brain and ", moves this chest" or "", rec.mods)
	else
		lines[#lines + 1] = "  no record of its lungs from the server (yet)"
	end
	return lines, c, rec
end

hook.Add("HUDPaint", "RS_View", function()
	if cvView:GetInt() == 0 then return end
	local x, y = 24, math.floor(ScrH() * 0.42)
	if RS.Quiet then return end
	if not V.Allowed() then
		Text("lung view: needs resp_dev 1 on the server and a superadmin", "RS_View", x, y, Color(255, 180, 120))
		return
	end
	y = Text(string.format("LUNG VIEW (developer)  %s  |  resp_view 0 to leave", cvView:GetInt() == 1 and "through the body" or "as part of the world"), "RS_View", x, y, Color(240, 200, 205))
	local small = Color(210, 210, 210)
	if RG.state == "failed" then
		Text("the models: " .. RG.note, "RS_ViewSmall", x, y, Color(255, 160, 120))
		return
	end
	if #V.targets == 0 then y = Text("no body shown: look at one (resp_view_who aim), or resp_view_who all / self", "RS_ViewSmall", x, y, small) end
	if cvInfo:GetBool() then
		local now = CurTime()
		for i, body in ipairs(V.targets) do
			if i > 3 then break end
			if IsValid(body) then
				local lines, c, rec = V.Lines(body)
				for k, l in ipairs(lines) do
					y = Text(l, "RS_ViewSmall", x, y, (k == 3 and rec and LABEL_COL[rec.label]) or small)
				end
				if c then
					Curve(c, x + 12, y + 2, 220, 46, now)
					y = y + 52
				end
			end
		end
	end
	local s = DR.stats.last
	Text(string.format("%d bod%s shown; the frame before: drawn %d time(s), %d model(s), %.2f ms; %d clock(s) known", #V.targets, #V.targets == 1 and "y" or "ies", s.bodies, s.models, s.ms, table.Count(CL.clocks)),
		"RS_ViewSmall", x, y, Color(160, 160, 160))
end)

cvars.AddChangeCallback("resp_view", function(_, _, new)
	if tonumber(new) == 0 then
		CL.Forget()
		RG.Release()
		V.targets, sticky = {}, nil
	end
end, "RS_View")

------------------------------------------------------------------------------------------
-- In words, in the console
------------------------------------------------------------------------------------------
local function Out(s) MsgC(Color(225, 150, 160), "[Respiratory] ", color_white, s, "\n") end

concommand.Add("resp_check", function()
	local bad = RS.CheckStructures()
	Out(string.format("version %s; structures: %d, sum %d: %s", RS.VERSION, #RS.StructList, RS.STRUCT_SUM, #bad == 0 and "whole" or (#bad .. " complaint(s)")))
	for _, s in ipairs(bad) do Out("  " .. s) end
	local D = RS.RigData
	if D then
		local n, tris = 0, 0
		for _, def in ipairs(D.models) do n = n + #def.bones tris = tris + def.triangles end
		Out(string.format("models: %d, %d bones, %d triangles, made %s; entities: %s%s", #D.models, n, tris, tostring(D.made), RG.state, RG.note ~= "" and (": " .. RG.note) or " (made when the view first needs them)"))
		for _, def in ipairs(D.models) do Out(string.format("  %s: %d bones, %d triangles, file %s", def.path, #def.bones, def.triangles, file.Exists(def.path, "GAME") and "there" or "NOT THERE")) end
	else
		Out("models: no table of bones (cl_rigdata.lua): tools/offline/lunggen.ps1 -Emit makes it")
	end
	Out(string.format("clocks known: %d (%d message(s) heard); records: %d; Z-City's chest follows the clock: %s (%d time(s) set)", table.Count(CL.clocks), CL.stats.clocks, table.Count(CL.recs),
		(C.sv.chest:GetBool() and C.sv.enabled:GetBool() and not RS.Quiet) and "yes" or "no", RS.Chest.stats.set))
end, nil, "Respiratory: the module looked over")
