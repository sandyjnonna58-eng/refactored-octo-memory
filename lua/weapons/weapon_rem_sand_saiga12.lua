-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (Shotguns). Модель и звуки - из пака,
-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.
SWEP.Base = "weapon_rem_sand_rifle"
SWEP.Spawnable = true
SWEP.Category = "Sandstorm (Z-City)"
SWEP.AdminOnly = false
SWEP.PrintName = "Saiga-12K"
SWEP.Instructions = "Insurgency: Sandstorm. 12/70 gauge"
SWEP.WorldModel = "models/weapons/sandswep/w_sand_saiga12.mdl"
SWEP.Primary.Ammo = "12/70 gauge"
SWEP.Primary.ClipSize = 5
SWEP.Primary.DefaultClip = 5
SWEP.Primary.Automatic = false
SWEP.Primary.Wait = 0.2
SWEP.Primary.Damage = 16
SWEP.Primary.Force = 12
SWEP.Penetration = 7
SWEP.CustomShell = "12x70"
SWEP.ShellEject = "ShotgunShellEject"
SWEP.NumBullet = 8
SWEP.Primary.Spread = Vector(0.01, 0.01, 0.01)
SWEP.PPSMuzzleEffect = "pcf_jack_mf_mshotgun"
SWEP.Primary.Sound = {"sandstorm/saiga12/shot_01.ogg", 90, 95, 105}
SWEP.SupressedSound = {"sandstorm/saiga12/shot_supp_01.ogg", 70, 95, 105}
SWEP.DistSound = "sandstorm/saiga12/distant_01.ogg"
SWEP.WorldPos = Vector(4.5, 0.925, 0.719)
SWEP.WorldAng = Angle(15.444, -89.272, 156.955)
SWEP.LocalMuzzlePos = Vector(25.99, -3.387, 1.495)
SWEP.LocalMuzzleAng = Angle(-13.889, -6.859, -156.02)
SWEP.ZoomPos = Vector(0, 2.203, 5.658)
SWEP.RHPos = Vector(1, -5, 3.5)
SWEP.RHAng = Angle(0, -15, 90)
SWEP.LHPos = Vector(14.19, 0, -3.7)
SWEP.LHAng = Angle(-100, -90, -90)
SWEP.SandLHPos = SWEP.LHPos
SWEP.lengthSub = 12
SWEP.Spray = {}
for i = 1, 20 do SWEP.Spray[i] = Angle(-0.4, (i % 2 == 0) and 0.2 or -0.2, 0) end
