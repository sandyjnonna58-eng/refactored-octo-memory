-- The face of an injured character: flexes of the model, set by the server.
--
-- Measured in the game: a client's own writes to the flexes of a standing player do not hold (the
-- engine overwrites them with the networked values), the server's do, on players and on ragdolls;
-- the engine networks a flex only when it changes. So the face is set here, a few times a second
-- at most and only on change. The mouth-opening flexes of a standing player belong to the game's
-- voice animation and the eyelids of a ragdoll to Z-City: neither is used.
--
--   weakness of the lower face   the corner of the mouth of that side hangs. A lesion of one
--                                hemisphere weakens the lower face of the other side and spares
--                                the eye [S: N23]
--   a lesion of the brainstem    the lid of the same side droops: the lateral medulla (Horner
--                                syndrome [S: N41]) or the midbrain (third nerve [S: N55])
--   a convulsion                 the jaw is clenched and the face drawn tight [S: Z6]
--   drowsiness                   lids half closed
--
-- Models without these flexes are left alone.

local NT = NeuroTrauma
NT.Face = NT.Face or {}
local F = NT.Face
local Z, A = NT.ZC, NT.Atlas

local applied = setmetatable({}, { __mode = "k" })   -- entity -> { flex name -> weight set }
local idCache = setmetatable({}, { __mode = "k" })   -- entity -> { flex name -> id or false }

local function FlexId(ent, name)
	local c = idCache[ent]
	if not c then c = {} idCache[ent] = c end
	local id = c[name]
	if id == nil then
		id = ent:GetFlexIDByName(name) or false
		c[name] = id
	end
	return id or nil
end

local function Apply(ent, want)
	local have = applied[ent]
	if not have then have = {} applied[ent] = have end
	for name, w in pairs(want) do
		if have[name] ~= w then
			local id = FlexId(ent, name)
			if id then ent:SetFlexWeight(id, w) end
			have[name] = w
		end
	end
	for name, w in pairs(have) do
		if want[name] == nil and w ~= 0 then
			local id = FlexId(ent, name)
			if id then ent:SetFlexWeight(id, 0) end
			have[name] = nil
		end
	end
end

function F.Clear(ent)
	if IsValid(ent) and applied[ent] then
		Apply(ent, {})
		applied[ent] = nil
	end
end

local function Q(x) return math.floor(math.Clamp(x, 0, 1) * 4 + 0.5) / 4 end

-- Called with the steps of a record; works twice a second.
function F.Update(ply, org, st, now)
	if now < (st.nextFace or 0) then return end
	st.nextFace = now + 0.5
	local body = Z.Body(ply)
	if not IsValid(body) or (body.GetFlexNum and body:GetFlexNum() == 0) then return end
	-- (the body changes when a character is dropped into its ragdoll or gets up: start over there)
	if st.faceBody ~= body then
		if IsValid(st.faceBody) then F.Clear(st.faceBody) end
		st.faceBody = body
	end
	local want = {}
	local wl, wr = Q((1 - st.faceL) * 1.2), Q((1 - st.faceR) * 1.2)
	if wl > 0 then want.left_corner_depressor = wl end
	if wr > 0 then want.right_corner_depressor = wr end
	local d = st.an.d
	local function Lid(side)
		return Q(math.max(d[A.regionOf[side .. "_medulla_lateral"]] or 0, d[A.regionOf[side .. "_midbrain_teg"]] or 0))
	end
	local ll, lr = Lid("L"), Lid("R")
	if ll > 0 then want.left_lid_droop = ll end
	if lr > 0 then want.right_lid_droop = lr end
	local sz = st.sz
	if sz and (sz.phase == "tonic" or sz.phase == "clonic") then
		want.jaw_clencher, want.bite, want.right_stretcher, want.left_stretcher = 1, 1, 0.75, 0.75
	elseif sz and sz.phase == "impaired" then
		want.jaw_clencher = 0.5
	end
	-- (a heart that has stopped: the jaw hangs)
	if st.arrestSince and body:IsRagdoll() then want.jaw_drop = 0.7 end
	local drowsy = Q(st.sedation or 0)
	if drowsy > 0 and not body:IsRagdoll() then want.half_closed = drowsy end
	Apply(body, want)
end

hook.Add("NT_Closed", "NT_Face", function(ply)
	if not IsValid(ply) then return end
	F.Clear(ply)
	-- (a body whose character has died keeps the face it had: the jaw of a body that lay in an
	-- arrest does not shut at the moment its death is booked)
	if IsValid(ply.FakeRagdoll) and ply:Alive() then F.Clear(ply.FakeRagdoll) end
end)
