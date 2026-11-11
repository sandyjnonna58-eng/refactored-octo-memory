-- The ways between the respiratory module and the other systems of the body (server).
--
-- The brain (lua/neurotrauma). That module decides whether and how the brain drives breathing; it
-- is asked, never copied, and nothing here writes into it:
--     RS.Brain.Drive(org)          how much respiratory control is left (its st.resp), and its
--                                  breathing pattern by its own number and name
--     RS.Brain.RagdollBreath(ply)  the clock of the breath it gives an unconscious body (it moves
--                                  that body's chest itself: the respiratory clock then follows it)
--
-- Oxygen. There is one oxygen store and it is Z-City's. The brain module reads that store itself
-- and injures the brain when it runs low (its sv_brain.lua), so oxygen already reaches the brain,
-- by Z-City's store. Whoever adds another way for the same shortage to reach the same consumer
-- counts it twice. To keep that from happening unseen, every such way is entered here:
--     RS.Paths                     consumer -> quantity -> { via, owner, note }
--     RS.ClaimPath(consumer, quantity, via, owner)    refused while another way is entered
--     RS.ReleasePath(consumer, quantity, owner)
--     RS.Oxygen(who)               what the respiratory system offers a consumer: read-only
-- The module itself claims nothing beyond what stands below: it publishes, and whatever layer
-- joins the systems decides what the numbers do.

local RS = HemoRespiratory
RS.Brain = RS.Brain or {}
local BR = RS.Brain

local function NT() return istable(NeuroTrauma) and NeuroTrauma.Loaded == true and NeuroTrauma or nil end

function BR.Available() return NT() ~= nil end

-- control 0..1 (nil: the brain module has no record of this character, which means all of it),
-- the pattern's number, its name.
function BR.Drive(org)
	local nt = NT()
	if not nt or not isfunction(nt.Get) then return nil end
	local ok, st = pcall(nt.Get, org)
	if not ok or not istable(st) then return nil end
	local control = tonumber(st.resp)
	local pattern = tonumber(st.respPattern)
	local names = istable(nt.CardioResp) and nt.CardioResp.PatternNames
	return control, pattern, (pattern and istable(names) and names[pattern]) or nil
end

-- What kind of breathing one of the brain module's patterns is, by that module's own names for
-- them: "normal", "irregular" (broken up, with pauses, or by a convulsion), "gasping", "none".
function BR.PatternKind(pattern)
	local nt = NT()
	local P = nt and istable(nt.CardioResp) and nt.CardioResp.Pattern
	if not pattern or not istable(P) then return "normal" end
	if pattern == P.GASPING then return "gasping" end
	if pattern == P.IRREGULAR or pattern == P.PERIODIC or pattern == P.ICTAL then return "irregular" end
	if pattern == P.APNOEA or pattern == P.NONE then return "none" end
	return "normal"
end

-- breaths a second and the phase now (0 at the breath out), or nil when the brain module is not
-- moving this player's chest.
function BR.RagdollBreath(ply)
	local nt = NT()
	if not nt then return nil end
	local rag = IsValid(ply) and ply.FakeRagdoll
	local M, CM = nt.Motor, istable(nt.Config) and nt.Config.Motor
	if not IsValid(rag) or not istable(M) or not istable(M.ctlOf) or not istable(CM) then return nil end
	local ctl = M.ctlOf[rag]
	local hz = tonumber(CM.breathHz)
	if not istable(ctl) or not ctl.breath or not hz or hz <= 0 then return nil end
	-- (its own arithmetic: sv_motor.lua, Quiet)
	return hz, (CurTime() * hz + (tonumber(ctl.slot) or 0) * 0.37) % 1
end

------------------------------------------------------------------------------------------
-- Ways by which a quantity reaches a consumer
------------------------------------------------------------------------------------------
RS.Paths = RS.Paths or {}
RS.Paths.brain = RS.Paths.brain or {
	oxygen = { via = "zcity_store", owner = "neurotrauma", note = "the brain module reads Z-City's oxygen store itself (sv_brain.lua): a shortage is counted there, once" },
}

-- Enters a way. Returns true, or false and why (another way is entered for that consumer and
-- quantity: release it first, or the same effect is counted twice).
function RS.ClaimPath(consumer, quantity, via, owner, note)
	if not isstring(consumer) or not isstring(quantity) or not isstring(via) or not isstring(owner) then return false, "a consumer, a quantity, a way and an owner are needed" end
	RS.Paths[consumer] = RS.Paths[consumer] or {}
	local p = RS.Paths[consumer][quantity]
	if p and (p.via ~= via or p.owner ~= owner) then
		return false, string.format("%s already reaches %s by %s (entered by %s)", quantity, consumer, p.via, p.owner)
	end
	RS.Paths[consumer][quantity] = { via = via, owner = owner, note = note }
	return true
end

function RS.ReleasePath(consumer, quantity, owner)
	local p = RS.Paths[consumer] and RS.Paths[consumer][quantity]
	if not p then return true end
	if p.owner ~= owner then return false, "entered by " .. tostring(p.owner) end
	RS.Paths[consumer][quantity] = nil
	return true
end

-- What a consumer may take of a character's oxygen, read-only: shares of normal.
--   availability   Z-City's oxygen store, as a share of the full store
--   ceiling        what that store can hold now (air in the pleural space, blood lost, lungs damaged)
--   ventilation    how well the lungs load the blood now (Z-City's own factor; 0 while no air moves)
--   exchange       the same whether or not air moves: what the lungs could do
--   moving         air moved a minute against a breath at rest: 0 while no breath
--   falling        the store is being used faster than it is filled
function RS.Oxygen(who)
	local s = RS.Read(who)
	if not s then return nil end
	return { availability = s.oxygen.now, ceiling = s.oxygen.ceiling, ventilation = s.ventilation, exchange = s.exchange, moving = s.moving, falling = s.oxygen.falling, via = "zcity_store" }
end
