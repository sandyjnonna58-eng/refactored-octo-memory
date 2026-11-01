-- Лечение как в Far Cry (анимации из аддона "Far Cry Healing System", логика своя под организм homigrad):
-- у кого в инвентаре мачете FC3 (SWEP.FCHeal = true), тот при ранениях жмёт F - руки делают перевязку/вынимают пулю/
-- вправляют сустав и т.д. (по тому, чем ранили), в конце кровотечения останавливаются, кровь и здоровье частично
-- возвращаются, боль спадает. Если не ранен - F работает как обычно (фонарик).
-- Модели рук: models/weapons/fc/*.mdl, звуки: sound/weapons/fc_heals/ - в контент-паке (не в репозитории).
hg = hg or {}
hg.FCHeal = hg.FCHeal or {}
local FH = hg.FCHeal

-- виды лечения: модель рук, последовательности, длительность, звуки по времени (группы - в sv_fcheal.lua)
FH.Kinds = {
	bullet = {model = "models/weapons/fc/fc_bullet_heal_left.mdl", dur = 3.5,
		seqs = {"fc_bullet_heal_left1", "fc_bullet_heal_left2", "fc_bullet_heal_left3", "fc_bullet_heal_left4", "fc_bullet_heal_left5"},
		snd = {{0.1, "movement"}, {0.3, "bleeding"}, {0.8, "extract", true}, {1.0, "mechanic"}, {1.9, "extract", true}, {2.5, "mechanic"}, {3.0, "movement"}}},
	frag_a = {model = "models/weapons/fc/fc_frag_heal_a.mdl", dur = 3.5,
		seqs = {"fc_frag_heal_a1", "fc_frag_heal_a3"},
		snd = {{0.1, "movement"}, {1.3, "knifepush"}, {2.4, "dagger", true}, {2.4, "bleeding"}, {3.0, "movement"}}},
	frag_c = {model = "models/weapons/fc/fc_frag_heal_c.mdl", dur = 3.5,
		seqs = {"fc_frag_heal_c1", "fc_frag_heal_c2"},
		snd = {{0.1, "movement"}, {1.0, "movement"}, {1.4, "shamrock"}, {2.2, "pullout", true}, {2.2, "bleeding"}, {2.8, "movement"}}},
	syringe = {model = "models/weapons/fc/fc_syringe_heal.mdl", dur = 2.0,
		seqs = {"fc_syringe_heal1", "fc_syringe_heal2", "fc_syringe_heal3"},
		snd = {{0.1, "movement"}, {0.5, "syringe"}, {1.3, "movement"}}},
	burn = {model = "models/weapons/fc/fc_burn_heal.mdl", dur = 3.0,
		seqs = {"fc_burn_heal1"},
		snd = {{0.1, "movement"}, {0.3, "flesh"}, {0.8, "flesh"}, {1.0, "movement"}, {1.5, "flame"}, {1.5, "flesh"}, {2.0, "movement"}}},
	disloc = {model = "models/weapons/fc/fc_dislocation_heal.mdl", dur = 3.5,
		seqs = {"fc_dislocation_heal1", "fc_dislocation_heal2", "fc_dislocation_heal3", "fc_dislocation_heal4", "fc_dislocation_heal6",
			"fc_dislocation_heal7", "fc_dislocation_heal8", "fc_dislocation_heal10"},
		snd = {{0.1, "movement"}, {0.9, "movement"}, {1.6, "bone"}, {2.2, "bone"}, {2.9, "movement"}}},
}

-- временное "оружие" с руками лечения на каждый вид (выдаётся на время анимации и забирается)
local function Register(kind, data)
	local SWEP = {
		Base = "weapon_base",
		PrintName = "Healing",
		Spawnable = false,
		AdminOnly = true,
		ViewModel = data.model,
		WorldModel = "",
		UseHands = true,
		ViewModelFOV = 80,
		ViewModelFlip = false,
		DrawCrosshair = false,
		DrawAmmo = false,
		Slot = 5,
		SlotPos = 9,
		Weight = 0,
		AutoSwitchTo = false,
		AutoSwitchFrom = false,
		Primary = {ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none"},
		Secondary = {ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none"},
		FCHealWeapon = true,
		FCHealKind = kind,
	}
	function SWEP:Initialize() self:SetHoldType("normal") end
	function SWEP:Deploy()
		if SERVER then
			local function play()
				if not IsValid(self) then return end
				local ply = self:GetOwner()
				local st = IsValid(ply) and ply.rem_fcheal
				local vm = IsValid(ply) and ply:GetViewModel()
				if not st or not IsValid(vm) then return end
				local id = vm:LookupSequence(st.seq)
				if id and id >= 0 then
					vm:SendViewModelMatchingSequence(id)
					vm:SetPlaybackRate(1)
				end
			end
			play()
			timer.Simple(0, play)
		end
		return true
	end
	function SWEP:PrimaryAttack() end
	function SWEP:SecondaryAttack() end
	function SWEP:Reload() end
	function SWEP:DrawWorldModel() end
	weapons.Register(SWEP, "rem_fcheal_" .. kind)
end
for kind, data in pairs(FH.Kinds) do Register(kind, data) end

function FH.IsHealing(ply)
	return IsValid(ply) and ply:GetNW2Bool("rem_fcheal", false)
end

-- пока лечится - не бьёт и не бегает
hook.Add("StartCommand", "rem_fcheal_lock", function(ply, cmd)
	if not FH.IsHealing(ply) then return end
	cmd:RemoveKey(IN_ATTACK)
	cmd:RemoveKey(IN_ATTACK2)
	cmd:RemoveKey(IN_SPEED)
	cmd:RemoveKey(IN_RELOAD)
end)
