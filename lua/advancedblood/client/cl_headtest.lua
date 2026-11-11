-- Client half of the head-wound scenes (developer tool). Inert unless the test harness is running
-- (garrysmod/data/abl_selftest.txt, see cl_selftest.lua).
--
-- headprobe: one character is watched frame by frame, and a line is written whenever what the
-- blood module holds of it, or draws of it, is no longer what it was the frame before: its source
-- and the entity that is its body, each wound (hidden, closing, anchored on the skin, linked to
-- a record and a mark, bleeding), its marks, its film, whether its blood was drawn in this frame
-- and if not why, what the head bone's matrix is scaled by, and how far from its bone a wound's
-- blood is let out (E.WoundFrame, as the simulation calls it). A line now and then sums up the
-- frames in between.
-- headcam: a camera of this file's own, with the local player drawn in the picture or not (the
-- harness's camera never draws it).
-- headinfo: what decides how Z-City draws heads on this client.

ABL.NoJIT()
local T = ABL.TestClient
if not T then return end
local H, Log = T.H, T.Log
local Z = ABL.ZC
local sqrt, floor = math.sqrt, math.floor
local HEAD = "ValveBiped.Bip01_Head1"

local watched = {}                                    -- entity number -> what is kept of it
local bySrc = setmetatable({}, { __mode = "k" })      -- source -> the same, for the wound frames
local origFrame

local function Short(name) return (string.gsub(tostring(name), "ValveBiped%.Bip01_", "")) end

-- The source of the character a player is: its own while it lives, its corpse's after.
local function SourceOf(ent)
	local S = ABL.Sources
	if not IsValid(ent) then return nil end
	local src = S.byKey[ent]
	if src and IsValid(src.migratedTo) and S.byKey[src.migratedTo] then return S.byKey[src.migratedTo] end
	if not src and ent:IsPlayer() then
		local corpse = Z.GetCorpse(ent)
		if IsValid(corpse) then src = S.byKey[corpse] end
	end
	return src
end

local function HeadState(body)
	if not IsValid(body) then return "no body", 1 end
	local b = body:LookupBone(HEAD)
	if not b then return "no head bone", 1 end
	local m = body:GetBoneMatrix(b)
	local s = m and m:GetScale() or nil
	local ms = body:GetManipulateBoneScale(b)
	local fl = isfunction(GetNetVar) and GetNetVar("fountains") or nil
	local neck = body:GetNW2Vector("ABL_Neck", vector_origin)
	return string.format("head bone scaled %.2f (manipulated %.2f)%s%s%s", s and s.x or -1, ms and ms.x or -1,
		(istable(fl) and fl[body] ~= nil) and ", Z-City fountain" or "", (not neck:IsZero()) and ", neck stump told" or "", body.headexploded and ", headexploded" or ""), s and s.x or 1
end

local function NewSecond() return { t0 = RealTime(), frames = 0, drawn = 0, via = 0, unseen = 0, miss = 0, bare = 0, lines = 0, dropped = 0, n = 0 } end

local function Sample(w)
	local frame = FrameNumber()
	local ent = Entity(w.idx)
	local src = SourceOf(ent)
	local st = w.sec
	st.frames = st.frames + 1
	local sig, line
	if not src then
		sig = IsValid(ent) and "none" or "gone"
		line = IsValid(ent) and "no source" or "the entity is gone"
	else
		bySrc[src] = w
		local FM, FC = ABL.Film, ABL.FlowCore
		local body = src.body
		local drawn = src.dsFrame == frame
		local via = src.appearFrame == frame
		if drawn then st.drawn = st.drawn + 1 end
		if via then st.via = st.via + 1 end
		if not src.visible then st.unseen = st.unseen + 1 end
		local has = (src.segCount or 0) > 0 or #src.blobs > 0 or (src.marks ~= nil and #src.marks > 0) or FC.Active(src) or FM.Active(src)
		-- (the body was drawn in this frame, with blood to draw on it, and its blood was not)
		if via and has and not drawn then
			st.miss = st.miss + 1
			w.missAll = (w.missAll or 0) + 1
		end
		-- (the middle of the body is in the picture, by the view of this frame, and its blood was not
		-- drawn: for a body that is not drawn through Z-City's renderer, of which nothing says
		-- whether the game drew it)
		if has and not drawn and IsValid(body) then
			local sp = body:WorldSpaceCenter():ToScreen()
			if sp.visible and sp.x >= 0 and sp.x <= ScrW() and sp.y >= 0 and sp.y <= ScrH() then
				st.bare = st.bare + 1
				w.bareAll = (w.bareAll or 0) + 1
			end
		end
		local why
		if drawn then why = "its blood was drawn"
		elseif not has then why = "nothing to draw"
		elseif not IsValid(body) then why = "NOT DRAWN: no body"
		elseif not src.visible then why = "NOT DRAWN: not in sight by the LOD's reckoning"
		elseif (src.dist or 0) > 1600 then why = "NOT DRAWN: too far"
		elseif not via then why = "NOT DRAWN: Z-City did not draw the body"
		else why = "NOT DRAWN: the body was drawn, its blood was not" end
		local ws, wp = {}, {}
		for i, wd in ipairs(src.woundList) do
			local fl = (wd.hidden and "H" or "") .. (wd.closing and "C" or "") .. (wd.synthetic and "S" or "") .. (wd.tri and "A" or "") .. (wd.mark and "M" or "") .. (wd.rec and "L" or "")
				.. (((wd.flow or 0) > 0.0005) and "F" or "")
			local f = w.wf[wd.id]
			local fresh = f and f.f >= frame - 3
			-- (blood let out within half a unit of the bone's own origin: the wound is not where it was made)
			local collapsed = fresh and f.d < 0.5
			ws[i] = wd.id .. "=" .. fl .. (collapsed and "!" or "")
			wp[i] = string.format("%s on %s [%s] value %.1f, %.3f ml/s%s", wd.id, Short(wd.boneName), fl, wd.sev or 0, wd.flow or 0,
				fresh and string.format(", let out %.2f units from its bone (the bone scaled %.2f)%s", f.d, f.s, collapsed and " COLLAPSED" or "") or "")
		end
		table.sort(ws)
		local nm, nh = 0, 0
		for _, mk in ipairs(src.marks or {}) do
			nm = nm + 1
			if mk.hidden then nh = nh + 1 end
		end
		local pend = src.pendingMarks and #src.pendingMarks or 0
		local cells = src.film and src.film.n or 0
		local filmOn = FM.Active(src) and true or false
		local hs, scale = HeadState(body)
		sig = table.concat({ tostring(src.key), tostring(body), src.alive and "a" or "d", tostring(src.lod), src.visible and "v" or "-", table.concat(ws, ","), nm, nh, pend,
			filmOn and "f" or "-", floor(cells / 200), why, string.format("%.1f", scale) }, "|")
		line = string.format("%s%s, %s, LOD %s, %s, %.0f units off | %s | %d wound(s): %s | marks %d (%d hidden, %d waiting) | film %s, %d cells | %s",
			tostring(src.key), body ~= src.key and (" as " .. tostring(body)) or "", src.alive and "alive" or "dead", tostring(src.lod), src.visible and "in sight" or "NOT in sight", src.dist or -1,
			hs, #src.woundList, #wp > 0 and table.concat(wp, "; ") or "-", nm, nh, pend, filmOn and "active" or "none", cells, why)
	end
	if sig ~= w.sig then
		w.sig = sig
		w.changes = w.changes + 1
		if st.lines < 10 then
			st.lines = st.lines + 1
			Log(string.format("probe %s f%d: %s", w.name, frame, line))
		else
			st.dropped = st.dropped + 1
		end
	end
	local now = RealTime()
	if now - st.t0 >= 1 then
		-- (a second in which every frame had its blood drawn is said only now and then)
		w.quiet = (w.quiet or 0) + 1
		-- (how often the body was drawn a further time in a frame, and its film over it again)
		local src2 = SourceOf(Entity(w.idx))
		local again = src2 and (src2.againN or 0) or 0
		if st.drawn ~= st.frames or st.dropped > 0 or w.quiet >= 5 or again ~= (w.againSeen or 0) then
			w.quiet = 0
			Log(string.format("probe %s sum: %d frames in %.2f s: blood drawn in %d, body drawn by Z-City (with blood on it) in %d, BODY DRAWN WITHOUT ITS BLOOD in %d, in the picture without its blood in %d, not in sight in %d | the body drawn a further time in a frame, and its film again: %d time(s)%s", w.name, st.frames, now - st.t0,
				st.drawn, st.via, st.miss, st.bare, st.unseen, again - (w.againSeen or 0), st.dropped > 0 and string.format(" | %d more change(s) not written", st.dropped) or ""))
			w.againSeen = again
		end
		w.sec = NewSecond()
	end
end

local function Install()
	local E = ABL.Emission
	if origFrame or not E then return end
	origFrame = E.WoundFrame
	E.WoundFrame = function(src, wd)
		local ok, x, y, z, nx, ny, nz = origFrame(src, wd)
		local w = bySrc[src]
		if w and ok and wd.bone and IsValid(src.body) then
			local m = src.body:GetBoneMatrix(wd.bone)
			if m then
				local t = m:GetTranslation()
				local dx, dy, dz = x - t.x, y - t.y, z - t.z
				local f = w.wf[wd.id]
				if not f then f = {} w.wf[wd.id] = f end
				f.d, f.s, f.f = sqrt(dx * dx + dy * dy + dz * dz), m:GetScale().x, FrameNumber()
			end
		end
		return ok, x, y, z, nx, ny, nz
	end
end

function H.headprobe(t)
	local w = watched[t.ent]
	if t.mark then
		-- (a count of its own for one stretch of a scene: body drawn without its blood, since the last mark)
		if w then
			Log(string.format("probe %s, %s: since the last mark the body was drawn by Z-City without its blood in %d frame(s), and was in the picture without its blood in %d frame(s)", w.name, tostring(t.mark),
				w.missAll or 0, w.bareAll or 0))
			w.missAll, w.bareAll = 0, 0
		end
		return
	end
	if t.off then
		if w then Log(string.format("probe %s ends: %d change(s) in all", w.name, w.changes)) end
		watched[t.ent] = nil
		if origFrame and next(watched) == nil then ABL.Emission.WoundFrame = origFrame origFrame = nil end
		return
	end
	watched[t.ent] = { idx = t.ent, name = tostring(t.name or t.ent), changes = 0, wf = {}, sec = NewSecond() }
	Install()
	Log(string.format("probe %s begins on entity %d (%s)", tostring(t.name or t.ent), t.ent, tostring(Entity(t.ent))))
end

local failed
hook.Add("PostRender", "ABL_HeadProbe", function()
	for _, w in pairs(watched) do
		local ok, err = pcall(Sample, w)
		if not ok and not failed then failed = true Log("CLIENT ERROR in headprobe: " .. tostring(err)) end
	end
end)

-- A note in the client's log, at the client's own time (what a scene did, between the probe's lines).
function H.headnote(t) Log(string.format("note: %s (f%d)", tostring(t.text), FrameNumber())) end

-- The events of cl_trace.lua in this log as they come; and what there is now.
function H.tracesink(t)
	ABL.Trace.sink = t.on and function(line) Log("trace: " .. line) end or nil
end
function H.tracedump(t)
	Log("trace dump " .. tostring(t.name) .. ":")
	ABL.Trace.Dump(function(s) Log("   | " .. s) end, t.events or 0)
end

-- headsight old = true: a body's blood is drawn only if the LOD has the body in sight, as the
-- module had it before (the LOD looks five times a second); else as the module has it.
local sightOrig
function H.headsight(t)
	if sightOrig then
		hook.Add("PostDrawAppearance", "ABL_BodyBlood", sightOrig)
		sightOrig = nil
	end
	if not t.old then Log("headsight: as the module has it") return end
	local orig = (hook.GetTable().PostDrawAppearance or {}).ABL_BodyBlood
	if not orig then Log("headsight: no hook to wrap") return end
	sightOrig = orig
	hook.Add("PostDrawAppearance", "ABL_BodyBlood", function(ent, ply)
		local src = ABL.Sources.byBody and ABL.Sources.byBody[ent]
		if src and src.body == ent and not src.visible then
			src.appearFrame = FrameNumber()
			return
		end
		return orig(ent, ply)
	end)
	Log("headsight: as it was (a body the LOD has not in sight gets no blood, though the game draws it)")
end

-- t.follow: the camera goes with the head of that entity's body (t.dist in front of it, t.side
-- to its side, t.up above), set again every frame.
local cam
function H.headcam(t)
	if t.off then cam = nil return end
	-- (the harness's own camera stands aside while this one is set)
	H.view({})
	cam = { origin = t.pos or Vector(), angles = t.ang or Angle(), fov = t.fov or 60, drawviewer = t.viewer and true or false, znear = t.znear }
	cam.follow, cam.dist, cam.side, cam.up, cam.top = t.follow, t.dist or 30, t.side or 10, t.up or 3, t.top
end
hook.Add("CalcView", "ABL_HeadTestView", function()
	if not cam then return end
	if cam.follow then
		local ent = Entity(cam.follow)
		local body = IsValid(ent) and (ent:IsPlayer() and (ent:Alive() and Z.GetBody(ent) or Z.GetCorpse(ent)) or ent) or nil
		local b = IsValid(body) and body:LookupBone(HEAD) or nil
		local m = b and body:GetBoneMatrix(b) or nil
		if m then
			local p = m:GetTranslation() + Vector(0, 0, 3)
			local yaw = ent:IsPlayer() and ent:EyeAngles().y or body:GetAngles().y
			local f = Angle(0, yaw, 0):Forward()
			local r = Angle(0, yaw, 0):Right()
			local eye = p + f * cam.dist + r * cam.side + Vector(0, 0, cam.up)
			-- (a body that lies: from above)
			if cam.top then eye = p + Vector(cam.side * 0.5, cam.side * 0.3, cam.dist) end
			cam.origin, cam.angles = eye, (p - eye):Angle()
		end
	end
	return cam
end)

------------------------------------------------------------------------------------------
-- headz: the bones a body is drawn with, and the bones its film is drawn with.
-- Z-City sets bone matrices by hand before it draws a body (the head's, the hands'), and the film
-- is the same model drawn again a moment later (cl_filmdraw.lua). For one body the head bone's
-- matrix is read just before Z-City draws the body (its hook "CoolPostDrawAppearance"), as the
-- blood module's own hook is entered, and as its film is about to be drawn; the three are
-- compared, a line a second.
-- mode "restore": the matrices read before the body was drawn are set again before the film is
-- drawn; "setuprestore": the bones are set up anew first, and then those matrices set.
------------------------------------------------------------------------------------------
local zw
local function Rows(m) return { m:Unpack() } end
local function MaxDiff(a, b)
	local d = 0
	for i = 1, 12 do
		local x = math.abs(a[i] - b[i])
		if x > d then d = x end
	end
	return d
end
local function Scale(r) return sqrt(r[1] * r[1] + r[5] * r[5] + r[9] * r[9]) end
local function ZBody(ent)
	local z = zw
	if not z then return nil end
	local who = Entity(z.idx)
	if not IsValid(who) then return nil end
	local body = who:IsPlayer() and (who:Alive() and Z.GetBody(who) or Z.GetCorpse(who)) or who
	return body == ent and z or nil
end
local function ZSecond() return { t0 = RealTime(), n = 0, dAB = 0, dAD = 0, sA = 0, sB = 0, sD = 0, bonesAB = 0, restored = 0 } end

function H.headz(t)
	local D = ABL.FilmDraw
	if zw then
		hook.Remove("CoolPostDrawAppearance", "ABL_HeadZ")
		if zw.origHook then hook.Add("PostDrawAppearance", "ABL_BodyBlood", zw.origHook) end
		if zw.origOverlay then D.Overlay = zw.origOverlay end
		-- (what the modes "noflex" and "lod0" set on the body)
		if IsValid(zw.touched) then
			zw.touched:SetFlexScale(1)
			zw.touched:SetLOD(-1)
		end
		Log(string.format("headz %s ends", zw.name))
		zw = nil
	end
	if t.off then return end
	local z = { idx = t.ent, name = tostring(t.name or t.mode or "watch"), mode = t.mode or "watch", sec = ZSecond(), saved = {} }
	zw = z
	Log(string.format("headz %s begins on entity %d, mode %s", z.name, t.ent, z.mode))
	-- just before Z-City draws the body
	hook.Add("CoolPostDrawAppearance", "ABL_HeadZ", function(ent)
		local w = ZBody(ent)
		if not w then return end
		-- "noflex": the face's own shapes (blinking, the mouth) are taken off the body, for its own
		-- drawing and its film's alike; "lod0": both are drawn with the model's finest mesh.
		if w.mode == "noflex" and w.touched ~= ent then
			w.touched = ent
			ent:SetFlexScale(0)
		elseif w.mode == "lod0" and w.touched ~= ent then
			w.touched = ent
			ent:SetLOD(0)
		end
		local saved = w.saved
		for i = 0, ent:GetBoneCount() - 1 do saved[i] = ent:GetBoneMatrix(i) end
		w.bone = ent:LookupBone(HEAD)
		w.A = w.bone and saved[w.bone] and Rows(saved[w.bone]) or nil
		w.frameA = FrameNumber()
		if not w.said then
			w.said = true
			Log(string.format("headz %s: the body %s, model %s, model scale %.3f, %d flexes (flex scale %.2f), LOD asked %s, %d bones", w.name, tostring(ent), tostring(ent:GetModel()), ent:GetModelScale(),
				ent:GetFlexNum() or 0, ent:GetFlexScale() or -1, tostring(ent.GetLOD and ent:GetLOD()), ent:GetBoneCount() or 0))
		end
	end)
	local function Restore(w, ent)
		if w.frameA ~= FrameNumber() then return end
		if w.mode == "setuprestore" then ent:SetupBones() end
		for i, m in pairs(w.saved) do
			if m then ent:SetBoneMatrix(i, m) end
		end
		w.sec.restored = w.sec.restored + 1
	end
	-- as the blood module's own hook is entered
	z.origHook = (hook.GetTable().PostDrawAppearance or {}).ABL_BodyBlood
	if z.origHook then
		hook.Add("PostDrawAppearance", "ABL_BodyBlood", function(ent, ply)
			local w = ZBody(ent)
			if w and w.A and w.frameA == FrameNumber() and w.bone then
				local st = w.sec
				local m = ent:GetBoneMatrix(w.bone)
				if m then
					local B = Rows(m)
					st.n = st.n + 1
					st.dAB = math.max(st.dAB, MaxDiff(w.A, B))
					st.sA, st.sB = Scale(w.A), Scale(B)
					-- how many of all its bones are no longer what they were
					local nb = 0
					for i, sm in pairs(w.saved) do
						local now = sm and ent:GetBoneMatrix(i)
						if now and MaxDiff(Rows(sm), Rows(now)) > 1e-5 then nb = nb + 1 end
					end
					if nb > st.bonesAB then st.bonesAB = nb end
				end
			end
			return z.origHook(ent, ply)
		end)
	end
	-- as its film is about to be drawn
	z.origOverlay = D.Overlay
	D.Overlay = function(ent, ...)
		local w = ZBody(ent)
		if w and w.A and w.frameA == FrameNumber() and w.bone then
			local m = ent:GetBoneMatrix(w.bone)
			if m then
				local Dm = Rows(m)
				w.sec.dAD = math.max(w.sec.dAD, MaxDiff(w.A, Dm))
				w.sec.sD = Scale(Dm)
			end
			if w.mode == "restore" or w.mode == "setuprestore" then Restore(w, ent) end
		end
		return z.origOverlay(ent, ...)
	end
end
hook.Add("PostRender", "ABL_HeadZ", function()
	local z = zw
	if not z then return end
	local st = z.sec
	if RealTime() - st.t0 < 1 then return end
	Log(string.format("headz %s: %d drawings of the body in %.2f s | head bone before the body was drawn: scale %.3f; as the blood's hook is entered: scale %.3f, off by up to %.6f; as the film is drawn: scale %.3f, off by up to %.6f | bones no longer as they were at the hook: up to %d | restored %d time(s)",
		z.name, st.n, RealTime() - st.t0, st.sA, st.sB, st.dAB, st.sD, st.dAD, st.bonesAB, st.restored))
	z.sec = ZSecond()
end)

function H.headinfo(t)
	local lp = LocalPlayer()
	local parts = {}
	for _, name in ipairs({ "hg_thirdperson", "hg_gopro", "hg_ragdollcombat", "hg_firstperson_ragdoll", "hg_firstperson_death", "hg_cheats" }) do
		local cv = GetConVar(name)
		parts[#parts + 1] = name .. " " .. (cv and cv:GetString() or "(none)")
	end
	local rs, cv = hook.GetTable().RenderScene or {}, hook.GetTable().CalcView or {}
	Log(string.format("headinfo %s: screen %dx%d | view entity %s (the local player: %s) | Z-City's RenderScene hook %s, its CalcView hook %s | %s", tostring(t.name), ScrW(), ScrH(),
		tostring(GetViewEntity()), tostring(GetViewEntity() == lp), rs.jopa and "in place" or "not in place", cv["homigrad-view"] and "in place" or "not in place", table.concat(parts, ", ")))
	local names = {}
	for k in pairs(hook.GetTable()["Player Spawn"] or {}) do names[#names + 1] = tostring(k) end
	Log("headinfo: this client's hooks on \"Player Spawn\", in the order they are called: " .. table.concat(names, ", "))
end
