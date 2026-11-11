-- Developer commands for the anatomical layer and the canned test actions. All need neuro_dev 1
-- and a superadmin (or the listen-server host / console): sv_debug.lua, D.Allowed.
--
--   brain_inspect [target]                      the damaged structures, the vessels, the channels
--   brain_regions [text]                        the regions of the atlas (filtered by text)
--   brain_vessels [target]                      the vessel tree, with what reaches each vessel
--   brain_activate <channel>                    which structures a function runs through
--   brain_damage_region <target> <key> [amount] add damage to a region or tract (default 1)
--   brain_damage_vessel <target> <key> [open]   set how open a vessel is (default 0: shut)
--   brain_disable_function <target> <channel>   destroy the first stage of a function
--   brain_test_typing <target> <text...>        what that character would make of the text
--   brain_test_wasd [target]                    what its body can do with the movement keys
--   brain_trace <target> [action]               the signal of an action stage by stage, from the
--                                               intention to what the limb does (walk, run, jump,
--                                               attack, aim, use, typing, speaking; default: all)
--   brain_reset [target]                        forget the injury
--   brain_export                                write the atlas as documents into data/neurotrauma/
--   brain_show_motor | language | visual | vascular | connectivity | perfusion | damage |
--   anatomy | activation | off                  the developer's drawing (cl_brainview.lua)
--   brain_show_signal [target]                  the same trace, live, for what the character is
--                                               doing right now (cl_signal.lua)
--   brain_show_3d [target]                      the brain as a body that can be turned and asked
--                                               about (cl_brain3d.lua; brain_view on the client)
--
--   neuro_test_<fall | headimpact | rotation | projectile | unconscious | seizure | postictal |
--   posturing | cardiac_arrest | cpr | rosc | midazolam | recovery | network | animation |
--   performance> [target] [arguments]           one canned action each, through the public calls

local NT = NeuroTrauma
local D = NT.Debug
local C, Z, E, A = NT.Config, NT.ZC, NT.E, NT.Atlas
local BR, AN, VA = NT.Brain, NT.Anatomy, NT.Vascular
local Reply = D.Reply

local function Cmd(name, fn)
	concommand.Add(name, function(ply, _, args)
		if not D.Allowed(ply) then return end
		fn(ply, args)
	end)
end

local function Who(ply, token)
	local target = D.Target(ply, token)
	local org = IsValid(target) and Z.Org(target)
	if not org then Reply(ply, "[NeuroTrauma] no such character") return nil end
	return target, org
end

Cmd("brain_inspect", function(ply, args)
	local target, org = Who(ply, args[1])
	if not target then return end
	local st = NT.Get(org)
	if not st then return Reply(ply, "[NeuroTrauma] %s: no neurological record (uninjured)", target:Nick()) end
	local an = st.an
	Reply(ply, "[NeuroTrauma] %s | language-dominant hemisphere: %s | collaterals over the surface %.2f", target:Nick(), an.dom == "L" and "left" or "right", an.lepto)
	for _, l in ipairs(AN.Lesions(st, 40)) do Reply(ply, "   %-58s %s %.2f", l[1], l[3] and "tract " or "region", l[2]) end
	Reply(ply, "   %s", VA.Describe(st))
	local ch, why = AN.Channels(st)
	local keys = {}
	for k in pairs(ch) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		if ch[k] < 0.995 and not string.find(k, "neglect", 1, true) then Reply(ply, "   %-24s %.2f  (limited by: %s)", k, ch[k], tostring(why[k] or "-")) end
	end
end)

Cmd("brain_regions", function(ply, args)
	local filter = args[1] and string.lower(args[1])
	for _, r in ipairs(A.regions) do
		if not filter or string.find(string.lower(r.key .. " " .. r.name .. " " .. r.lobe), filter, 1, true) then
			local sup = {}
			for k, v in pairs(r.supply) do sup[#sup + 1] = string.format("%s %.0f%%", k, v * 100) end
			table.sort(sup)
			Reply(ply, "%-28s %-60s %-10s BA %-6s supply: %s", r.key, r.name, r.lobe, r.brodmann ~= "" and r.brodmann or "-", table.concat(sup, ", "))
		end
	end
end)

Cmd("brain_vessels", function(ply, args)
	local target, org = Who(ply, args[1])
	local st = target and NT.Get(org)
	if st and not st.an.deliv[1] then VA.Flow(st.an) end
	local function Line(v, depth)
		local reach = st and st.an.deliv[v.id] or 1
		local open = st and (st.an.pat[v.id] or 1) or 1
		Reply(ply, "%s%-52s %-28s open %3.0f%%  receives %3.0f%%", string.rep("  ", depth), v.name, v.key, open * 100, reach * 100)
		for _, c in ipairs(v.children) do Line(A.vessels[c], depth + 1) end
	end
	for _, v in ipairs(A.vessels) do if not v.parentId then Line(v, 0) end end
end)

Cmd("brain_activate", function(ply, args)
	local key = args[1]
	local found = false
	for _, c in ipairs(AN.compiled.L) do
		if c.key == key or c.base == key then
			found = true
			Reply(ply, "[NeuroTrauma] %s (language on the left):", c.key)
			for i, s in ipairs(c.stages) do
				local parts = {}
				for _, it in ipairs(s.items) do
					parts[#parts + 1] = string.format("%s %.0f%%", it[1] and A.tracts[it[2]].name or A.regions[it[2]].name, it[3] * 100)
				end
				Reply(ply, "   stage %d: %s (reserve %.0f%%): %s", i, s.name, s.reserve * 100, table.concat(parts, ", "))
			end
		end
	end
	if not found then
		local names = {}
		for _, def in ipairs(A.channels) do names[#names + 1] = def.key .. (def.sides and "L/R" or "") end
		Reply(ply, "[NeuroTrauma] channels: %s", table.concat(names, ", "))
	end
end)

Cmd("brain_damage_region", function(ply, args)
	local target = Who(ply, args[1])
	if not target or not args[2] then return Reply(ply, "[NeuroTrauma] brain_damage_region <target> <key> [amount]") end
	if not NT.DamageRegion(target, args[2], tonumber(args[3]) or 1) then Reply(ply, "[NeuroTrauma] unknown region or tract (see brain_regions)") end
end)

Cmd("brain_damage_vessel", function(ply, args)
	local target = Who(ply, args[1])
	if not target or not args[2] then return Reply(ply, "[NeuroTrauma] brain_damage_vessel <target> <key> [open 0..1]") end
	if not NT.DamageVessel(target, args[2], tonumber(args[3]) or 0) then Reply(ply, "[NeuroTrauma] unknown vessel (see brain_vessels)") end
end)

-- Destroys what the first stage of a channel runs on (the cortex of a function).
function D.DisableFunction(target, key)
	local org = Z.Org(target)
	if not org then return false end
	local st = BR.Ensure(org)
	for _, c in ipairs(AN.compiled[st.an.dom]) do
		if c.key == key then
			for _, it in ipairs(c.stages[1].items) do
				if it[1] then AN.DamageTract(st, it[2], 1) else AN.DamageRegion(st, it[2], 1) end
			end
			st.quiet = false
			NT.States.Push(st, target, "function disabled by hand: " .. key)
			return true
		end
	end
	return false
end

Cmd("brain_disable_function", function(ply, args)
	local target = Who(ply, args[1])
	if not target or not args[2] then return Reply(ply, "[NeuroTrauma] brain_disable_function <target> <channel> (see brain_activate)") end
	if not D.DisableFunction(target, args[2]) then Reply(ply, "[NeuroTrauma] unknown channel") end
end)

Cmd("brain_test_typing", function(ply, args)
	local target, org = Who(ply, args[1])
	if not target then return end
	local text = table.concat(args, " ", 2)
	if text == "" then text = "the quick brown fox jumps over the lazy dog near the old bridge" end
	local st = NT.Get(org)
	if not st then return Reply(ply, "[NeuroTrauma] no record: '%s'", text) end
	local p = NT.Language.Profile(st)
	Reply(ply, "[NeuroTrauma] non-fluent %.2f fluent %.2f conduction %.2f spelling %.2f typing %.2f confusion %.2f | speech %.2f", p.nonfluent, p.fluent, p.conduction, p.spelling, p.typing, p.confusion, p.speech)
	for i = 1, 3 do
		local out, did = NT.Language.Transform(st, text, 1000 + i)
		Reply(ply, "   '%s'%s", out, did and ("   [" .. did .. "]") or "   [unchanged]")
	end
end)

Cmd("brain_test_wasd", function(ply, args)
	local target, org = Who(ply, args[1])
	if not target then return end
	local st = NT.Get(org)
	if not st then return Reply(ply, "[NeuroTrauma] no record: every key does what it says") end
	local run, jump, fire, aim, veer = NT.Limits(target)
	Reply(ply, "[NeuroTrauma] %s: walking at %d/15 of normal speed | may run %s, jump %s, pull the trigger %s, aim a long weapon %s | pulled %s",
		target:Nick(), st.moveQ or 15, tostring(run), tostring(jump), tostring(fire), tostring(aim),
		(veer or 0) == 0 and "nowhere" or string.format("to the %s (%d of 3)", veer > 0 and "left" or "right", math.abs(veer)))
	Reply(ply, "   legs L %.2f R %.2f | hands L %.2f R %.2f | balance %.2f | coordination L %.2f R %.2f", st.legL, st.legR, st.handL, st.handR, st.balance, st.coordL, st.coordR)
end)

Cmd("brain_reset", function(ply, args)
	local target = Who(ply, args[1])
	if target then NT.Reset(target) end
end)

-- the developer's drawing: the mode is the client's; the server only needs to know whom to send to
for _, mode in ipairs({ "anatomy", "motor", "language", "visual", "sensory", "vascular", "damage", "perfusion", "connectivity", "activation", "signal", "3d", "off" }) do
	Cmd("brain_show_" .. mode, function(ply, args)
		if not IsValid(ply) then return end
		net.Start("nt_brainview")
		net.WriteString(mode)
		net.Send(ply)
		D.brainWatch = D.brainWatch or {}
		-- (whom to show: the character under the crosshair, or the one named)
		D.brainWatch[ply] = mode ~= "off" and (args[1] or "aim") or nil
	end)
end

------------------------------------------------------------------------------------------
-- What the watched brain looks like, for the drawing: sparse lists, twice a second, to the
-- developers who asked for it and to nobody else.
------------------------------------------------------------------------------------------
util.AddNetworkString("nt_brainview")
util.AddNetworkString("nt_braindata")

-- What the character is trying to do right now: the channels in use, and the actions as bits in
-- the order of A.actions.
local ACTION = {}
for i, a in ipairs(A.actions) do ACTION[a.key] = i end
function D.Activity(target)
	local out, bits = {}, 0
	if not IsValid(target) or not target:IsPlayer() then return out, bits end
	local function On(key)
		local i = ACTION[key]
		bits = bit.bor(bits, bit.lshift(1, i - 1))
		for _, k in ipairs(A.actions[i].channels) do out[k] = true end
	end
	if target:KeyDown(IN_FORWARD) or target:KeyDown(IN_BACK) or target:KeyDown(IN_MOVELEFT) or target:KeyDown(IN_MOVERIGHT) or target:GetVelocity():Length2D() > 20 then On("walk") end
	if target:KeyDown(IN_SPEED) then On("run") end
	if target:KeyDown(IN_JUMP) then On("jump") end
	if target:KeyDown(IN_ATTACK) then On("attack") end
	if target:KeyDown(IN_ATTACK2) then On("aim") end
	if target:KeyDown(IN_USE) then On("use") end
	if target.GetNetVar and target:GetNetVar("bIsTyping") then On("typing") end
	if target.IsSpeaking and target:IsSpeaking() then On("speaking") end
	return out, bits
end

-- The signal of one action stage by stage, in words: from the intention through cortex, the
-- descending fibres and the cord to what the limb does, and what the game makes of that.
local LIMB = { legL = "legL", legR = "legR", armL = "armL", armR = "armR", handL = "handL", handR = "handR", trunk = "trunk", balance = "balance" }
function D.TraceLines(target, key)
	local lines = {}
	local org = Z.Org(target)
	local st = org and NT.Get(org)
	for _, a in ipairs(A.actions) do
		if not key or key == "all" or a.key == key then
			lines[#lines + 1] = string.format("%s (%s)", string.upper(a.name), a.keys)
			if not st then
				lines[#lines + 1] = "   no neurological record: every stage carries 100%, the output is 100%"
			else
				local awake = st.effective or st.consciousness or 1
				for _, ck in ipairs(a.out) do
					local stages, value = AN.Trace(st, ck)
					if stages then
						local parts = { string.format("intention %.0f%%", (awake >= 0.4 and 1 or awake / 0.4) * 100) }
						for _, s in ipairs(stages) do parts[#parts + 1] = string.format("%s %.0f%%", s[1], s[2] * 100) end
						local out = LIMB[ck] and st[LIMB[ck]] or value
						lines[#lines + 1] = string.format("   %-26s %s", A.channelNames[ck] or ck, table.concat(parts, " > "))
						lines[#lines + 1] = string.format("   %-26s signal %.0f%% => output %.0f%%%s", "", value * 100, out * 100,
							(LIMB[ck] and math.abs(out - value) > 0.02) and " (after how readily a movement starts, and pressure on the pathway)" or "")
					end
				end
				if a.key == "walk" or a.key == "run" or a.key == "jump" then
					local run, jump = NT.Limits(target)
					lines[#lines + 1] = string.format("   => walking at %d/15 of normal speed; may run: %s; may jump: %s; on its feet: %s", st.moveQ or 15, tostring(run ~= false), tostring(jump ~= false),
						tostring(target:IsPlayer() and not IsValid(target.FakeRagdoll)))
				elseif a.key == "attack" or a.key == "aim" then
					local _, _, fire, aim = NT.Limits(target)
					lines[#lines + 1] = string.format("   => may pull the trigger: %s; may aim a long weapon: %s", tostring(fire ~= false), tostring(aim ~= false))
				end
			end
		end
	end
	return lines
end

Cmd("brain_trace", function(ply, args)
	local target = Who(ply, args[1])
	if not target then return end
	Reply(ply, "[NeuroTrauma] %s: the signal of %s", target:Nick(), args[2] or "every action")
	for _, l in ipairs(D.TraceLines(target, args[2])) do Reply(ply, "%s", l) end
end)

local OUTPUTS = { "armL", "armR", "handL", "handR", "legL", "legR", "trunk", "balance" }
local function Q15(v) return math.Clamp(math.floor((v or 1) * 15 + 0.5), 0, 15) end

timer.Create("NT_BrainView", 0.5, 0, function()
	local watch = D.brainWatch
	if not watch or next(watch) == nil then return end
	for ply in pairs(watch) do
		if not IsValid(ply) or not D.Allowed(ply) then
			watch[ply] = nil
		else
			local target = D.Target(ply, watch[ply])
			local org = IsValid(target) and Z.Org(target)
			local st = org and NT.Get(org)
			net.Start("nt_braindata")
			net.WriteString(IsValid(target) and target:Nick() or "-")
			net.WriteUInt(IsValid(target) and target:IsPlayer() and target:EntIndex() or 0, 8)
			local act, bits = D.Activity(target)
			net.WriteUInt(bits, 8)
			net.WriteBool(st ~= nil)
			if st then
				local an = st.an
				net.WriteBool(an.dom == "R")
				local function List(map, bits)
					local n = 0
					for _, v in pairs(map) do if v > 0.01 then n = n + 1 end end
					net.WriteUInt(math.min(n, 255), 8)
					local k = 0
					for id, v in pairs(map) do
						if v > 0.01 and k < 255 then
							k = k + 1
							net.WriteUInt(id, bits)
							net.WriteUInt(math.Clamp(math.floor(v * 15 + 0.5), 0, 15), 4)
						end
					end
				end
				List(an.d, 8) List(an.td, 8) List(an.rs, 8) List(an.ts, 8)
				local shut = {}
				for id, p in pairs(an.pat) do shut[id] = 1 - p end
				List(shut, 8)
				local low = {}
				for id, p in pairs(an.perf) do low[id] = 1 - p end
				List(low, 8)
				-- channels and what the character is doing with them
				local ch = AN.Channels(st)
				local comp = AN.compiled[an.dom]
				net.WriteUInt(#comp, 8)
				for i = 1, #comp do
					net.WriteUInt(math.Clamp(math.floor(ch[comp[i].key] * 15 + 0.5), 0, 15), 4)
					net.WriteBool(act[comp[i].key] == true)
				end
				-- stage by stage (the trace), and what arrives at the limbs
				for i = 1, #comp do
					local caps = an.stg[comp[i].key]
					local n = #comp[i].stages
					net.WriteUInt(n, 4)
					for s = 1, n do net.WriteUInt(Q15(caps and caps[s]), 4) end
				end
				for _, k in ipairs(OUTPUTS) do net.WriteUInt(Q15(st[k]), 4) end
				net.WriteUInt(Q15(st.effective or st.consciousness), 4)
				net.WriteUInt(st.moveQ or 15, 4)
			end
			D.streamBytes = net.BytesWritten()
			net.Send(ply)
		end
	end
end)

------------------------------------------------------------------------------------------
-- The atlas as documents: written from the data, so the documents cannot drift from the code.
------------------------------------------------------------------------------------------
function D.Export()
	file.CreateDir("neurotrauma")
	local function W(name, lines) file.Write("neurotrauma/" .. name, table.concat(lines, "\n") .. "\n") end
	local out = { "| Key | Name | Lobe | Kind | Brodmann | Hypoxia | Seizure | Border zone | Supply |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |" }
	local KIND = { C = "cortex", D = "deep grey", B = "brainstem", X = "cerebellum" }
	for _, r in ipairs(A.regions) do
		if r.side ~= "R" then
			local sup = {}
			-- (a structure of one side: its own side's vessels, without the prefix; one on the midline
			-- is fed from both sides and keeps them)
			for k, v in pairs(r.supply) do sup[#sup + 1] = string.format("%s %.0f %%", r.side ~= "M" and string.gsub(k, "^L_", "") or k, v * 100) end
			table.sort(sup)
			out[#out + 1] = string.format("| `%s` | %s | %s | %s | %s | %.1f | %.1f | %s | %s |", string.gsub(r.key, "^L_", ""), string.gsub(r.name, "^left ", ""),
				r.lobe, KIND[r.kind], r.brodmann ~= "" and r.brodmann or "-", r.hypoxia, r.seizure, r.watershed and "yes" or "", table.concat(sup, ", "))
		end
	end
	W("regions.txt", out)
	out = { "| Key | Name | Share lost to a full diffuse injury | Supply |", "| --- | --- | --- | --- |" }
	for _, t in ipairs(A.tracts) do
		if t.side ~= "R" then
			local sup = {}
			for k, v in pairs(t.supply) do sup[#sup + 1] = string.format("%s %.0f %%", t.side ~= "M" and string.gsub(k, "^L_", "") or k, v * 100) end
			table.sort(sup)
			out[#out + 1] = string.format("| `%s` | %s | %.0f %% | %s |", string.gsub(t.key, "^L_", ""), string.gsub(t.name, "^left ", ""), t.dai * C.Anatomy.daiTract * 100, table.concat(sup, ", "))
		end
	end
	W("tracts.txt", out)
	out = { "| Key | Name | Fed by | Kind | Feeds |", "| --- | --- | --- | --- | --- |" }
	local VK = { T = "stem", S = "segment", C = "cortical branch", P = "perforator (end artery)", W = "circle of Willis" }
	for _, v in ipairs(A.vessels) do
		if v.side == "L" then
			local feeds = {}
			for _, r in ipairs(A.regions) do if r.supply[v.key] then feeds[#feeds + 1] = string.format("%s %.0f %%", string.gsub(r.name, "^left ", ""), r.supply[v.key] * 100) end end
			for _, t in ipairs(A.tracts) do if t.supply[v.key] then feeds[#feeds + 1] = string.format("%s %.0f %%", string.gsub(t.name, "^left ", ""), t.supply[v.key] * 100) end end
			out[#out + 1] = string.format("| `%s` | %s | %s | %s | %s |", string.gsub(v.key, "^L_", ""), string.gsub(v.name, "^left ", ""),
				v.parent and ("`" .. string.gsub(v.parent, "^L_", "") .. "`") or "-", VK[v.kind], #feeds > 0 and table.concat(feeds, "; ") or "-")
		end
	end
	W("vessels.txt", out)
	out = { "| Channel | Stage | Reserve | Runs on |", "| --- | --- | --- | --- |" }
	local seen = {}
	for _, c in ipairs(AN.compiled.L) do
		if not seen[c.base] and (c.side == nil or c.side == "R") then
			seen[c.base] = true
			for i, s in ipairs(c.stages) do
				local parts = {}
				for _, it in ipairs(s.items) do parts[#parts + 1] = string.format("%s %.0f %%", it[1] and A.tracts[it[2]].name or A.regions[it[2]].name, it[3] * 100) end
				out[#out + 1] = string.format("| %s | %d. %s | %.0f %% | %s |", i == 1 and ("`" .. c.base .. "`" .. (c.side and " (right body side / right field; language on the left)" or "")) or "", i, s.name, s.reserve * 100, table.concat(parts, "; "))
			end
		end
	end
	W("channels.txt", out)
	return #A.regions, #A.tracts, #A.vessels, #AN.compiled.L
end

concommand.Add("brain_export", function(ply)
	if not D.Allowed(ply) then return end
	local r, t, v, c = D.Export()
	Reply(ply, "[NeuroTrauma] written to data/neurotrauma/: %d regions, %d tracts, %d vessels, %d channels", r, t, v, c)
end)

------------------------------------------------------------------------------------------
-- Canned test actions
------------------------------------------------------------------------------------------
local TESTS = {
	fall = function(t, a) return NT.ApplyImpact(t, { rotation = tonumber(a[1]) or 13, contact = tonumber(a[2]) or 6, region = "back", mechanism = "fall" }) end,
	headimpact = function(t, a) return NT.ApplyImpact(t, { rotation = tonumber(a[1]) or 9, contact = tonumber(a[2]) or 9, region = a[3] or "left", side = (a[3] or "left") == "right" and -1 or 1 }) end,
	rotation = function(t, a) return NT.ApplyImpact(t, { rotation = tonumber(a[1]) or 24, contact = 0, mechanism = "whiplash" }) end,
	projectile = function(t, a)
		-- a track straight through from one temple to the other, or front to back
		local org = Z.Org(t)
		local way = a[1] or "side"
		local A1 = way == "front" and { 0.3, 1, 0.2 } or { 1, 0.1, 0.2 }
		local B1 = way == "front" and { 0.3, -1, 0.1 } or { -1, 0.0, 0.2 }
		local ev = { id = 0, t = CurTime(), seed = math.random(1, 2147483646), ply = t, org = org, body = Z.Body(t), mech = E.Mech.PROJECTILE,
			measured = false, region = way == "front" and E.Region.FRONT or E.Region.LEFT, lat = way == "front" and 0.3 or 1, hit = A1,
			rot = 0, contact = 0, rotEff = 0, contactEff = 0, landing = 0, awake = 1, shield = 0, pen = E.Pen.PERFORATING,
			zones = way == "front" and E.Zone.LEFT or (E.Zone.LEFT + E.Zone.RIGHT + E.Zone.DEEP), energy = tonumber(a[2]) or 500, trackA = A1, trackB = B1 }
		ev.synthetic = true
		NT.ProcessTraumaEvent(t, ev)
		return true
	end,
	unconscious = function(t, a) return NT.SetUnconscious(t, tonumber(a[1]) or 15) end,
	seizure = function(t, a)
		local kind = a[1] or "tonic_clonic"
		local o = { focal = false, tonic = true, clonic = true, status = false }
		if kind == "focal" then o = { focal = true, aware = true, spread = false }
		elseif kind == "impaired" then o = { focal = true, aware = false, spread = false }
		elseif kind == "tonic" then o = { focal = false, tonic = true, clonic = false, status = false }
		elseif kind == "clonic" then o = { focal = false, tonic = false, clonic = true, status = false }
		elseif kind == "status" then o = { focal = false, tonic = true, clonic = true, status = true } end
		return NT.TriggerSeizure(t, o)
	end,
	postictal = function(t)
		local st = BR.Ensure(Z.Org(t))
		NT.Seizure.Force(t, st, CurTime(), { { "postictal", 40 } }, 1, true)
		return true
	end,
	posturing = function(t, a)
		NT.SetUnconscious(t, 60)
		return NT.SetPosturing(t, a[1] or "extensor", tonumber(a[2]) or 1, 45)
	end,
	cardiac_arrest = function(t, a) return Cardio.TriggerArrest(t, a[1] or "triggered") end,
	cpr = function(t)
		-- what Z-City's compressions do to its own numbers, thirty of them, two a second
		local org = Z.Org(t)
		local n = 0
		timer.Create("NT_TestCPR" .. t:EntIndex(), 0.5, 30, function()
			if not IsValid(t) or not istable(org) or org.alive == false then return end
			n = n + 1
			org.pulse = math.min((tonumber(org.pulse) or 0) + 5, 70)
			if org.pulse > 15 and n >= 20 then org.heartstop = false end
		end)
		return true
	end,
	rosc = function(t, a) return Cardio.AttemptROSC(t, tonumber(a[1]) or 1) end,
	midazolam = function(t) return NT.AdministerMedication(t, "midazolam") end,
	recovery = function(t, a) return NT.AttemptRecovery(t, tonumber(a[1]) or 1) ~= false end,
	network = function(t, a, ply)
		local N = NT.Net
		Reply(ply, "[NeuroTrauma] state messages %d (%d bytes), owner messages %d (%d bytes), records %d", N.messages, N.bytes, N.selfMessages, N.selfBytes, BR.count)
		return true
	end,
	animation = function(t, a)
		-- one side weak, the other clumsy, enough to see every standing layer
		NT.DamageRegion(t, "R_precentral_hand", 1) NT.DamageRegion(t, "R_precentral_arm", 0.9) NT.DamageRegion(t, "R_paracentral", 0.6)
		NT.DamageRegion(t, "R_cerebellum_sup", 0.9) NT.DamageRegion(t, "R_cerebellum_inf", 0.9)
		return true
	end,
	performance = function(t, a, ply)
		local n = 2000
		local st = BR.Ensure(Z.Org(t))
		local t0 = SysTime()
		for _ = 1, n do st.an.dirty = true AN.Compute(st) end
		local t1 = SysTime()
		for _ = 1, n do BR.Derive(st, CurTime()) end
		local t2 = SysTime()
		st.an.flowDirty = true
		for _ = 1, n do VA.Flow(st.an) end
		local t3 = SysTime()
		Reply(ply, "[NeuroTrauma] per call: channels %.1f us, function %.1f us, blood flow %.1f us | records %d", (t1 - t0) / n * 1e6, (t2 - t1) / n * 1e6, (t3 - t2) / n * 1e6, BR.count)
		return true
	end,
}
D.Tests = TESTS

for name, fn in pairs(TESTS) do
	Cmd("neuro_test_" .. name, function(ply, args)
		local target = Who(ply, args[1])
		if not target then return end
		local rest = {}
		for i = 2, #args do rest[#rest + 1] = args[i] end
		local ok = fn(target, rest, ply)
		Reply(ply, "[NeuroTrauma] neuro_test_%s on %s: %s", name, target:Nick(), ok and "done" or "refused")
	end)
end
