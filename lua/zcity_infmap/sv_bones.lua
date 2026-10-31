-- Кости, физика и позиции игрока на сервере.

local ZCInf = ZCInf
local IsZero = ZCInf.IsZero
local cs2 = ZCInf.ChunkSpan
local InBounds = ZCInf.InBounds

local EntityMT = FindMetaTable("Entity")
local PhysObjMT = FindMetaTable("PhysObj")

--[[-------------------------------------------------------------------------
	Entity:GetBoneMatrix
	InfMap переводит в мировые координаты GetBonePosition и GetAttachment,
	но не GetBoneMatrix. А Z-City строит на ней почти всё: ragdoll "фейка",
	попадания по органам, кровь, оружие в руках, позицию игрока в фейке.
	Без этого игрок в чанке, отличном от нулевого, при падении в ragdoll
	улетает в чанк 0, а попадания не находят органы.
---------------------------------------------------------------------------]]
ZCInf.Detour(EntityMT, "GetBoneMatrix", function(orig)
	return function(self, bone)
		local m = orig(self, bone)
		if m == nil then return m end
		local c = self.CHUNK_OFFSET
		if c == nil or (c[1] == 0 and c[2] == 0 and c[3] == 0) then return m end
		m:SetTranslation(m:GetTranslation() + c * cs2())
		return m
	end
end)
ZCInf.Mark("GetBoneMatrix")

-- GetBonePosition у InfMap падает с ошибкой, если движок вернул nil (неверная кость)
ZCInf.Detour(EntityMT, "GetBonePosition", function(orig)
	return function(self, bone)
		local pos, ang = self:InfMap_GetBonePosition(bone)
		if pos == nil then return pos, ang end
		return InfMap.unlocalize_vector(pos, self.CHUNK_OFFSET), ang
	end
end)

--[[-------------------------------------------------------------------------
	PhysObj:ComputeShadowControl / UpdateShadow
	Цель (pos) задаётся в координатах движка. Z-City управляет руками,
	головой и телом ragdoll'а в фейке, передавая мировые координаты.
---------------------------------------------------------------------------]]
local function physChunk(phys)
	local ent = phys:GetEntity()
	if not IsValid(ent) then return nil end
	local c = ent.CHUNK_OFFSET
	if IsZero(c) then return nil end
	return c
end

ZCInf.Detour(PhysObjMT, "ComputeShadowControl", function(orig)
	return function(self, params)
		local c = params and params.pos and physChunk(self)
		if not c then return orig(self, params) end
		local wp = params.pos
		params.pos = wp - c * cs2()
		orig(self, params)
		params.pos = wp
	end
end)

ZCInf.Detour(PhysObjMT, "UpdateShadow", function(orig)
	return function(self, pos, ang, dt)
		local c = physChunk(self)
		if c then pos = pos - c * cs2() end
		return orig(self, pos, ang, dt)
	end
end)
ZCInf.Mark("ComputeShadowControl/UpdateShadow")

--[[-------------------------------------------------------------------------
	PhysObj:SetPos у ragdoll'ов.
	InfMap определяет чанк по самой точке и переносит ВСЮ сущность в этот чанк.
	Когда Z-City расставляет кости ragdoll'а по одной, а ragdoll стоит на стыке
	чанков, сущность "прыгает" между чанками и кости разлетаются на 20000 юнитов.
	Для ragdoll'а, у которого чанк уже есть, ставим кость в его же чанке
	(движок позволяет выйти за чанк до границы мира, потом InfMap сам перенесёт ragdoll).
---------------------------------------------------------------------------]]
ZCInf.Detour(PhysObjMT, "SetPos", function(orig)
	return function(self, pos, teleport)
		local ent = self:GetEntity()
		if IsValid(ent) and ent.CHUNK_OFFSET ~= nil and ent:IsRagdoll() then
			local lp = ZCInf.ToLocal(pos, ent.CHUNK_OFFSET)
			if InBounds(lp) then
				return self:InfMap_SetPos(lp, teleport)
			end
		end
		return orig(self, pos, teleport)
	end
end)
ZCInf.Mark("ragdoll PhysObj:SetPos")

--[[-------------------------------------------------------------------------
	Entity:SetPos у игрока в машине или в фейке.
	Z-City каждый тик ставит игрока в фейке в голову ragdoll'а, а игрока в машине -
	в vector_origin. InfMap при этом определяет чанк игрока по точке и может
	увести его в другой чанк, чем ragdoll/машина: камера и отрисовка ломаются.
	Игрок всегда держится в чанке своей машины или своего ragdoll'а.
---------------------------------------------------------------------------]]
function ZCInf.PlayerAnchor(ply)
	if ply:InVehicle() then
		local veh = ply:GetVehicle()
		if IsValid(veh) and veh.CHUNK_OFFSET ~= nil then return veh end
	end
	local rag = ply.FakeRagdoll
	if IsValid(rag) and rag.CHUNK_OFFSET ~= nil and ply:Alive() then return rag end
	return nil
end
local PlayerAnchor = ZCInf.PlayerAnchor

ZCInf.Detour(EntityMT, "SetPos", function(orig)
	return function(self, pos)
		if self:IsPlayer() then
			local anchor = PlayerAnchor(self)
			if anchor ~= nil then
				local c = anchor.CHUNK_OFFSET
				local lp = ZCInf.ToLocal(pos, c)
				if InBounds(lp) then
					if self.CHUNK_OFFSET ~= c then InfMap.prop_update_chunk(self, c) end
					return self:InfMap_SetPos(lp)
				end
			end
		end
		return orig(self, pos)
	end
end)
ZCInf.Mark("player SetPos anchor")
