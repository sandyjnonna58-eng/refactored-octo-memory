-- Coarse server-side pool records so that clients who join late (or reconnect) still see where
-- people bled. This is deliberately cheap: one ground trace per bleeding body per second and a
-- capped table of cells. Clients that were present simulate their own, more detailed pools.

local C, N, Z = ABL.Config, ABL.Net, ABL.ZC

local CELL = 18
local MAX_CELLS = 96
local cells = {}      -- key -> record
local cellCount = 0
local lastBlood = setmetatable({}, { __mode = "k" })

local function Reset()
	cells = {}
	cellCount = 0
end
hook.Add("PostCleanupMap", "ABL_PersistReset", Reset)

local function Evict()
	local worstKey, worst = nil, math.huge
	for k, r in pairs(cells) do
		local score = r.vol / (1 + (CurTime() - r.t) / 600)
		if score < worst then worstKey, worst = k, score end
	end
	if worstKey then cells[worstKey] = nil cellCount = cellCount - 1 end
end

local function Deposit(pos, normal, vol)
	local key = ABL.CellKey(pos.x, pos.y, pos.z, CELL)
	local r = cells[key]
	if not r then
		if cellCount >= MAX_CELLS then Evict() end
		r = { pos = pos, normal = normal, vol = 0, t = CurTime(), born = CurTime() }
		cells[key] = r
		cellCount = cellCount + 1
	end
	r.vol = math.min(r.vol + vol, 16000)
	r.t = CurTime()
end

local traceData = { mask = MASK_SOLID_BRUSHONLY }

local function Track(ent, org)
	if not istable(org) then return end
	local hasWounds = (istable(org.wounds) and #org.wounds > 0) or (istable(org.arterialwounds) and #org.arterialwounds > 0)
	local blood = tonumber(org.blood)
	if not blood then return end
	local prev = lastBlood[org]
	lastBlood[org] = blood
	if not hasWounds or not prev then return end
	local lost = prev - blood
	if lost <= 0.05 or lost > 600 then return end

	local body = ent:IsPlayer() and Z.GetBody(ent) or ent
	if not IsValid(body) then return end
	local start = body:WorldSpaceCenter()
	traceData.start = start
	traceData.endpos = start - Vector(0, 0, 96)
	traceData.filter = { body, ent }
	local tr = util.TraceLine(traceData)
	if not tr.Hit or tr.HitNormal.z < 0.6 then return end
	-- Blood leaves the body over an area around it, not at a point; jitter the deposit.
	local p = tr.HitPos + Vector(math.Rand(-8, 8), math.Rand(-8, 8), 0)
	Deposit(p, tr.HitNormal, lost * C.sv.volume:GetFloat())
end

timer.Create("ABL_PersistTrack", 1, 0, function()
	if not ABL.Enabled() or not C.sv.persist:GetBool() then return end
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then Track(ply, ply.organism) end
		local corpse = Z.GetCorpse(ply)
		if IsValid(corpse) and istable(corpse.organism) then Track(corpse, corpse.organism) end
	end
end)

-- Clients ask once they are fully in game.
local lastReq = setmetatable({}, { __mode = "k" })
net.Receive(N.REQ, function(_, ply)
	if not IsValid(ply) then return end
	if (lastReq[ply] or 0) > CurTime() then return end
	lastReq[ply] = CurTime() + 30
	if not C.sv.persist:GetBool() or cellCount == 0 then return end

	net.Start(N.PERSIST)
	local list = {}
	for _, r in pairs(cells) do
		if r.vol >= 2 then list[#list + 1] = r end
	end
	table.sort(list, function(a, b) return a.vol > b.vol end)
	local n = math.min(#list, 64)
	net.WriteUInt(n, 7)
	for i = 1, n do
		local r = list[i]
		net.WriteVector(r.pos)
		net.WriteNormal(r.normal)
		net.WriteUInt(math.Clamp(math.Round(r.vol), 0, 16383), 14)
		net.WriteUInt(math.Clamp(math.Round(CurTime() - r.born), 0, 16383), 14)
	end
	net.Send(ply)
end)
