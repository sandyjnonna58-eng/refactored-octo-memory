-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Assault Rifles). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "Honey Badger"
SWEP.Instructions = "Insurgency: Sandstorm. 7.62x39 mm"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_honeybadger.mdl"
SWEP.Primary.Ammo = "7.62x39 mm"
SWEP.Primary.ClipSize = 30
SWEP.Primary.DefaultClip = 30
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.075
SWEP.Primary.Damage = 50
SWEP.Primary.Force = 50
SWEP.Penetration = 15
SWEP.CustomShell = "762x39"
SWEP.ShellEject = "RifleShellEject"
SWEP.Primary.Sound = {"sandstorm/honeybadger/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/honeybadger/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/honeybadger/distant_01.ogg"
SWEP.ReloadSoundes = {"none", "sandstorm/honeybadger/foley/badger_foley_mag_out.ogg", "none", "sandstorm/honeybadger/foley/badger_foley_mag_in.ogg", "sandstorm/honeybadger/foley/badger_foley_charging_handle_pull.ogg", "none"}
SWEP.WorldPos = Vector(4.5, 0.22, -1.745)
SWEP.WorldAng = Angle(3.938, -95.85, -172.588)
SWEP.LocalMuzzlePos = Vector(20.917, 0.571, -0.496)
SWEP.LocalMuzzleAng = Angle(-3.129, 6.319, 172.214)
SWEP.ZoomPos = Vector(0, 1.498, 6.045)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(11.44, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 10
SWEP.Spray = {}
for i = 1, 30 do SWEP.Spray[i] = i <= 12 and Angle(-0.11, 0, 0) or Angle(-0.055, (i % 2 == 0) and 0.11 or -0.11, 0) end
