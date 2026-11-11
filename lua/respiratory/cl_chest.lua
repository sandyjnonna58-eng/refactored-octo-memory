-- Client: Z-City's visible breath, on the server's clock.
--
-- Z-City makes the breath one sees (the chest bone grows and shrinks, a breath is heard) from a
-- clock each client runs for itself: two players do not see the same breath, and nothing on the
-- server knows where in a breath anybody is. Here that clock is set, before Z-City reads it each
-- frame, from the respiratory module's: the chest, the sound and the lungs of the developer view
-- are then one breath, the same on every screen. Z-City's own code draws the chest as it always
-- did, with its own size of movement; nothing of it is replaced.
--
-- resp_zcity_chest 0 (or the module switched off, or no clock for a body): Z-City's clock runs on
-- by itself from wherever it stands, exactly as shipped.

local RS = HemoRespiratory
RS.NoJIT()
local C, CK, CL = RS.Config, RS.Clock, RS.CL
RS.Chest = RS.Chest or {}
local CH = RS.Chest
CH.stats = CH.stats or { set = 0 }
local asin, min = math.asin, math.min

-- (Z-City's handler works on ent.organism, and calls this hook for every player and ragdoll it draws)
hook.Add("Player-Ragdoll think", "RS_Chest", function(_, ent)
	if RS.Quiet or not C.sv.chest:GetBool() or not C.sv.enabled:GetBool() then return end
	local org = IsValid(ent) and ent.organism
	if not istable(org) then return end
	local c = CL.ClockOf(ent)
	if not c then return end
	local vl, vr, depth = CL.Fill(c, CurTime())
	-- (a breath shallower than a quiet one moves the chest less; a deeper one cannot move it more
	-- than Z-City's own movement goes)
	local v = (vl + vr) * 0.5 * min(depth, 1)
	-- Z-City shows (sin(clock) + 1) / 2
	org.pulsethink = asin(CK.Clamp(2 * v - 1, -1, 1))
	CH.stats.set = CH.stats.set + 1
end)
