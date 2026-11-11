-- The link: the one place where what is true of a character's breathing becomes the few numbers a
-- picture is made from. A pure function, the same on both sides and in the offline check. The
-- state decides the picture; nothing here or after it writes back into the state.
--
--   state (server)                          controls (client, for one frame)
--   ---------------------------------       ----------------------------------------------
--   the clock: how full the breath is  -->  dl, dr   how far each half of the diaphragm has
--   its depth                                        gone down (0 out .. 1 its whole travel);
--   the airway: how open               -->           the lungs' bases go with it
--   each lung: what it can still do    -->
--   each lung: let go of the wall      -->  fl, fr   how far each lung stands in its place
--                                                    (1) or is drawn together at its root (0)
--
-- What the picture cannot show is left out on purpose: the ribs do not swing (the skeleton
-- module's ribs are rigid on a body), so the chest's own rise is Z-City's, which the clock drives
-- (cl_chest.lua).

local RS = HemoRespiratory
RS.Link = RS.Link or {}
local L = RS.Link
local C = RS.Config
local function Clamp(x, a, b) return x < a and a or (x > b and b or x) end

-- The one pneumothorax number Z-City keeps, shared out to the two sides by how far each lung is
-- punctured: how far each has let go of the chest wall, 0..1. (Z-City lets the number rise to half
-- the sum of the two punctures.)
function L.Collapse(pneumothorax, breachL, breachR)
	local sum = breachL + breachR
	if sum <= 1e-6 or pneumothorax <= 0 then return 0, 0 end
	return Clamp(2 * pneumothorax * breachL / sum, 0, 1), Clamp(2 * pneumothorax * breachR / sum, 0, 1)
end

-- vl, vr: how full the breath is now on each side (0..1; the left a moment behind the right);
-- depth: the clock's; rec: what is known of the lungs: { patency, shareL, shareR, collapseL,
-- collapseR } (nil: sound lungs). out is filled and returned: dl, dr, fl, fr.
function L.Controls(vl, vr, depth, rec, out)
	out = out or {}
	local B = C.Breath
	local pat = rec and rec.patency or 1
	local sl, sr = rec and rec.shareL or 1, rec and rec.shareR or 1
	local cl, cr = rec and rec.collapseL or 0, rec and rec.collapseR or 0
	-- the muscle's pull: a quiet breath uses a part of the diaphragm's travel, a deep one more
	local pull = Clamp(depth * B.quietDia, 0, 1)
	-- what the pull gets done: all of it into lungs that take the air; little against a shut airway or
	-- a lung that cannot fill (the muscle works, the base hardly moves)
	local al = B.struggle + (1 - B.struggle) * Clamp(pat * sl, 0, 1)
	local ar = B.struggle + (1 - B.struggle) * Clamp(pat * sr, 0, 1)
	out.dl = Clamp(vl * pull * B.leftShare * al, 0, 1)
	out.dr = Clamp(vr * pull * ar, 0, 1)
	out.fl = Clamp(1 - cl, 0, 1)
	out.fr = Clamp(1 - cr, 0, 1)
	return out
end

-- How a lung looks for what is wrong with it: a factor for each of red, green, blue (1: as it is).
-- A lung drawn together is darker and denser; a damaged one darker and redder.
function L.Tint(damage, collapse)
	local d, c = Clamp(damage or 0, 0, 1), Clamp(collapse or 0, 0, 1)
	local k = 1 - 0.35 * c
	return k * (1 - 0.10 * d), k * (1 - 0.40 * d), k * (1 - 0.38 * d)
end
