-- Совместимость с отдельным аддоном "Metal Gear Solid V: Gameplay SWEP" (таблица MGSVSnake, оружие weapon_mgsv_*).
-- Самого аддона в репозитории нет (модели и звуки MGSV чужие) - он ставится отдельной папкой в garrysmod/addons.
-- Пока у игрока в руках SWEP Снейка, homigrad уступает:
--   камера - работает камера аддона из-за плеча (от 3-го лица) вместо камеры homigrad от 1-го лица (cl_camera.lua);
--   тело - homigrad не рисует своё тело и аксессуары, аддон рисует Снейка (sh_utility.lua, hg.renderOverride);
--   движение - инерция homigrad выключена, у аддона своё движение: ползком, перекаты, укрытия (movement/sh_inertia.lua).
-- Если игрок упал регдоллом homigrad (FakeRagdoll) или без сознания - Снейк выключается, дальше работает homigrad.
-- Того, кого Снейк схватил (CQC), аддон рисует сам по анимации захвата - homigrad его тело не рисует и свою камеру
-- ему не навязывает (у схваченного камера аддона).
-- Транквилизатор Снейка (и бионическая рука) по игрокам и NPC с организмом действует как дротик Z-city
-- (weapon_tranquilizer): удар DMG_CLUB на 5 и +5 к org.tranquilizer - сознание уходит постепенно (sv_pain.lua).
hg.MGSV = hg.MGSV or {}

function hg.MGSV.Active(ply)
	-- только игроки: homigrad зовёт отрисовку и для регдоллов, а у них нет InVehicle и т.п.
	if not MGSVSnake or not MGSVSnake.Active or not IsValid(ply) or not ply:IsPlayer() then return false end
	return MGSVSnake.Active(ply) and true or false
end

-- его схватили приёмом CQC (аддон двигает и рисует его сам)
function hg.MGSV.Held(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return false end
	if MGSVCQC and MGSVCQC.Held and MGSVCQC.Held(ply) then return true end
	return CLIENT and MGSVSnake and MGSVSnake.CQCHeld and MGSVSnake.CQCHeld(ply) or false
end

-- регдолл аддона (вырублен приёмом CQC или усыплён): его рисует движок, а не отрисовка homigrad
function hg.MGSV.IsRag(ent)
	if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return false end
	return ent:GetNW2Bool("MGSVCQC_KO", false) or ent:GetNW2Float("MGSV_Sleep", 0) > 0 or ent:GetNW2String("MGSV_RagModel", "") ~= ""
end

-- камера и тело - за аддоном (Снейк в руках или схвачен)
function hg.MGSV.Owns(ply)
	return hg.MGSV.Active(ply) or hg.MGSV.Held(ply)
end

-- дротик как у Z-city: tranquilizerdarts в sh_ammostuff.lua (BulletSettings.Damage = 5, DMG_CLUB, tranquilizer = true)
local DART_DAMAGE = 5
local function ZCityDart(victim, attacker)
	local org = victim.organism
	if not org or org.alive == false then return false end
	local d = DamageInfo()
	d:SetDamage(DART_DAMAGE)
	d:SetDamageType(DMG_CLUB)
	d:SetAttacker(IsValid(attacker) and attacker or victim)
	d:SetInflictor(IsValid(attacker) and attacker or victim)
	d:SetDamagePosition(victim:WorldSpaceCenter())
	victim:TakeDamageInfo(d)
	org.tranquilizer = (org.tranquilizer or 0) + DART_DAMAGE
	return true
end

-- аддон грузится сам (autorun), поэтому оборачиваем его проверку, когда всё загружено
local function Wrap()
	local S = MGSVSnake
	if not S then return end

	if S.Active and not S.RemWrappedActive then
		S.RemWrappedActive = true
		local orig = S.Active
		S.Active = function(ply)
			if not IsValid(ply) or not ply:IsPlayer() then return false end
			if IsValid(ply.FakeRagdoll) or (ply.organism and ply.organism.otrub) then return false end
			return orig(ply)
		end
	end

	if SERVER and S.TranqPlayer and not S.RemWrappedTranqPly then
		S.RemWrappedTranqPly = true
		local orig = S.TranqPlayer
		S.TranqPlayer = function(victim, attacker, head)
			if IsValid(victim) and victim:IsPlayer() and victim:Alive() and victim.organism then return ZCityDart(victim, attacker) end
			return orig(victim, attacker, head)
		end
	end
	if SERVER and S.TranqNPC and not S.RemWrappedTranqNPC then
		S.RemWrappedTranqNPC = true
		local orig = S.TranqNPC
		S.TranqNPC = function(npc, attacker, head)
			if IsValid(npc) and npc.organism then return ZCityDart(npc, attacker) end
			return orig(npc, attacker, head)
		end
	end
end
Wrap()
timer.Simple(0, Wrap)
hook.Add("InitPostEntity", "rem_mgsv_compat", Wrap)
