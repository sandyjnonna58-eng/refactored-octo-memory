-- Client: the developer's fitting view of a head. For looking at how skull, lower jaw and brain lie
-- in a body's head, and for fitting a head by hand: the numbers of sh_headfit.lua are changed from
-- the console and seen at once, and the line to keep is printed.
--
-- A developer's tool, as the inspection view is (cl_view.lua): it needs skel_dev 1 on the server and
-- a superadmin (or the listen server's host); none of its switches is saved, so nothing of it is on
-- after a restart; while it is on, lines on the screen say so. With skel_head 0 this file draws
-- nothing, moves no camera and leaves every body as it is drawn.
--
--   skel_head 0|1                  the view
--   skel_head_who aim|self         the body looked at (it stays until another is looked at) | one's own
--   skel_head_show both|cut|skull|brain
--                                  the skull as glass round the brain | its left half cut away | alone | the brain alone
--   skel_head_body 1|2|0           the body's own model: as it is | faint | not drawn
--   skel_head_marks 0|1            the landmarks the fit was made by: the skull's against the head's
--   skel_head_neck 0|1             the vertebrae of the neck with the skull
--   skel_head_cam off|side|front|back|top|quarter
--                                  a camera that stands by the head: from its left, its front, its back, above it, three quarters
--   skel_head_set <what> <value>   a number of this model's head, tried out: skull.tilt skull.pitch skull.side
--                                  skull.along skull.high skull.fwd skull.up jaw.long jaw.high jaw.broad
--                                  brain.k brain.f brain.u brain.pitch
--   skel_head_nudge <what> <by>    the same, by so much
--   skel_head_print                this model's numbers as a line for HF.Adjust (sh_headfit.lua)
--   skel_head_reset                what was tried out is dropped
-- What is tried out is tried out on this client only: the server keeps the numbers of the files
-- until the printed line is put into HF.Adjust.

local SK = HemoSkeleton
SK.NoJIT()
SK.HeadView = SK.HeadView or {}
local HV = SK.HeadView
local V, G, D, P, M, HF, C = SK.View, SK.Geo, SK.Draw, SK.Pose, SK.M, SK.HeadFit, SK.Config

local cvOn = CreateClientConVar("skel_head", "0", false, false, "Skeleton: the fitting view of a head, skull and brain (superadmin, skel_dev 1)", 0, 1)
local cvWho = CreateClientConVar("skel_head_who", "aim", false, false, "Head view: aim (the body looked at) or self")
local cvShow = CreateClientConVar("skel_head_show", "both", false, false, "Head view: both (the skull as glass round the brain), cut (its left half cut away), skull, brain")
local cvBody = CreateClientConVar("skel_head_body", "1", false, false, "Head view: the body's own model. 1 as it is, 2 faint, 0 not drawn", 0, 2)
local cvMarks = CreateClientConVar("skel_head_marks", "1", false, false, "Head view: the landmarks the fit was made by", 0, 1)
local cvNeck = CreateClientConVar("skel_head_neck", "1", false, false, "Head view: the vertebrae of the neck with the skull", 0, 1)
local cvCam = CreateClientConVar("skel_head_cam", "off", false, false, "Head view: a camera by the head. off, side, front, back, top, quarter")

HV.target = nil
HV.marks = {}

local function On() return cvOn:GetBool() and V.Allowed() end

------------------------------------------------------------------------------------------
-- Whose head
------------------------------------------------------------------------------------------
local function IsBody(e)
	return IsValid(e) and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) and not e:IsDormant()
end

local nextPick = 0
local function Pick()
	local me = LocalPlayer()
	local t = HV.target
	-- (a body it has been handed, by a test scene: kept while it is there)
	if HV.pinned and IsValid(t) and not t:IsDormant() then return end
	if string.lower(cvWho:GetString()) == "self" then
		t = SK.BodyOf(me)
	else
		-- (the player's own eye, not the drawing's: the scene is drawn from other eyes as well)
		local eye, fwd = me:EyePos(), me:EyeAngles():Forward()
		local tr = util.TraceLine({ start = eye, endpos = eye + fwd * C.View.dist, filter = me, mask = MASK_SHOT })
		if IsBody(tr.Entity) then
			t = SK.BodyOf(tr.Entity)
		elseif not IsValid(t) then
			-- (a body the trace does not stop at: the one whose middle lies nearest the line of sight)
			local bd
			for _, c in ipairs(ents.GetAll()) do
				if IsBody(c) and c ~= me then
					local b = SK.BodyOf(c)
					if IsValid(b) and not b:GetNoDraw() then
						local to = b:WorldSpaceCenter() - eye
						local along = to:Dot(fwd)
						if along > 0 and along < C.View.dist and (to - fwd * along):Length() < 26 and (not bd or along < bd) then t, bd = b, along end
					end
				end
			end
		end
	end
	if IsValid(t) and t:IsPlayer() then t = SK.BodyOf(t) end
	if not IsValid(t) or t:IsDormant() then t = nil end
	HV.target = t
end

------------------------------------------------------------------------------------------
-- The body's own model: as it is, faint, or not drawn. Its bones are worked out all the same:
-- skull and brain go by them.
------------------------------------------------------------------------------------------
local held = {}        -- body -> what its RenderOverride was (false: none)
local function Release(ent)
	if held[ent] == nil then return end
	if IsValid(ent) then ent.RenderOverride = held[ent] or nil end
	held[ent] = nil
end
local function ReleaseAll()
	for ent in pairs(held) do Release(ent) end
end
local function Hold(ent, mode)
	if held[ent] == nil then held[ent] = ent.RenderOverride or false end
	if ent.SK_headMode == mode and ent.RenderOverride == ent.SK_headOverride then return end
	local fn = function(self, flags)
		self:SetupBones()
		if mode == 2 then
			render.SetBlend(0.25)
			self:DrawModel(flags)
			render.SetBlend(1)
		end
	end
	ent.RenderOverride, ent.SK_headOverride, ent.SK_headMode = fn, fn, mode
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
local SKULL_COL, HEAD_COL, LINE_COL = Color(255, 215, 70), Color(90, 230, 255), Color(255, 255, 255, 160)

local function OnlyHead(u)
	local key = u.carry and u.carry[1] and u.carry[1][1]
	return key == "head" or key == "jaw" or (key == "neck" and cvNeck:GetBool())
end
local function InsideTint() return 0.72, 0.6, 0.56 end

-- The head frame of a body now: the place 4.2 up and 0.8 toward the face from its head bone, and the
-- directions left, face, up (the brain module's frame; sh_headfit.lua works in it).
function HV.Frame(body)
	local pose = SK.PoseOf(body)
	local idx = pose and pose.prof.bone.head
	local vm = idx and body:GetBoneMatrix(idx)
	if not vm then return nil end
	local p = HF.For(pose.prof.model)
	local r = M.FromMatrix(vm)
	local up, face, left = Vector(r[1], r[5], r[9]), Vector(-r[2], -r[6], -r[10]), Vector(r[3], r[7], r[11]) * p.lsign
	local st = SK.Stock.head
	return Vector(r[4], r[8], r[12]) + up * st.up + face * st.face, left, face, up, p
end

local function Cross(p, size, col)
	render.DrawLine(p - Vector(size, 0, 0), p + Vector(size, 0, 0), col, false)
	render.DrawLine(p - Vector(0, size, 0), p + Vector(0, size, 0), col, false)
	render.DrawLine(p - Vector(0, 0, size), p + Vector(0, 0, size), col, false)
end

local lastFrame = -1
hook.Add("PostDrawTranslucentRenderables", "SK_HeadView", function(depth, sky)
	if depth or sky or not cvOn:GetBool() then return end
	if not V.Allowed() then return end
	local rt = render.GetRenderTarget()
	if rt and string.find(string.lower(rt:GetName()), "reflection", 1, true) then return end
	local frame = FrameNumber()
	if frame ~= lastFrame then
		lastFrame = frame
		local now = RealTime()
		if now >= nextPick then nextPick = now + 0.1 Pick() end
		if G.Request() ~= "ready" then G.Step() end
		-- the body's own model
		local mode = cvBody:GetInt()
		for ent in pairs(held) do if ent ~= HV.target or mode == 1 then Release(ent) end end
		if IsValid(HV.target) and mode ~= 1 then Hold(HV.target, mode) end
	end
	HV.marks = {}
	local body = HV.target
	if not IsValid(body) then return end
	local c, left, face, up, p = HV.Frame(body)
	if not c then return end
	local show = string.lower(cvShow:GetString())
	local brain = show ~= "skull" and istable(NeuroTrauma) and istable(NeuroTrauma.Brain3D) and isfunction(NeuroTrauma.Brain3D.DrawHead)
	-- The brain first, and the skull as glass round it. Cut open it is the other way round: the kept
	-- half lies behind the brain and is drawn first, the brain over it (the brain's cortex is drawn a
	-- little clear and leaves no depth behind: a wall drawn after it would be drawn over it).
	if show ~= "cut" then HV.brainDrawn = brain and NeuroTrauma.Brain3D.DrawHead(body, FrameTime()) or false end
	if show ~= "brain" and G.state == "ready" then
		if show == "cut" then
			-- the skull's left half away: what is kept lies on the right of the head's middle plane.
			-- The asset's bones are surfaces with an outside only; the kept half is drawn from the
			-- inside as well (its far faces, darker), so that the hollow the brain lies in shows.
			local old = render.EnableClipping(true)
			local n = -left
			render.PushCustomClipPlane(n, n:Dot(c))
			render.CullMode(MATERIAL_CULLMODE_CW)
			D.Body(body, { xray = true, only = OnlyHead, tint = InsideTint })
			render.CullMode(MATERIAL_CULLMODE_CCW)
			D.Body(body, { xray = true, only = OnlyHead })
			render.PopCustomClipPlane()
			render.EnableClipping(old)
		else
			D.Body(body, { xray = true, only = OnlyHead, alpha = show == "both" and HV.brainDrawn and 0.42 or nil })
		end
	end
	if show == "cut" then HV.brainDrawn = brain and NeuroTrauma.Brain3D.DrawHead(body, FrameTime()) or false end
	if cvMarks:GetBool() then
		render.SetColorMaterialIgnoreZ()
		local function W(h) return c + left * h[1] + face * h[2] + up * h[3] end
		for _, mk in ipairs(HF.Marks(p)) do
			local a = W(mk.skull)
			Cross(a, 0.22, SKULL_COL)
			if mk.head then
				local b = W(mk.head)
				Cross(b, 0.22, HEAD_COL)
				render.DrawLine(a, b, LINE_COL, false)
			end
			local s = a:ToScreen()
			if s.visible then HV.marks[#HV.marks + 1] = { s.x, s.y, mk.name } end
		end
	end
end)

-- (a body that is let go of, or gone, is drawn as it was)
cvars.AddChangeCallback("skel_head", function(_, _, new)
	if tonumber(new) == 0 then ReleaseAll() HV.target, HV.pinned = nil, nil end
end, "SK_HeadView")
hook.Add("EntityRemoved", "SK_HeadView", function(ent) held[ent] = nil end)

------------------------------------------------------------------------------------------
-- The camera by the head
------------------------------------------------------------------------------------------
-- { how far along left, face, up the camera stands (the head's own directions); which of them is up on the screen }
local CAMS = {
	side = { 1, 0, 0, "up" }, front = { 0, 1, 0, "up" }, back = { 0, -1, 0, "up" }, top = { 0, 0, 1, "face" }, quarter = { 0.62, 0.74, 0.22, "up" },
}
-- Where a camera of that name stands by a body's head now, how it is turned, and what it looks at.
-- The camera goes by the head's own level (the frame's axes turned by the head's tilt), not by the
-- head bone's axes: seen by those a head that is held level looks thrown back.
function HV.CamAt(body, name, dist)
	local cam = CAMS[string.lower(name or "")]
	if not cam then return nil end
	local c, left, face, up, p = HV.Frame(body)
	if not c then return nil end
	local t = math.rad(p.skull.tilt)
	face, up = face * math.cos(t) + up * math.sin(t), up * math.cos(t) - face * math.sin(t)
	local dir = left * cam[1] + face * cam[2] + up * cam[3]
	dir:Normalize()
	-- (the middle of the head: a little under the frame's origin, which lies in the brain)
	local at = c - up * 1.2
	return at + dir * (dist or C.HeadView.dist), (-dir):AngleEx(cam[4] == "face" and face or up), at
end
hook.Add("CalcView", "SK_HeadView", function(ply, origin, angles, fov)
	if not cvOn:GetBool() then return end
	local name = string.lower(cvCam:GetString())
	if not CAMS[name] or not V.Allowed() or not IsValid(HV.target) then return end
	local pos, ang = HV.CamAt(HV.target, name)
	if not pos then return end
	return { origin = pos, angles = ang, fov = C.HeadView.fov, drawviewer = true }
end)

------------------------------------------------------------------------------------------
-- The words on the screen
------------------------------------------------------------------------------------------
local function Text(s, font, x, y, col)
	draw.SimpleText(s, font, x + 1, y + 1, Color(0, 0, 0, 220))
	draw.SimpleText(s, font, x, y, col)
	return y + (font == "SK_View" and 17 or 15)
end

-- What there is to say of a body's head, as lines.
function HV.Lines(body)
	local pose, why = SK.PoseOf(body)
	if not pose then return { string.format("%s: no skeleton (%s)", tostring(body), tostring(why)) } end
	local p = HF.For(pose.prof.model)
	local s, j, b = p.skull, p.jaw, p.brain
	local lines = {}
	lines[#lines + 1] = string.format("%s  %s  | head: %s", tostring(body), string.match(body:GetModel() or "?", "([^/]+)%.mdl$") or "?", p.src)
	lines[#lines + 1] = string.format("skull  tilt %.2f  pitch %.2f  side %.3f  along %.3f  high %.3f  fwd %.3f  up %.3f", s.tilt, s.pitch, s.side, s.along, s.high, s.fwd, s.up)
	lines[#lines + 1] = string.format("jaw    long %.3f  high %.3f  broad %.3f", j.long, j.high, j.broad)
	lines[#lines + 1] = string.format("brain  k %.3f  f %.3f  u %.3f  pitch %.2f   (the brain module's own: k 2.58 at the frame's origin, pitch 0)", b.k, b.f, b.u, b.pitch)
	if p.fit and not p.adjusted then
		lines[#lines + 1] = string.format("generator: left over at the landmarks %.2f units; outside the skin: skull %.1f %%, jaw %.1f %%; brain in the bone %.1f %%", p.fit.rms, p.fit.skullOut, p.fit.jawOut, p.fit.brainOut)
	elseif not p.measured then
		lines[#lines + 1] = "not measured by the generator: the stock skull as the rig carries it, the brain as it lies in that skull (fit it with skel_head_set)"
	end
	local place = SK.BrainPlace(body)
	if place and place.cord then lines[#lines + 1] = string.format("cord: bent %.1f degrees at the skull's base to run down the neck", place.cord.bent) end
	local ms = {}
	for _, mk in ipairs(HF.Marks(p)) do
		if mk.head then ms[#ms + 1] = string.format("%s %.2f", mk.name, mk.dist) end
	end
	if #ms > 0 then
		lines[#lines + 1] = "landmarks, skull to head (units; the tissue between belongs there):"
		for i = 1, #ms, 4 do lines[#lines + 1] = "   " .. table.concat(ms, "   ", i, math.min(i + 3, #ms)) end
	end
	return lines
end

hook.Add("HUDPaint", "SK_HeadView", function()
	if not cvOn:GetBool() then return end
	local x, y = 24, math.floor(ScrH() * 0.42)
	if not V.Allowed() then
		Text("head view: needs skel_dev 1 on the server and a superadmin", "SK_View", x, y, Color(255, 180, 120))
		return
	end
	y = Text(string.format("HEAD VIEW (developer)  show %s  body %s  cam %s  |  skel_head 0 to leave", cvShow:GetString(), ({ [0] = "not drawn", "as it is", "faint" })[cvBody:GetInt()], cvCam:GetString()), "SK_View", x, y, Color(235, 225, 190))
	local small = Color(210, 210, 210)
	if G.state ~= "ready" then y = Text(G.state == "failed" and ("geometry: " .. G.note) or "taking the game's skeleton model apart ...", "SK_ViewSmall", x, y, Color(255, 200, 120)) end
	local body = HV.target
	if not IsValid(body) then
		Text("no body: look at one (skel_head_who aim), or skel_head_who self", "SK_ViewSmall", x, y, small)
		return
	end
	for _, l in ipairs(HV.Lines(body)) do y = Text(l, "SK_ViewSmall", x, y, small) end
	if string.lower(cvShow:GetString()) ~= "skull" and not HV.brainDrawn then
		y = Text("the brain is not drawn: the brain module is not loaded, or its meshes are not built yet", "SK_ViewSmall", x, y, Color(255, 200, 120))
	end
	if cvMarks:GetBool() then
		y = Text("marks: yellow the skull's, blue the head's own", "SK_ViewSmall", x, y, Color(160, 160, 160))
		for _, m in ipairs(HV.marks) do draw.SimpleText(m[3], "SK_ViewSmall", m[1] + 6, m[2] - 6, SKULL_COL) end
	end
end)

------------------------------------------------------------------------------------------
-- Fitting by hand
------------------------------------------------------------------------------------------
local function Out(s) MsgC(Color(215, 205, 170), "[Skeleton] ", color_white, s, "\n") end

local function Params()
	if not V.Allowed() then Out("needs skel_dev 1 and a superadmin") return nil end
	local body = IsValid(HV.target) and HV.target or SK.BodyOf(LocalPlayer())
	local pose = IsValid(body) and SK.PoseOf(body)
	if not pose then Out("no body with a skeleton") return nil end
	return HF.For(pose.prof.model)
end

local function Change(args, by)
	local p = Params()
	if not p then return end
	local group, field = string.match(string.lower(args[1] or ""), "^(%a+)%.(%a+)$")
	local v = tonumber(args[2] or "")
	local t = group and p[group]
	if not (group == "skull" or group == "jaw" or group == "brain") or type(t) ~= "table" or type(t[field]) ~= "number" or not v then
		Out("skel_head_set <what> <value>: what is one of skull.tilt skull.pitch skull.side skull.along skull.high skull.fwd skull.up jaw.long jaw.high jaw.broad brain.k brain.f brain.u brain.pitch")
		return
	end
	local new = by and t[field] + v or v
	-- (a size of nothing has no inverse)
	if (field == "side" or field == "along" or field == "high" or field == "long" or field == "broad" or field == "k") and new < 0.2 then Out("too small a size") return end
	t[field] = new
	HF.Changed(p)
	Out(string.format("%s: %s.%s = %.4f (on this client; skel_head_print gives the line to keep)", p.model, group, field, new))
end
concommand.Add("skel_head_set", function(_, _, args) Change(args, false) end, nil, "Skeleton head view: a number of this model's head, tried out. skel_head_set skull.side 0.8")
concommand.Add("skel_head_nudge", function(_, _, args) Change(args, true) end, nil, "Skeleton head view: a number of this model's head changed by so much. skel_head_nudge brain.u 0.1")
concommand.Add("skel_head_print", function()
	local p = Params()
	if not p then return end
	Out("for HF.Adjust in lua/skeleton/sh_headfit.lua (" .. p.src .. "):")
	Out(HF.Line(p))
end, nil, "Skeleton head view: this model's head as a line for HF.Adjust")
concommand.Add("skel_head_reset", function()
	if not V.Allowed() then Out("needs skel_dev 1 and a superadmin") return end
	HF.Forget()
	Out("what was tried out is dropped: every head is as the files have it")
end, nil, "Skeleton head view: drop what was tried out")
