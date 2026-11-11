-- Client: the developer's drawing of a brain. brain_show_<mode> (superadmin, neuro_dev 1) asks the
-- server for the brain of the character under the crosshair (or one's own) and draws the atlas with
-- it, twice a second: three views side by side (left hemisphere from its side, the deep structures
-- and the hindbrain from above, right hemisphere from its side) and the list of channels.
--
--   anatomy       the regions by lobe
--   motor, language, visual, sensory
--                 the regions each group of functions runs on, by how much it leans on them
--   vascular      territories of the three cerebral arteries and the vertebrobasilar system, the
--                 vessel tree, shut vessels marked
--   damage        what is destroyed (filled) and what is only switched off (ring)
--   perfusion     where too little blood arrives
--   connectivity  the tracts and the regions they join, by how much of each tract is left
--   activation    what the character is using right now (moving, firing, typing, speaking), dimmed
--                 where the structure no longer works; it fades when the action stops
--
-- The drawing is a schematic (the positions of sh_atlas.lua), not an image of a brain. Nobody but
-- a developer who asked is sent anything, and the game does not use this drawing for anything.

NeuroTrauma.NoJIT()
local NT = NeuroTrauma
local A = NT.Atlas
local Clamp, max, min = math.Clamp, math.max, math.min

local mode = "off"
local data = nil
local act = {}            -- region id -> activation that fades
local tact = {}

net.Receive("nt_brainview", function()
	mode = net.ReadString()
	if mode == "off" then data = nil end
	-- (the window of cl_brain3d.lua opens and closes by this)
	hook.Run("NT_BrainViewMode", mode)
end)

local function ReadList(bits)
	local n = net.ReadUInt(8)
	local t = {}
	for _ = 1, n do
		local id = net.ReadUInt(bits)
		t[id] = net.ReadUInt(4) / 15
	end
	return t
end

net.Receive("nt_braindata", function()
	local d = { name = net.ReadString(), t = CurTime() }
	d.ent = net.ReadUInt(8)
	d.actions = net.ReadUInt(8)
	d.has = net.ReadBool()
	if d.has then
		d.dom = net.ReadBool() and "R" or "L"
		d.d, d.td, d.rs, d.ts = ReadList(8), ReadList(8), ReadList(8), ReadList(8)
		d.shut, d.low = ReadList(8), ReadList(8)
		local n = net.ReadUInt(8)
		d.ch, d.on = {}, {}
		for i = 1, n do
			d.ch[i] = net.ReadUInt(4) / 15
			d.on[i] = net.ReadBool()
		end
		-- stage by stage, and what arrives at the limbs (cl_signal.lua)
		d.stg, d.out = {}, {}
		for i = 1, n do
			local caps = {}
			for s = 1, net.ReadUInt(4) do caps[s] = net.ReadUInt(4) / 15 end
			d.stg[i] = caps
		end
		for _, k in ipairs({ "armL", "armR", "handL", "handR", "legL", "legR", "trunk", "balance" }) do d.out[k] = net.ReadUInt(4) / 15 end
		d.awake = net.ReadUInt(4) / 15
		d.moveQ = net.ReadUInt(4)
		-- what is in use lights up the structures it runs on
		local comp = A.compiled[d.dom]
		for i = 1, min(n, #comp) do
			if d.on[i] then
				for _, s in ipairs(comp[i].stages) do
					for _, it in ipairs(s.items) do
						local tbl = it[1] and tact or act
						tbl[it[2]] = max(tbl[it[2]] or 0, 0.35 + 0.65 * it[3])
					end
				end
			end
		end
	end
	data = d
end)

------------------------------------------------------------------------------------------
-- What each group of functions leans on (static, per dominant hemisphere)
------------------------------------------------------------------------------------------
local groupWeight = {}
local edges = {}
local function Group(dom, group)
	local key = dom .. group
	local w = groupWeight[key]
	if w then return w end
	w = {}
	local GROUPS = { motor = "motor", language = "language", sensory = "sensory", visual = "sensory" }
	for _, c in ipairs(A.compiled[dom]) do
		local take = c.group == GROUPS[group]
		if group == "visual" then take = string.find(c.base, "vision", 1, true) ~= nil end
		if group == "sensory" then take = c.group == "sensory" and not string.find(c.base, "vision", 1, true) end
		if take then
			for _, s in ipairs(c.stages) do
				for _, it in ipairs(s.items) do
					if not it[1] then w[it[2]] = max(w[it[2]] or 0, it[3]) end
				end
			end
		end
	end
	groupWeight[key] = w
	return w
end
-- tracts and what they join: a structure of one stage to the tract of the next
local function Edges(dom)
	local e = edges[dom]
	if e then return e end
	e = {}
	local seen = {}
	for _, c in ipairs(A.compiled[dom]) do
		for i = 1, #c.stages - 1 do
			for _, a in ipairs(c.stages[i].items) do
				for _, b in ipairs(c.stages[i + 1].items) do
					if a[1] ~= b[1] or (a[1] and b[1]) then
						local k = (a[1] and "t" or "r") .. a[2] .. ">" .. (b[1] and "t" or "r") .. b[2]
						if not seen[k] then
							seen[k] = true
							e[#e + 1] = { a[1], a[2], b[1], b[2] }
						end
					end
				end
			end
		end
	end
	edges[dom] = e
	return e
end

------------------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------------------
surface.CreateFont("NT_Brain", { font = "Consolas", size = 13, weight = 500, antialias = true })
surface.CreateFont("NT_BrainHead", { font = "Consolas", size = 16, weight = 700, antialias = true })

local unit = {}
for i = 0, 11 do
	local a = i / 12 * math.pi * 2
	unit[i + 1] = { math.cos(a), math.sin(a) }
end
local poly = {}
for i = 1, 12 do poly[i] = { x = 0, y = 0 } end
local function Disc(x, y, r, col)
	for i = 1, 12 do poly[i].x, poly[i].y = x + unit[i][1] * r, y + unit[i][2] * r end
	surface.SetDrawColor(col.r, col.g, col.b, col.a)
	draw.NoTexture()
	surface.DrawPoly(poly)
end

local LOBE = {
	frontal = Color(80, 130, 220), parietal = Color(90, 190, 110), temporal = Color(230, 150, 60), occipital = Color(170, 110, 220),
	insular = Color(70, 190, 190), limbic = Color(230, 120, 170), deep = Color(150, 150, 160), brainstem = Color(170, 120, 80), cerebellum = Color(220, 200, 80),
}
local MAJOR = { aca = Color(230, 90, 90), mca = Color(90, 200, 110), pca = Color(90, 140, 240), ica = Color(230, 210, 90), vb = Color(190, 110, 220) }
local GREY = Color(70, 72, 78, 200)

local function Mix(a, b, f)
	return Color(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 230)
end

-- where a structure is drawn: view 1 left hemisphere from the side, 2 from above, 3 right hemisphere
local function Place(o, view, x0, y0, w, h)
	if view == 2 then
		return x0 + w * 0.5 - o.x * w * 0.45, y0 + h * 0.5 - (o.y + 0.25) * h * 0.4
	end
	local fx = (o.y + 1) / 2
	if view == 1 then fx = 1 - fx end
	return x0 + w * (0.06 + 0.88 * fx), y0 + h * (1 - (o.z + 1.55) / 2.65)
end
local function ViewOf(o)
	if o.kind == "D" or o.kind == "B" or o.kind == "X" or o.side == "M" or o.dai then return 2 end
	return o.side == "L" and 1 or 3
end

local function RegionColour(r, d)
	local id = r.id
	if mode == "anatomy" then return LOBE[r.lobe] or GREY end
	if mode == "damage" then
		local dm = d.d[id] or 0
		return dm > 0.01 and Mix(GREY, Color(230, 50, 40), Clamp(dm * 1.2, 0.2, 1)) or GREY
	end
	if mode == "perfusion" then
		local low = d.low[id] or 0
		return Mix(Color(70, 120, 210), Color(15, 15, 20), low)
	end
	if mode == "vascular" then
		local best, share = nil, 0
		for key, s in pairs(r.supply) do
			if s > share then best, share = key, s end
		end
		local v = best and A.Vessel(best)
		return v and MAJOR[v.major] or GREY
	end
	if mode == "activation" then
		local a = (act[id] or 0) * (1 - (d.d[id] or 0)) * (1 - (d.rs[id] or 0))
		return Mix(GREY, Color(255, 230, 90), a)
	end
	if mode == "connectivity" then return GREY end
	local w = Group(d.dom, mode)[id]
	if not w then return GREY end
	local col = Mix(GREY, Color(90, 220, 140), Clamp(0.25 + w, 0, 1))
	local dm = d.d[id] or 0
	if dm > 0.05 then col = Mix(col, Color(230, 50, 40), dm) end
	return col
end

-- (for the other drawings of the same stream: cl_signal.lua)
NT.BrainView = { Mode = function() return mode end, Data = function() return data end }

hook.Add("HUDPaint", "NT_BrainView", function()
	if mode == "off" or mode == "signal" or mode == "3d" then return end
	local sw, sh = ScrW(), ScrH()
	local w, h = min(sw * 0.24, 470), min(sh * 0.4, 430)
	local x0, y0 = sw - (w * 3 + 40) - 250, 60
	surface.SetDrawColor(8, 9, 12, 242)
	surface.DrawRect(x0 - 10, y0 - 34, w * 3 + 40 + 250, h + 70)
	local d = data
	local title = string.format("brain: %s | %s", string.upper(mode), d and d.name or "waiting for the server (neuro_dev 1, superadmin)")
	draw.SimpleText(title, "NT_BrainHead", x0, y0 - 28, Color(150, 195, 255))
	if not d or CurTime() - d.t > 3 then return end
	if not d.has then
		draw.SimpleText("no neurological record (uninjured): the atlas as it is", "NT_Brain", x0, y0 - 8, color_white)
		d = { has = false, dom = "L", d = {}, td = {}, rs = {}, ts = {}, shut = {}, low = {}, ch = {}, on = {}, name = d.name, t = d.t }
	else
		draw.SimpleText("language-dominant hemisphere: " .. (d.dom == "L" and "left" or "right"), "NT_Brain", x0, y0 - 8, color_white)
	end
	local names = { "left hemisphere", "deep structures and hindbrain, from above (left on the left)", "right hemisphere" }
	local ox = { x0, x0 + w + 20, x0 + 2 * w + 40 }
	for v = 1, 3 do
		surface.SetDrawColor(30, 32, 38, 255)
		surface.DrawOutlinedRect(ox[v], y0 + 8, w, h)
		draw.SimpleText(names[v], "NT_Brain", ox[v] + 4, y0 + h + 10, Color(160, 160, 170))
	end
	-- fading of what was in use
	local fade = FrameTime() * 1.2
	for id, a in pairs(act) do act[id] = a > fade and a - fade or nil end
	for id, a in pairs(tact) do tact[id] = a > fade and a - fade or nil end

	-- tracts and what they join
	if mode == "connectivity" then
		for _, e in ipairs(Edges(d.dom)) do
			local a = e[1] and A.tracts[e[2]] or A.regions[e[2]]
			local b = e[3] and A.tracts[e[4]] or A.regions[e[4]]
			local va, vb = ViewOf(a), ViewOf(b)
			if va == vb then
				local ax, ay = Place(a, va, ox[va], y0 + 8, w, h)
				local bx, by = Place(b, vb, ox[vb], y0 + 8, w, h)
				local tid = e[3] and e[4] or (e[1] and e[2])
				local left = tid and (1 - (d.td[tid] or 0)) * (1 - (d.ts[tid] or 0)) or 1
				surface.SetDrawColor(60 + 170 * (1 - left), 60 + 150 * left, 80, 150)
				surface.DrawLine(ax, ay, bx, by)
			end
		end
	end
	-- vessels
	if mode == "vascular" or mode == "perfusion" then
		for _, v in ipairs(A.vessels) do
			if v.parentId then
				local p = A.vessels[v.parentId]
				local view = 2
				local ax, ay = Place(p, view, ox[view], y0 + 8, w, h)
				local bx, by = Place(v, view, ox[view], y0 + 8, w, h)
				local shut = d.shut[v.id] or 0
				local col = MAJOR[v.major] or GREY
				surface.SetDrawColor(col.r * (1 - shut) + 255 * shut, col.g * (1 - shut), col.b * (1 - shut), 220)
				surface.DrawLine(ax, ay, bx, by)
				if shut > 0.3 then Disc(bx, by, 4, Color(255, 40, 40, 255)) end
			end
		end
	end
	-- regions
	for _, r in ipairs(A.regions) do
		local view = ViewOf(r)
		local x, y = Place(r, view, ox[view], y0 + 8, w, h)
		local rad = max(r.radius * w * 0.2, 4)
		local col = RegionColour(r, d)
		Disc(x, y, rad, col)
		local off = d.rs[r.id] or 0
		if (mode == "damage" or mode == "perfusion") and off > 0.1 then
			surface.DrawCircle(x, y, rad + 2, 255, 170, 40, 255 * off)
		end
		if (d.d[r.id] or 0) > 0.3 and mode ~= "anatomy" then
			draw.SimpleText((string.gsub(r.base, "_", " ")), "NT_Brain", x, y - rad - 12, Color(255, 200, 190), TEXT_ALIGN_CENTER)
		end
	end
	-- tracts as small squares
	if mode == "connectivity" or mode == "damage" or mode == "activation" then
		for _, t in ipairs(A.tracts) do
			local x, y = Place(t, 2, ox[2], y0 + 8, w, h)
			local left = (1 - (d.td[t.id] or 0)) * (1 - (d.ts[t.id] or 0))
			if mode == "activation" then
				local a = (tact[t.id] or 0) * left
				surface.SetDrawColor(70 + 185 * a, 72 + 158 * a, 78, 230)
			else
				surface.SetDrawColor(60 + 180 * (1 - left), 70 + 150 * left, 90, 230)
			end
			surface.DrawRect(x - 3, y - 3, 7, 7)
		end
	end
	-- channels
	local comp = A.compiled[d.dom]
	local lx, ly = x0 + 3 * w + 52, y0 + 8
	draw.SimpleText("channels (in use: >)", "NT_Brain", lx, ly - 16, Color(160, 160, 170))
	local row = 0
	for i = 1, #comp do
		local v = d.ch[i] or 1
		local on = d.on[i]
		if v < 0.97 or on or #comp <= 40 then
			if ly + row * 13 > y0 + h + 20 then break end
			surface.SetDrawColor(40, 42, 48, 255)
			surface.DrawRect(lx + 132, ly + row * 13 + 2, 100, 9)
			surface.SetDrawColor(230 * (1 - v) + 40, 200 * v + 30, 60, 255)
			surface.DrawRect(lx + 132, ly + row * 13 + 2, 100 * v, 9)
			draw.SimpleText((on and "> " or "  ") .. comp[i].key, "NT_Brain", lx, ly + row * 13, on and Color(255, 230, 90) or color_white)
			row = row + 1
		end
	end
end)
