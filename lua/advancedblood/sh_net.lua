-- Network protocol. The server only sends *events* (never droplets, decals or runoff frames):
--   abl_hit      wound impact: body entity, bone, entry/exit in bone space, direction, class, energy,
--                hitgroup
--   abl_rcol     bloody ragdoll collision: ragdoll, bone, contact point/normal, speed
--   abl_persist  late-join snapshot of coarse server-side pool records (sent once per client)
--   abl_req      client -> server: request the persist snapshot after the client is ready
--   abl_zcs      abl_zcity_status: the client asks, the server answers with what its part of the
--                Z-City compatibility has in place (once a second per player at most)
--   abl_wreq     client -> server: the bodies that have come into this client's sight (entity
--                numbers): has any of them wounds this client was not told of?
--   abl_wrep     the answer, one message a wound: the abl_hit it was, with the place and the
--                direction as the body stands now, and how old it is (server/sv_woundstore.lua)
--   abl_life     a player has been spawned anew (not got up from its ragdoll: that is a spawn
--                too, and the same life): nothing of the old body's blood belongs on the new one.
--                Clients cannot tell the two apart by themselves (cl_sources.lua, S.NewLife).
-- Persistent wound state itself is already replicated by Z-City's "wounds"/"arterialwounds" netvars.

ABL.Net = ABL.Net or {}
local N = ABL.Net

N.HIT, N.RCOL, N.PERSIST, N.REQ = "abl_hit", "abl_rcol", "abl_persist", "abl_req"
-- developer only (abl_dev_compare): which model of body blood a character is drawn with
N.DEV = "abl_dev"
N.ZCS = "abl_zcs"
N.WREQ, N.WREP = "abl_wreq", "abl_wrep"
N.LIFE = "abl_life"

-- damage classes
N.DMG_BULLET, N.DMG_BUCKSHOT, N.DMG_SLASH, N.DMG_CLUB, N.DMG_BLAST, N.DMG_OTHER = 0, 1, 2, 3, 4, 5

if SERVER then
	util.AddNetworkString(N.HIT)
	util.AddNetworkString(N.RCOL)
	util.AddNetworkString(N.PERSIST)
	util.AddNetworkString(N.REQ)
	util.AddNetworkString(N.DEV)
	util.AddNetworkString(N.ZCS)
	util.AddNetworkString(N.WREQ)
	util.AddNetworkString(N.WREP)
	util.AddNetworkString(N.LIFE)
end

local LOCAL_SCALE = 16 -- bone-local positions: 1/16 unit precision, +-127 units range (Int12)

function N.WriteLocal(v)
	net.WriteInt(math.Clamp(math.Round(v.x * LOCAL_SCALE), -2047, 2047), 12)
	net.WriteInt(math.Clamp(math.Round(v.y * LOCAL_SCALE), -2047, 2047), 12)
	net.WriteInt(math.Clamp(math.Round(v.z * LOCAL_SCALE), -2047, 2047), 12)
end

function N.ReadLocal()
	local x = net.ReadInt(12) / LOCAL_SCALE
	local y = net.ReadInt(12) / LOCAL_SCALE
	local z = net.ReadInt(12) / LOCAL_SCALE
	return Vector(x, y, z)
end

-- Entity index with the engine's edict bit budget.
function N.WriteEnt(ent) net.WriteUInt(IsValid(ent) and ent:EntIndex() or 0, 13) end
function N.ReadEnt() return Entity(net.ReadUInt(13)) end

-- A hit as a wound told again carries it (abl_wrep): the fields of abl_hit that say what the
-- wound is, in abl_hit's order. rec: class, damage, bleed, hitgroup, what ABL.Wound.Write
-- writes, second. (abl_hit itself is written and read where it always was: sv_main.lua,
-- cl_events.lua.)
function N.WriteHit(body, bone, lEntry, lExit, dir, rec)
	N.WriteEnt(body)
	net.WriteUInt(bone, 8)
	N.WriteLocal(lEntry)
	net.WriteNormal(dir)
	net.WriteUInt(rec.class or 0, 3)
	net.WriteUInt(math.Clamp(math.Round(rec.damage or 0), 0, 1023), 10)
	net.WriteUInt(math.Clamp(math.Round((rec.bleed or 0) * 4), 0, 1023), 10)
	net.WriteUInt(math.Clamp(tonumber(rec.hitgroup) or 0, 0, 15), 4)
	ABL.Wound.Write(rec)
	net.WriteBool(rec.second and true or false)
	net.WriteBool(lExit ~= nil)
	if lExit then N.WriteLocal(lExit) end
end

-- Returns the event and the number of the entity it names.
function N.ReadHit()
	local ev = {}
	local index = net.ReadUInt(13)
	ev.body = Entity(index)
	ev.bone = net.ReadUInt(8)
	ev.lpos = N.ReadLocal()
	ev.dir = net.ReadNormal()
	ev.class = net.ReadUInt(3)
	ev.damage = net.ReadUInt(10)
	ev.bleed = net.ReadUInt(10) / 4
	ev.hitgroup = net.ReadUInt(4)
	ABL.Wound.Read(ev)
	ev.second = net.ReadBool()
	if net.ReadBool() then ev.exitLocal = N.ReadLocal() end
	return ev, index
end

-- Statistics for the debug HUD (bits sent/received per message name)
N.stats = N.stats or { count = 0, bits = 0 }
function N.Account(bits)
	N.stats.count = N.stats.count + 1
	N.stats.bits = N.stats.bits + (bits or 0)
end
