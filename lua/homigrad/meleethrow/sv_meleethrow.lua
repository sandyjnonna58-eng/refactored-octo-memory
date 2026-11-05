-- Бросок ножа: у оружия с SWEP.CanThrow = true (ножи, мачете, стекло) E + ПКМ - метнуть в того, на кого смотришь.
-- Летит с вращением, бьёт по скорости (сильнее обычного удара), лезвием застревает в теле (рану держит, вынуть - E по
-- человеку, как застрявшую стрелу/нож в сборке), иначе падает рядом - подобрать E. Используется ent_throwable из сборки.
hg = hg or {}
hg.MeleeThrow = hg.MeleeThrow or {}
local MT = hg.MeleeThrow

MT.Speed = 1400
MT.DamageMul = 1.3
MT.Cooldown = 0.6

function MT.Throw(ply, wep)
	if not IsValid(ply) or not IsValid(wep) or not wep.CanThrow then return false end
	if not ply:Alive() or IsValid(ply.FakeRagdoll) then return false end
	if (ply.rem_throw_next or 0) > CurTime() then return false end
	ply.rem_throw_next = CurTime() + MT.Cooldown

	local ent = ents.Create("ent_throwable")
	if not IsValid(ent) then return false end
	ent.WorldModel = wep.WorldModelExchange or wep.WorldModel
	ent.modelscale = wep.modelscale2 ~= 1 and wep.modelscale2 or nil

	local char = hg.GetCurrentCharacter and hg.GetCurrentCharacter(ply) or ply
	local start = hg.eye and select(1, hg.eye(ply, 60, char)) or ply:EyePos()
	local aim = ply:GetAimVector()
	ent:SetPos(start + aim * 8)
	ent:SetAngles(aim:Angle())
	ent:SetOwner(ply)
	ent:Spawn()

	ent.localshit = Vector(0, 0, 0)
	ent.wep = wep:GetClass()
	ent.owner = ply
	ent.damage = (wep.DamagePrimary or 20) * MT.DamageMul
	ent.MaxSpeed = MT.Speed
	ent.DamageType = DMG_SLASH
	ent.AttackHit = "Canister.ImpactHard"
	ent.AttackHitFlesh = wep.AttackHitFlesh or "snd_jack_hmcd_knifehit.wav"
	ent.poisoned2 = wep.poisoned2

	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetVelocity(aim * MT.Speed + ply:GetVelocity())
		phys:AddAngleVelocity(Vector(0, 1400, 0)) -- кувырком, как метательный нож
	end

	ply:EmitSound("weapons/slam/throw.wav", 60, math.random(95, 108))
	ply:ViewPunch(Angle(-3, math.Rand(-1, 1), 0))
	if ply.DoAnimationEvent then ply:DoAnimationEvent(ACT_GMOD_GESTURE_ITEM_THROW) end

	ply:SelectWeapon(hg.GetHandsWeaponClass and hg.GetHandsWeaponClass(ply) or "weapon_hands_sh")
	ply:StripWeapon(wep:GetClass())
	return true
end

hook.Add("KeyPress", "rem_meleethrow", function(ply, key)
	if key ~= IN_ATTACK2 or not ply:KeyDown(IN_USE) then return end
	local wep = ply:GetActiveWeapon()
	if IsValid(wep) and wep.CanThrow then MT.Throw(ply, wep) end
end)
