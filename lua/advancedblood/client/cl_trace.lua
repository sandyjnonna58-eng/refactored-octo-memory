-- Development diagnostics: what became of each wound, and of each character's blood, and why.
--
-- The blood of a character is the sum of things that begin and end at different moments: Z-City's
-- wounds come and go in its lists, a hit is told once, a body becomes another entity as its owner
-- falls, gets up or dies, a wound is anchored on the skin or is not, a limb is gone, a body is in
-- sight or is not drawn. When blood is where it should not be, or is not where it should be, the
-- question is which of these happened last. Each of them is written down here as it happens: one
-- line, with the character, the wound and the reason.
--   * the last 400 events are kept, whatever the settings (an event is a transition: there are a
--     few a second at most, and none while nothing changes);
--   * abl_debug with 1024 set prints them to the console as they come, a dozen a second at the
--     most (what is over that is counted and said once);
--   * abl_trace prints what there is now: every character with blood, each of its wounds (its
--     name, the part of the body, whether its place is valid and how it is held on the skin,
--     whether it bleeds, what happened to it last and why), and the last events;
--   * abl_trace_clear forgets the events.
-- Nothing is written per frame. A wound's name is the one cl_sources.lua gives it: Z-City's own
-- for an artery, else the bone and the place in its space to half a unit.

ABL.NoJIT()
ABL.Trace = ABL.Trace or {}
local TR = ABL.Trace
local C = ABL.Config

local SIZE = 400
TR.ring = TR.ring or {}
TR.count = TR.count or 0
local ring = TR.ring

local function Short(name) return (string.gsub(tostring(name), "ValveBiped%.Bip01_", "")) end
TR.Short = Short

local function Who(src)
	if not src then return "-" end
	local key, body = src.key, src.body
	local s = IsValid(key) and tostring(key) or "(an entity that is gone)"
	if IsValid(body) and body ~= key then s = s .. " as " .. tostring(body) end
	return s
end

local printed, printT, held = 0, 0, 0
local function Print(line)
	if bit.band(C.cl.debug:GetInt(), 1024) == 0 then return end
	local now = RealTime()
	if now - printT >= 1 then
		if held > 0 then MsgC(Color(255, 190, 120), string.format("[ABL trace] %d more event(s) in that second (abl_trace shows them)\n", held)) end
		printT, printed, held = now, 0, 0
	end
	if printed >= 12 then held = held + 1 return end
	printed = printed + 1
	MsgC(Color(255, 190, 120), "[ABL trace] " .. line .. "\n")
end

-- src: the character it happened to, or nil. wd: the wound, or nil. what: a few words. why: the
-- reason, or nil. The same thing happening to the same wound again within two seconds is counted
-- on the line it has.
function TR.Event(src, wd, what, why)
	local now = CurTime()
	local id = wd and wd.id or nil
	if wd then wd.trWhat, wd.trWhy, wd.trT = what, why, now end
	local last = TR.count > 0 and ring[(TR.count - 1) % SIZE + 1] or nil
	if last and last.src == src and last.id == id and last.what == what and last.why == why and now - last.t < 2 then
		last.n = last.n + 1
		last.t = now
		return
	end
	local e = { t = now, f = FrameNumber(), src = src, who = Who(src), id = id, bone = wd and wd.boneName or nil, what = what, why = why, n = 1 }
	ring[TR.count % SIZE + 1] = e
	TR.count = TR.count + 1
	Print(TR.Line(e))
	if TR.sink then TR.sink(TR.Line(e)) end
end

function TR.Line(e)
	return string.format("%.2f f%d | %s%s | %s%s%s", e.t, e.f, e.who, e.id and (" | wound " .. Short(e.id)) or "", e.what, e.why and (": " .. e.why) or "",
		e.n > 1 and string.format(" (%d times)", e.n) or "")
end

-- The last n events, oldest first.
function TR.Last(n)
	local out = {}
	local total = math.min(TR.count, SIZE)
	n = math.min(n or 40, total)
	for i = TR.count - n, TR.count - 1 do
		local e = ring[i % SIZE + 1]
		if e then out[#out + 1] = TR.Line(e) end
	end
	return out
end

-- Whether blood on a character's body is drawn, and if not why: looked at once a frame for the
-- frame before (cl_sources.lua S.Update), written down when it is no longer what it was.
-- ABL.Flow's hook says why it did not draw (src.skipWhy for frame src.skipFrame).
function TR.DrawState(src, frame)
	local st
	-- (the frame that was drawn last has this frame's number or the one before it, by where in
	-- the game's frame this is asked)
	if src.dsFrame and src.dsFrame >= frame - 1 then st = "drawn"
	elseif not IsValid(src.body) then st = "not drawn: it has no body just now"
	elseif src.skipFrame and src.skipFrame >= frame - 1 and src.skipWhy then st = "not drawn: " .. src.skipWhy
	elseif not src.visible then st = "not drawn: not in sight"
	else st = "not drawn: its body was not drawn" end
	if st ~= src.trDraw then
		src.trDraw = st
		TR.Event(src, nil, "blood on the body " .. st)
	end
end

------------------------------------------------------------------------------------------
-- What there is now
------------------------------------------------------------------------------------------
local function Finite(x) return x == x and x > -1e7 and x < 1e7 end

-- One wound: its name, the part of the body, its place, how it is held, whether it bleeds, what
-- happened to it last.
function TR.WoundLine(src, wd, now)
	local Z = ABL.ZC
	local part = Z.BoneLimb(wd.boneName or "") or "trunk"
	local place
	local ok, x, y, z = ABL.Emission.WoundFrame(src, wd)
	if not ok then
		place = "NO PLACE (its bone is not on this body)"
	elseif not (Finite(x) and Finite(y) and Finite(z)) then
		place = "PLACE INVALID (not a number)"
	else
		local c = IsValid(src.body) and src.body:WorldSpaceCenter() or nil
		local off = c and math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2 + (z - c.z) ^ 2) or 0
		local from = ""
		local b = wd.bone and src.pose:Bone(wd.bone)
		if b then from = string.format(", %.1f units from its bone", math.sqrt((x - b[4]) ^ 2 + (y - b[8]) ^ 2 + (z - b[12]) ^ 2)) end
		place = (off > 120 and string.format("PLACE INVALID (%.0f units from the body)", off) or "place valid") .. from
	end
	local hold
	if wd.tri and src.mesh and wd.tri <= src.mesh.nt then
		hold = (wd.mark and wd.mark.tri == wd.tri) and "held at its mark's opening" or "held on the skin"
	elseif not src.mesh then hold = "not held yet (the body's surface model is not there)"
	elseif wd.anchorTried then hold = "NOT HELD on the skin: bleeds from its place in the bone's space"
	else hold = "not held yet" end
	local state
	if wd.removed then state = "removed"
	elseif wd.hidden then state = "hidden, lets nothing out"
	elseif wd.closing then state = string.format("closing (response %.2f)", wd.resp or 0)
	elseif (wd.flow or 0) > 0.0005 then state = string.format("bleeding %.3f ml/s%s", wd.flow, wd.arterial and " (artery)" or "")
	else state = "open, nothing flowing" end
	return string.format("wound %s | %s (%s) | value %.1f | %s | %s | %s | %s%s | last: %s%s, %.1f s ago", Short(wd.id), Short(wd.boneName), part, wd.sev or 0, state, place, hold,
		wd.rec and "of a hit it knows" or "of no hit it knows", wd.mark and ", with a mark" or "", wd.trWhat or "?", wd.trWhy and (" (" .. wd.trWhy .. ")") or "", now - (wd.trT or wd.born or now))
end

function TR.Dump(out, events)
	out = out or print
	local S = ABL.Sources
	local now = CurTime()
	out(string.format("[ABL trace] %d character(s) with blood; %d event(s) so far", #S.list, TR.count))
	for _, src in ipairs(S.list) do
		local nm, nh = 0, 0
		for _, mk in ipairs(src.marks or {}) do
			nm = nm + 1
			if mk.hidden then nh = nh + 1 end
		end
		out(string.format("  %s | %s | LOD %s, %s, %.0f units | %d wound(s), %d mark(s) (%d hidden, %d waiting), film %d cells | blood on the body %s", Who(src), src.alive and "alive" or "dead",
			C.LODNames[src.lod] or "?", src.visible and "in sight" or "not in sight", (src.dist or 0) < 1e8 and src.dist or -1, #src.woundList, nm, nh,
			src.pendingMarks and #src.pendingMarks or 0, src.film and src.film.n or 0, src.trDraw or "?"))
		for _, wd in ipairs(src.woundList) do
			local ok, line = pcall(TR.WoundLine, src, wd, now)
			out("    " .. (ok and line or ("wound " .. tostring(wd.id) .. ": " .. tostring(line))))
		end
	end
	local last = TR.Last(events or 40)
	out(string.format("  the last %d event(s):", #last))
	for _, l in ipairs(last) do out("    " .. l) end
end

concommand.Add("abl_trace", function(_, _, args)
	TR.Dump(function(s) MsgC(Color(255, 190, 120), s .. "\n") end, tonumber(args[1]) or 40)
end, nil, "AdvancedBlood: every character with blood and each of its wounds (place, hold, state, what happened to it last and why), and the last events [how many]")

concommand.Add("abl_trace_clear", function()
	for i = 1, SIZE do ring[i] = nil end
	TR.count = 0
	ABL.Print("trace: events forgotten")
end, nil, "AdvancedBlood: forget the events abl_trace shows")
