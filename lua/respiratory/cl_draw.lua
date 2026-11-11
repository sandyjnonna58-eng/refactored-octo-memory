-- Client: drawing the lungs, the airways and the diaphragm inside a body. Called by the developer
-- view only (cl_view.lua): nothing here runs in ordinary play.
--
-- For a body and a frame: the body's pose as the skeleton module reads it after the body was drawn
-- (so Z-City's breathing chest, a body laid down, an animation are all in it), the four numbers of
-- the link (sh_link.lua) from the body's breathing clock and what is known to be wrong with its
-- lungs, the models posed by them (cl_rig.lua) and drawn.
--
--   RS.Draw.Body(body, opts)   opts.xray: through the body (the parts still hide each other, and
--                              the skeleton view's bones hide them and are hidden by them);
--                              opts.hold: the diaphragm's travel set by hand, 0..1, instead of the clock;
--                              opts.lungs: how solid the lungs are, 0 (not drawn) .. 1;
--                              opts.airways, opts.diaphragm: false leaves them out
--   RS.Draw.Controls(body, hold, out)   the four numbers alone, and what they were made from

local RS = HemoRespiratory
RS.NoJIT()
RS.Draw = RS.Draw or {}
local DR = RS.Draw
local C, CL, RG, LK = RS.Config, RS.CL, RS.Rig, RS.Link
local SK = HemoSkeleton

-- (all: since the session began; last: the frame before the newest one in which anything was drawn)
DR.stats = DR.stats or { bodies = 0, models = 0, ms = 0, frame = -1, last = { bodies = 0, models = 0, ms = 0 }, all = { bodies = 0, models = 0, ms = 0 } }

local lights = {
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
	{ type = MATERIAL_LIGHT_DIRECTIONAL, color = Vector(1, 1, 1), dir = Vector(1, 0, 0) },
}
-- Light fixed to the eye, as the skeleton view has it: what is inside a body has no light of its own.
local function LightsOn(at)
	local ang = EyeAngles()
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local V = C.View
	local amb = render.GetLightColor(at)
	local a = V.ambient
	lights[1].color = Vector(V.key, V.key * 0.98, V.key * 0.96)
	lights[2].color = Vector(V.fill * 0.9, V.fill * 0.95, V.fill)
	lights[1].dir = (f * 0.6 + r * 0.45 - u * 0.65):GetNormalized()
	lights[2].dir = (f * 0.5 - r * 0.8 - u * 0.1):GetNormalized()
	render.SuppressEngineLighting(true)
	render.SetLightingOrigin(at)
	render.ResetModelLighting(a + amb.x * 0.25, a + amb.y * 0.25, a + amb.z * 0.25)
	render.SetLocalModelLights(lights)
end
local function LightsOff()
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
end

local curPose
local function Skin(key) return curPose:Skin(key) end
DR.Skin = Skin

-- The four numbers for a body now. out: dl, dr, fl, fr; and what they were made from: out.vl,
-- out.vr (how full each side's breath is), out.depth, out.clock, out.rec, out.src.
function DR.Controls(body, hold, out)
	out = out or {}
	local c, rec = CL.ClockOf(body), CL.Record(body)
	local vl, vr, depth = 0, 0, 1
	if c then vl, vr, depth = CL.Fill(c, CurTime()) end
	LK.Controls(vl, vr, depth, rec, out)
	out.src = c and "clock" or "none"
	if hold then
		-- (set by hand: the whole of the travel is there to be looked at, whatever the lungs could do)
		out.dl, out.dr, out.src = hold, hold, "hand"
	end
	out.vl, out.vr, out.depth, out.clock, out.rec = vl, vr, depth, c, rec
	return out
end

local ctl = {}
local at = Vector()
local ORDER = { "diaphragm", "airways", "lung_r", "lung_l" }

function DR.Body(body, opts)
	if not RG.Ready() then return 0 end
	local pose = SK.PoseOf(body)
	if not pose then return 0 end
	local t0 = SysTime()
	-- (the body's bones as they are now, after it was drawn)
	pose:Fresh()
	local chest = pose:Skin("spine_up")
	if not chest then return 0 end
	curPose = pose
	DR.Controls(body, opts.hold, ctl)
	local rec = ctl.rec
	-- (about the middle of the chest, in the rest pose's own terms: between the lungs' roots)
	local h = RS.RigData.hilum
	at.x, at.y, at.z = SK.M.Xf(chest, 0, (h.r[2] + h.l[2]) * 0.5, (h.r[3] + h.l[3]) * 0.5)
	LightsOn(at)
	if opts.xray then render.DepthRange(0, 0.02) end
	local n = 0
	local solid = opts.lungs or 1
	for _, id in ipairs(ORDER) do
		local lung = id == "lung_r" or id == "lung_l"
		local show = (lung and solid > 0.01) or (id == "airways" and opts.airways ~= false) or (id == "diaphragm" and opts.diaphragm ~= false)
		if show then
			local ent = RG.Pose(id, Skin, ctl, at)
			if ent then
				local r, g, b = 1, 1, 1
				if lung and rec then
					if id == "lung_r" then r, g, b = LK.Tint(rec.damageR, rec.collapseR) else r, g, b = LK.Tint(rec.damageL, rec.collapseL) end
				end
				render.SetColorModulation(r, g, b)
				if lung and solid < 0.995 then render.SetBlend(solid) end
				ent:DrawModel()
				if lung and solid < 0.995 then render.SetBlend(1) end
				n = n + 1
			end
		end
	end
	render.SetColorModulation(1, 1, 1)
	if opts.xray then render.DepthRange(0, 1) end
	LightsOff()
	curPose = nil
	local s = DR.stats
	local fr = FrameNumber()
	if s.frame ~= fr then
		s.last.bodies, s.last.models, s.last.ms = s.bodies, s.models, s.ms
		s.frame, s.bodies, s.models, s.ms = fr, 0, 0, 0
	end
	local ms = (SysTime() - t0) * 1000
	s.bodies, s.models, s.ms = s.bodies + 1, s.models + n, s.ms + ms
	s.all.bodies, s.all.models, s.all.ms = s.all.bodies + 1, s.all.models + n, s.all.ms + ms
	return n
end

-- Where a mark of the model stands on a body now (Vector), or nil. hold: as for DR.Body.
local mctl = {}
function DR.MarkPos(body, id, hold)
	local pose = SK.PoseOf(body)
	if not pose then return nil end
	curPose = pose
	DR.Controls(body, hold, mctl)
	local x, y, z = RG.Mark(id, Skin, mctl)
	curPose = nil
	return x and Vector(x, y, z) or nil
end
