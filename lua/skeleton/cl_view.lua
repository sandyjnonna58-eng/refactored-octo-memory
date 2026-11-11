-- Client: the developer's inspection view. A skeleton drawn inside a body, with what is needed to
-- check it: which bone is which, what it hangs on, where the joints are, what stands for it in a
-- collision query, what the asset has no geometry for, what is known to be wrong with it.
--
-- It is a developer's tool and behaves like one: it needs skel_dev 1 on the server and a superadmin
-- (or the listen server's host); its switches are not saved, so nothing is on after a restart; and
-- while it is on a line on the screen says so. With skel_view 0 this file draws nothing, asks the
-- server for nothing and builds nothing; the registry, the poses and the queries work regardless.
--
--   skel_view 0 | 1 | 2        off | through the body | as part of the world (what shows has come through the surface)
--   skel_view_who aim|all|self the body looked at (it stays until another is looked at) | every body near | one's own
--   skel_view_colour 0..3      the bone's own texture | every unit its own colour | by the animation bone it hangs on | by how sure its geometry is
--   skel_view_labels 0|1       the bone under the crosshair is named
--   skel_view_joints 0|1       the joints the rig moves
--   skel_view_proxies 0|1|2    collision solids: of the bone looked at | of every bone
--   skel_view_missing 0|1      bones this asset has no geometry for
--   skel_view_fit 0|1          the body model's fit off, to see the stock skeleton as it is
--   skel_view_tier 1..3        leave out the minute (3) or the detailed (2) bones
--   skel_info <bone>, skel_list [structure], skel_check, skel_rig     in words, in the console
-- How skull, lower jaw and brain lie in a head is looked at, and fitted by hand, in a view of its
-- own: skel_head (cl_headview.lua).

local SK = HemoSkeleton
SK.NoJIT()
SK.View = SK.View or {}
local V = SK.View
local C, G, D, CL, ST, R, P, M = SK.Config, SK.Geo, SK.Draw, SK.CL, SK.Stock, SK.Rig, SK.Pose, SK.M

local cvView = CreateClientConVar("skel_view", "0", false, false, "Skeleton: the inspection view. 0 off, 1 through the body, 2 as part of the world (superadmin, skel_dev 1)", 0, 2)
local cvWho = CreateClientConVar("skel_view_who", "aim", false, false, "Skeleton view: aim (the body looked at), all (every body near), self")
local cvColour = CreateClientConVar("skel_view_colour", "0", false, false, "Skeleton view: 0 the bone's texture, 1 every unit its own colour, 2 by the animation bone it hangs on, 3 by how its geometry is had", 0, 3)
local cvLabels = CreateClientConVar("skel_view_labels", "1", false, false, "Skeleton view: name the bone under the crosshair", 0, 1)
local cvJoints = CreateClientConVar("skel_view_joints", "0", false, false, "Skeleton view: mark the joints the rig moves", 0, 1)
local cvProxies = CreateClientConVar("skel_view_proxies", "0", false, false, "Skeleton view: collision solids. 1 of the bone looked at, 2 of every bone", 0, 2)
local cvMissing = CreateClientConVar("skel_view_missing", "0", false, false, "Skeleton view: mark the bones the asset has no geometry for", 0, 1)
local cvFit = CreateClientConVar("skel_view_fit", "1", false, false, "Skeleton view: 0 shows the stock skeleton without the body model's fit", 0, 1)
local cvTier = CreateClientConVar("skel_view_tier", "3", false, false, "Skeleton view: the highest tier of bone shown (1 structural, 2 detailed, 3 minute)", 1, 3)

V.targets = V.targets or {}          -- bodies shown now
V.hover = nil                        -- { body, id, t, x, y, z }
V.marks = {}                         -- what the 3D pass leaves for the HUD: { x, y, text, colour }

function V.Allowed()
	local me = LocalPlayer()
	return IsValid(me) and SK.DevAllowed(me)
end
function V.On() return cvView:GetInt() > 0 and V.Allowed() end

------------------------------------------------------------------------------------------
-- Whom to show
------------------------------------------------------------------------------------------
local function IsBody(e)
	return IsValid(e) and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) and not e:IsDormant()
end

-- The eye of the frame's main view. The scene is drawn more than once a frame where water is in
-- sight (for its reflection, from a mirrored eye, and for what lies under it), and by anything that
-- films it for a screen in the world; whichever of those is drawn first, what is looked at is asked
-- of the main view. (Found in the game: on a map with water the view picked nobody, the first
-- drawing of a frame being the reflection's.)
local mainEye, mainAng, mainFrame = Vector(), Angle(), -1
hook.Add("RenderScene", "SK_View", function(origin, angles)
	if cvView:GetInt() == 0 then return end
	mainEye:Set(origin)
	mainAng:Set(angles)
	mainFrame = FrameNumber()
end)
local function Eye()
	if mainFrame == FrameNumber() then V.eyeFrom = "the main view" return mainEye, mainAng end
	-- (the hook above was not run this frame: another addon draws the scene itself)
	V.eyeFrom = "the drawing at hand"
	return EyePos(), EyeAngles()
end
V.Eye = Eye

local sticky
local nextPick = 0
local function Pick()
	local me = LocalPlayer()
	local who = string.lower(cvWho:GetString())
	local eye, eyeAng = Eye()
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
					if d < C.View.dist * C.View.dist then list[#list + 1] = b b.SK_viewDist = d end
				end
			end
		end
		table.sort(list, function(a, b) return a.SK_viewDist < b.SK_viewDist end)
		for i = #list, C.View.shown + 1, -1 do list[i] = nil end
	else
		local fwd = eyeAng:Forward()
		local tr = util.TraceLine({ start = eye, endpos = eye + fwd * C.View.dist, filter = me, mask = MASK_SHOT })
		local e = tr.Entity
		if IsBody(e) then
			sticky = SK.BodyOf(e)
		else
			-- (a body the trace does not stop at, as Z-City's ragdolls can be: the one whose middle lies nearest the line of sight)
			local best, bd
			for _, c in ipairs(ents.GetAll()) do
				if IsBody(c) and c ~= me then
					local b = SK.BodyOf(c)
					if IsValid(b) and not b:GetNoDraw() then
						local to = b:WorldSpaceCenter() - eye
						local along = to:Dot(fwd)
						if along > 0 and along < C.View.dist then
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
			local owner = istable(ABL) and ABL.ZC and ABL.ZC.GetOwner and ABL.ZC.GetOwner(sticky)
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

------------------------------------------------------------------------------------------
-- Colours
------------------------------------------------------------------------------------------
local PALETTE = { { 0.90, 0.35, 0.31 }, { 0.35, 0.67, 0.94 }, { 0.43, 0.82, 0.47 }, { 0.94, 0.78, 0.31 }, { 0.75, 0.47, 0.90 }, { 0.31, 0.84, 0.82 }, { 0.94, 0.55, 0.24 },
	{ 0.63, 0.75, 0.35 }, { 0.92, 0.47, 0.71 }, { 0.51, 0.55, 0.94 }, { 0.78, 0.67, 0.51 }, { 0.47, 0.90, 0.67 } }
local STATE = { [1] = { 0.95, 0.86, 0.50 }, [2] = { 1.0, 0.66, 0.26 }, [3] = { 1.0, 0.33, 0.24 }, [4] = { 0.80, 0.12, 0.12 }, [5] = { 0.22, 0.22, 0.28 } }
local HOW = { piece = { 0.85, 0.95, 0.85 }, cut = { 1.0, 0.85, 0.45 }, shared = { 0.75, 0.75, 1.0 }, extra = { 0.7, 0.7, 0.7 }, bone = { 1.0, 0.6, 0.6 } }
local unitNo, keyNo = {}, {}
do
	local n = 0
	for _, key in ipairs(R.KEYS) do n = n + 1 keyNo[key] = n end
end

local curBody, curRec, curHoverUnit
local function Tint(u)
	if curHoverUnit == u.id then return 1.0, 0.95, 0.35 end
	-- what is wrong with it: the worst of its bones
	if curRec then
		local worst = 0
		for _, id in ipairs(u.bones) do
			local e = curRec.bones[SK.Bones[id].idx]
			if e and e.state > worst then worst = e.state end
		end
		if worst > 0 then local c = STATE[worst] return c[1], c[2], c[3] end
	end
	local mode = cvColour:GetInt()
	if mode == 1 then
		local n = unitNo[u.id]
		if not n then n = 0 for i, id in ipairs(G.order) do unitNo[id] = i end n = unitNo[u.id] or 1 end
		local c = PALETTE[(n - 1) % #PALETTE + 1]
		return c[1], c[2], c[3]
	elseif mode == 2 then
		local key = u.key or (u.carry[1] and u.carry[1][1])
		-- (a part of a bone's load, the lower jaw or a pair of ribs: its bone's colour)
		key = P.PART[key] or key
		local c = PALETTE[((keyNo[key] or 1) - 1) % #PALETTE + 1]
		return c[1], c[2], c[3]
	elseif mode == 3 then
		local c = HOW[u.how] or HOW.extra
		return c[1], c[2], c[3]
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
local JOINT_COL, MISS_COL, PROXY_COL, PROXY_ALL = Color(90, 230, 255), Color(255, 90, 230), Color(120, 255, 140), Color(120, 255, 140, 90)

local function Cross(p, size, col)
	render.DrawLine(p - Vector(size, 0, 0), p + Vector(size, 0, 0), col, false)
	render.DrawLine(p - Vector(0, size, 0), p + Vector(0, size, 0), col, false)
	render.DrawLine(p - Vector(0, 0, size), p + Vector(0, 0, size), col, false)
end

local function Mark(p, text, col)
	local s = p:ToScreen()
	if s.visible then V.marks[#V.marks + 1] = { s.x, s.y, text, col } end
end

-- The bone the line of sight meets first in any shown body.
local function Hover()
	local eye, eyeAng = Eye()
	local far = eye + eyeAng:Forward() * C.View.labelDist
	local best
	for _, body in ipairs(V.targets) do
		local hits = SK.Trace(body, eye, far, { first = true })
		local h = hits and hits[1]
		if h and (not best or h.tIn < best.t) then best = { body = body, id = h.id, t = h.tIn, kind = h.kind } end
	end
	V.hover = best
end

local lastFrame = -1
V.passes = 0
hook.Add("PostDrawTranslucentRenderables", "SK_View", function(depth, sky)
	if depth or sky or cvView:GetInt() == 0 then return end
	if not V.Allowed() then return end
	-- (a reflection in water is no place for a developer's view, and would cost a whole drawing of it)
	local rt = render.GetRenderTarget()
	if rt and string.find(string.lower(rt:GetName()), "reflection", 1, true) then return end
	-- (the scene can be drawn more than once a frame; what is worked out for a frame is worked out once)
	local frame = FrameNumber()
	local first = frame ~= lastFrame
	lastFrame = frame
	if first then
		V.passes = 0
		local now = RealTime()
		if now >= nextPick then nextPick = now + 0.1 Pick() end
		if G.Request() ~= "ready" then G.Step() end
	end
	V.passes = V.passes + 1
	if G.state ~= "ready" then return end
	-- (the fit can be switched off for a look: every pose is worked out again)
	local noFit = not cvFit:GetBool()
	if P.noFit ~= noFit then P.noFit = noFit P.gen = P.gen + 1 end
	V.marks = {}
	if first then
		if cvLabels:GetBool() or cvProxies:GetInt() == 1 then Hover() else V.hover = nil end
	end
	local xray = cvView:GetInt() == 1
	for _, body in ipairs(V.targets) do
		if IsValid(body) then
			curBody, curRec = body, CL.Record(body)
			local st = V.hover and V.hover.body == body and ST.bones[V.hover.id]
			curHoverUnit = st and st.unit or nil
			D.Body(body, { xray = xray, tint = Tint, tier = cvTier:GetInt() })
			local pose = SK.PoseOf(body)
			if pose then
				-- (every solid of a body is some twelve thousand lines: of the first body shown only)
				if cvProxies:GetInt() == 2 and body == V.targets[1] then D.Proxies(body, nil, PROXY_ALL)
				elseif cvProxies:GetInt() == 1 and V.hover and V.hover.body == body then D.Proxies(body, V.hover.id, PROXY_COL) end
				if cvJoints:GetBool() then
					render.SetColorMaterialIgnoreZ()
					for _, j in ipairs(SK.JointList) do
						if j.rig then
							-- a joint the rig moves is where the child's animation bone begins
							local rows = pose:Carrier(j.rig[2])
							if rows then
								local p = Vector(rows[4], rows[8], rows[12])
								Cross(p, 0.9, JOINT_COL)
								if p:DistToSqr(EyePos()) < 160 * 160 then Mark(p, j.id, JOINT_COL) end
							end
						end
					end
				end
				if cvMissing:GetBool() then
					render.SetColorMaterialIgnoreZ()
					for _, b in ipairs(SK.BoneList) do
						local s = ST.bones[b.id]
						if s and s.src ~= "stock" then
							local x, y, z = pose:BonePos(b.id)
							if x then
								local p = Vector(x, y, z)
								Cross(p, 0.35, MISS_COL)
								if b.tier <= 2 and p:DistToSqr(EyePos()) < 90 * 90 then Mark(p, b.id, MISS_COL) end
							end
						end
					end
				end
			end
		end
	end
	curBody, curRec, curHoverUnit = nil, nil, nil
end)

------------------------------------------------------------------------------------------
-- The words on the screen
------------------------------------------------------------------------------------------
surface.CreateFont("SK_View", { font = "Tahoma", size = 15, weight = 600, antialias = true })
surface.CreateFont("SK_ViewSmall", { font = "Tahoma", size = 13, weight = 500, antialias = true })

local function Text(s, font, x, y, col)
	draw.SimpleText(s, font, x + 1, y + 1, Color(0, 0, 0, 220))
	draw.SimpleText(s, font, x, y, col)
	return y + (font == "SK_View" and 17 or 15)
end

-- What there is to say of a bone on a body, as lines.
function V.BoneLines(body, id)
	local b, st = SK.Bones[id], ST.bones[id]
	if not b then return { "no bone " .. tostring(id) } end
	local lines = {}
	lines[#lines + 1] = string.format("%s  (#%d)  %s", b.id, b.idx, b.name)
	lines[#lines + 1] = string.format("%s, %s bone, tier %d; part of: %s", b.region, b.class, b.tier, table.concat(SK.PartOf(b.id), " < "))
	if b.proximal then lines[#lines + 1] = "hangs on: " .. b.proximal end
	local js = {}
	for _, jid in ipairs(b.joints) do js[#js + 1] = jid end
	lines[#lines + 1] = "joints: " .. (#js > 0 and table.concat(js, ", ") or "none")
	if st then
		local unit = st.unit and ST.units[st.unit]
		local geo = unit and (unit.how == "piece" and "a piece of the model of its own" or (unit.how == "cut" and "cut from a fused piece of the model: its borders are approximate" or "one piece of the model for " .. #unit.bones .. " bones")) or "none in this asset"
		lines[#lines + 1] = "geometry: " .. geo .. (st.src == "derived" and "; placed on the rig by rule" or (st.src == "placed" and "; a place only" or ""))
		lines[#lines + 1] = "collision: " .. (st.proxy == "shell" and string.format("the skull's shell (%.2f units thick, assumed)", SK.Cranial.Thick(id)) or (istable(st.proxy) and (#st.proxy .. " solid(s)") or "none"))
	end
	if IsValid(body) then
		local carry, info = SK.BoneCarriers(body, id)
		if carry then
			local cs = {}
			for _, c in ipairs(carry) do
				cs[#cs + 1] = string.format("%s%s = %s%s", c.key, c.weight < 0.999 and string.format(" %.0f%%", c.weight * 100) or "", c.name and string.gsub(c.name, "ValveBiped%.Bip01_", "") or "nothing",
					c.standin and (" (stand-in " .. c.standin .. ")") or "")
			end
			lines[#lines + 1] = "carried by: " .. table.concat(cs, ", ") .. "; fit: " .. tostring(info.fit)
			local p = SK.BonePos(body, id)
			if p then lines[#lines + 1] = string.format("at %.1f %.1f %.1f", p.x, p.y, p.z) end
		end
		local rec = CL.Record(body)
		local e = rec and rec.bones[b.idx]
		if e then
			lines[#lines + 1] = string.format("RECORD: %s, integrity %d%s%s, from %s", C.StateName[e.state], e.integrity, e.site and string.format(", at %.2f of its length", e.site) or "",
				bit.band(e.flags, C.Flag.APPROX) ~= 0 and ", nearest bone to the path" or "", tostring(e.src))
		end
		-- the brain under a skull bone
		if st and st.proxy == "shell" and SK.Brain.Available() then
			local under = SK.Brain.RegionsUnder(id)
			if #under > 0 then
				local names = {}
				for i = 1, math.min(#under, 4) do names[#names + 1] = NeuroTrauma.Atlas.regions[under[i]].key end
				lines[#lines + 1] = string.format("over %d region(s) of the brain module's atlas: %s%s", #under, table.concat(names, ", "), #under > 4 and " ..." or "")
			end
		end
	end
	return lines
end

hook.Add("HUDPaint", "SK_View", function()
	if cvView:GetInt() == 0 then return end
	local x, y = 24, math.floor(ScrH() * 0.16)
	if not V.Allowed() then
		Text("skeleton view: needs skel_dev 1 on the server and a superadmin", "SK_View", x, y, Color(255, 180, 120))
		return
	end
	local head = Color(235, 225, 190)
	y = Text(string.format("SKELETON VIEW (developer)  %s  |  skel_view 0 to leave", cvView:GetInt() == 1 and "through the body" or "as part of the world"), "SK_View", x, y, head)
	local small = Color(210, 210, 210)
	if G.state ~= "ready" then
		y = Text(G.state == "failed" and ("geometry: " .. G.note) or "taking the game's skeleton model apart ...", "SK_ViewSmall", x, y, Color(255, 200, 120))
		return
	end
	if G.coarse then y = Text("the skeleton model on this machine is not the stock one: drawn by animation bone, its bones cannot be told apart", "SK_ViewSmall", x, y, Color(255, 160, 120)) end
	if #V.targets == 0 then y = Text("no body shown: look at one (skel_view_who aim), or skel_view_who all / self", "SK_ViewSmall", x, y, small) end
	for i, body in ipairs(V.targets) do
		if i > 3 then break end
		local pose, why = SK.PoseOf(body)
		if pose then
			local prof, fit = pose.prof, pose.fit
			local rec = CL.Record(body)
			y = Text(string.format("%s  %s  | rig %s, %d stand-in(s), %d carried by nothing | fit: %s%s; head: %s | record: %s", tostring(body), string.match(body:GetModel() or "?", "([^/]+)%.mdl$") or "?",
				prof.rig, prof.standins, #prof.missing, cvFit:GetBool() and fit.src or "off", fit.out and cvFit:GetBool() and string.format(" (%.1f%% outside, generator)", fit.out[2]) or "",
				cvFit:GetBool() and tostring(fit.head) or "off", rec and (rec.n .. " bone(s), v" .. rec.ver) or "none"), "SK_ViewSmall", x, y, small)
		else
			y = Text(string.format("%s: no skeleton (%s)", tostring(body), tostring(why)), "SK_ViewSmall", x, y, Color(255, 160, 120))
		end
	end
	-- (the scene may be drawn more than once a frame, where water is in sight: the cost is that of all of them)
	local s = D.stats.last
	y = Text(string.format("%d bod%s shown; the frame before: drawn %d time(s), %d units, %.2f ms", #V.targets, #V.targets == 1 and "y" or "ies", s.bodies, s.units, s.ms), "SK_ViewSmall", x, y, Color(160, 160, 160))
	-- the bone under the crosshair
	if V.hover and cvLabels:GetBool() then
		local hx, hy = ScrW() / 2 + 26, ScrH() / 2 + 18
		for i, l in ipairs(V.BoneLines(V.hover.body, V.hover.id)) do
			hy = Text(l, i == 1 and "SK_View" or "SK_ViewSmall", hx, hy, i == 1 and Color(255, 242, 150) or small)
		end
	end
	for _, m in ipairs(V.marks) do
		draw.SimpleText(m[3], "SK_ViewSmall", m[1] + 5, m[2] - 6, m[4])
	end
end)

cvars.AddChangeCallback("skel_view", function(_, _, new)
	if tonumber(new) == 0 then
		CL.Forget()
		V.targets, V.hover, sticky = {}, nil, nil
	end
end, "SK_View")

------------------------------------------------------------------------------------------
-- In words, in the console
------------------------------------------------------------------------------------------
local function Out(s) MsgC(Color(215, 205, 170), "[Skeleton] ", color_white, s, "\n") end

local function Target()
	local b = V.targets[1]
	if IsValid(b) then return b end
	local me = LocalPlayer()
	local e = me:GetEyeTrace().Entity
	if IsBody(e) then return SK.BodyOf(e) end
	return SK.BodyOf(me)
end

concommand.Add("skel_info", function(_, _, args)
	local id = string.lower(args[1] or "")
	if tonumber(id) and SK.BoneByIdx[tonumber(id)] then id = SK.BoneByIdx[tonumber(id)].id end
	if not SK.Bones[id] then Out("no bone \"" .. id .. "\" (skel_list lists them)") return end
	for _, l in ipairs(V.BoneLines(V.Allowed() and Target() or nil, id)) do Out(l) end
	local nb = {}
	for other, jid in pairs(SK.Neighbours(id)) do nb[#nb + 1] = other .. " (" .. jid .. ")" end
	table.sort(nb)
	Out("articulates with: " .. (#nb > 0 and table.concat(nb, ", ") or "nothing"))
	local d = SK.Distal(id)
	if #d > 0 then Out(#d .. " bone(s) lie beyond it") end
end, nil, "Skeleton: a bone in words. skel_info <id or number>")

concommand.Add("skel_list", function(_, _, args)
	local name = string.lower(args[1] or "skeleton")
	if not SK.Groups[name] and not SK.Sets[name] then
		local gs = {}
		for id in pairs(SK.Groups) do gs[#gs + 1] = id end
		for id in pairs(SK.Sets) do gs[#gs + 1] = id end
		table.sort(gs)
		Out("structures: " .. table.concat(gs, " "))
		return
	end
	local ids = SK.BonesOf(name)
	Out(string.format("%s: %d bone(s)", name, #ids))
	local line = {}
	for i, id in ipairs(ids) do
		line[#line + 1] = id
		if #line == 10 or i == #ids then Out("  " .. table.concat(line, " ")) line = {} end
	end
end, nil, "Skeleton: the bones of a structure (none: the names of the structures). skel_list [structure]")

concommand.Add("skel_check", function()
	local bad = SK.Check()
	Out(string.format("registry: %d bones, %d joints, sum %d: %s", #SK.BoneList, #SK.JointList, SK.Sum(), #bad == 0 and "whole" or (#bad .. " complaint(s)")))
	for _, s in ipairs(bad) do Out("  " .. s) end
	Out("geometry: " .. G.state .. (G.note ~= "" and (": " .. G.note) or " (it is read when the view first needs it)"))
	Out(string.format("brain module: %s", SK.Brain.Available() and "loaded" or "not loaded"))
end, nil, "Skeleton: the registry and the geometry looked over")

concommand.Add("skel_rig", function()
	if not V.Allowed() then Out("needs skel_dev 1 and a superadmin") return end
	local body = Target()
	if not IsValid(body) then Out("no body") return end
	local prof = R.Resolve(body)
	for _, l in ipairs(R.Describe(prof)) do Out(l) end
	local pose = SK.PoseOf(body)
	if pose then
		local keys = {}
		for key in pairs(pose.fit.keys) do keys[#keys + 1] = key end
		table.sort(keys)
		Out(string.format("fit: %s%s; %d key(s) changed%s", pose.fit.src, pose.fit.out and string.format(" (outside the body %.1f%% as it is, %.1f%% fitted: the generator's measure)", pose.fit.out[1], pose.fit.out[2]) or "", #keys,
			#keys > 0 and (": " .. table.concat(keys, " ")) or ""))
	end
end, nil, "Skeleton: how the body looked at is rigged and fitted (superadmin, skel_dev 1)")
