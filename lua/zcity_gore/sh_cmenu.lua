-- |Z-CITY| GORE c-menu (shared)
--
-- Why this exists: this addon ignores every cut that does not go through ZCityGore (see the
-- AmputateLimb wrapper in sv_gore.lua). Z-City's own "Amputate Limb" c-menu property calls
-- hg.organism.AmputateLimb / hg.ExplodeHead directly, so with this addon loaded every entry
-- did nothing. This file re-registers the property so that it
--   * keeps Z-City's own label / icon / order / access filter,
--   * severs limbs and the head through hg.ZCityGore_Sever (severed piece, artery, tether),
--   * adds "Amputate Torso" (cut in half at the chest, lower half hangs on the chest artery).

ZCityGore = ZCityGore or {}

local PROP_NAME = "amputate_limb"

-- menu entry -> limb (nil = torso)
local ENTRIES = {
	{"Head", 0, "head"},
	{"Left Arm", 1, "larm"},
	{"Right Arm", 2, "rarm"},
	{"Left Leg", 3, "lleg"},
	{"Right Leg", 4, "rleg"},
	{"Amputate Torso", 5, nil},
}
local ID_TO_LIMB = {}
for i = 1, #ENTRIES do ID_TO_LIMB[ENTRIES[i][2]] = ENTRIES[i][3] end
local ID_TORSO = 5

local function fallbackFilter(self, ent, ply)
	if not IsValid(ply) or not IsValid(ent) then return false end
	if ply.ZCTools_GetAccess then
		if not ply:ZCTools_GetAccess() then return false end
	elseif not ply:IsSuperAdmin() then
		return false
	end
	if ent:IsPlayer() or ent:IsNPC() then return true end
	return ent:IsRagdoll() and not (ent.IsSeveredLimb or ent:GetNWBool("IsSeveredLimb"))
end

local function ownerOf(ent)
	if IsValid(ent) and ent:IsNPC() then return ent end -- NPCs have no player behind them (RagdollOwner is for ragdolls)
	return (istable(hg) and isfunction(hg.RagdollOwner) and hg.RagdollOwner(ent)) or ent
end

local function installProperty()
	if not properties or not properties.Add then return false end
	if not istable(hg) then return false end

	local cur = properties.List and properties.List[PROP_NAME]
	if cur and cur.__zcGore then return true end -- ours is already in place

	-- remember Z-City's own definition so we can borrow its look and its access filter
	local orig = cur
	local origFilter = orig and isfunction(orig.Filter) and orig.Filter or nil

	properties.Add(PROP_NAME, {
		__zcGore = true,
		MenuLabel = orig and orig.MenuLabel or "Amputate Limb",
		Order = orig and orig.Order or 14,
		MenuIcon = orig and orig.MenuIcon or "effects/arc9_eft/evil.png",

		Filter = function(self, ent, ply)
			-- Z-City's own filter knows nothing about NPCs: same admin rule as for players
			if IsValid(ent) and ent:IsNPC() then return fallbackFilter(self, ent, ply) end
			if origFilter then return origFilter(orig, ent, ply) end
			return fallbackFilter(self, ent, ply)
		end,

		MenuOpen = function(self, option, ent)
			local owner = ownerOf(ent)
			local submenu = option:AddSubMenu()
			for i = 1, #ENTRIES do
				local id = ENTRIES[i][2]
				local item = submenu:AddOption(ENTRIES[i][1])
				item.OnChecked = function() self:AmputateLimb(owner, id) end
				item:SetIsCheckable(true)
			end
		end,

		AmputateLimb = function(self, ent, id)
			self:MsgStart()
			net.WriteEntity(ent)
			net.WriteUInt(id, 8)
			self:MsgEnd()
		end,

		Receive = function(self, _, ply)
			local ent = net.ReadEntity()
			local id = net.ReadUInt(8)
			if not IsValid(ent) or not self:Filter(ent, ply) then return end
			if not SERVER then return end

			local owner = ownerOf(ent)
			if not IsValid(owner) then return end

			if owner:IsNPC() then
				if id == ID_TORSO then
					if ZCityGore.NPCSeverTorso then ZCityGore.NPCSeverTorso(owner, VectorRand(-250, 250)) end
				elseif ID_TO_LIMB[id] and ZCityGore.NPCSever then
					ZCityGore.NPCSever(owner, ID_TO_LIMB[id], nil, "c-menu")
				end
				return
			end

			if id == ID_TORSO then
				if isfunction(ZCityGore.SeverTorso) then
					ZCityGore.SeverTorso(owner, VectorRand(-250, 250), false)
				end
				return
			end

			local limb = ID_TO_LIMB[id]
			if not limb then return end
			local org = owner.organism
			if not org then return end
			if limb == "head" and (org.headamputated == true or owner.noHead) then return end

			-- same path a weapon cut takes: severed piece + artery + stump on the body
			if isfunction(hg.ZCityGore_Sever) then
				hg.ZCityGore_Sever(org, limb, nil, "c-menu")
			end
		end,
	})
	return true
end

ZCityGore.InstallCMenu = installProperty

-- Z-City may register its own property after this file ran (load order), which would silently put the
-- broken one back. Keep checking for a while and take it over again whenever that happens.
local function boot()
	installProperty()
	timer.Create("zcity_gore_cmenu_guard", 1, 90, installProperty)
end

hook.Add("HomigradRun", "zcity_gore_cmenu", function() timer.Simple(0, boot) end)
hook.Add("InitPostEntity", "zcity_gore_cmenu", function() timer.Simple(0.5, boot) end)
boot()
