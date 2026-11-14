-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Shotguns). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "USAS-12"
SWEP.Instructions = "Insurgency: Sandstorm. 12/70 gauge"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_usas12.mdl"
SWEP.Primary.Ammo = "12/70 gauge"
SWEP.Primary.ClipSize = 10
SWEP.Primary.DefaultClip = 10
SWEP.Primary.Automatic = true
SWEP.Primary.Wait = 0.167
SWEP.Primary.Damage = 16
SWEP.Primary.Force = 12
SWEP.Penetration = 7
SWEP.CustomShell = "12x70"
SWEP.ShellEject = "ShotgunShellEject"
SWEP.NumBullet = 8
SWEP.Primary.Spread = Vector(0.01, 0.01, 0.01)
SWEP.PPSMuzzleEffect = "pcf_jack_mf_mshotgun"
SWEP.Primary.Sound = {"sandstorm/usas12/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/usas12/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/usas12/distant_01.ogg"
SWEP.WorldPos = Vector(4.5, 0.379, 1.206)
SWEP.WorldAng = Angle(6.039, -8.285, -172.693)
SWEP.LocalMuzzlePos = Vector(27.254, 1.977, -2.217)
SWEP.LocalMuzzleAng = Angle(-4.872, 9.017, 171.871)
SWEP.ZoomPos = Vector(0, 1.657, 9.198)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(14.82, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 13
SWEP.Spray = {}
for i = 1, 20 do SWEP.Spray[i] = Angle(-0.4, (i % 2 == 0) and 0.2 or -0.2, 0) end
