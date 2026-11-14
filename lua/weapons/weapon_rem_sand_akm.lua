-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.PrintName = "AKM"
SWEP.Instructions = "Insurgency: Sandstorm. 7.62x39 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_akm.mdl"
SWEP.Primary.Ammo = "7.62x39 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.1
SWEP.Primary.Damage = 50
SWEP.Primary.Force = 50
SWEP.Penetration = 15
SWEP.CustomShell = "762x39"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/akm/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/akm/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/akm/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/akm/foley/akm_foley_mag_out.ogg", "none", "sandstorm/akm/foley/akm_foley_mag_in.ogg", "sandstorm/akm/foley/akm_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, -0.566, 1.101)
SWEP.WorldAng = Angle(13.586, 6.049, -178.332)
SWEP.LocalMuzzlePos = Vector(24.787, -3.263, 1.251)
SWEP.LocalMuzzleAng = Angle(-13.684, -5.821, 179.752)
SWEP.ZoomPos = Vector(0, 0.712, 6.437)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(13.52, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 12
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.11, 0, 0) or Angle(-0.055, (i % 2 == 0) and 0.11 or -0.11, 0) end
