# Генератор оружия Z-City из паков Мастерской «Sandstorm SWEPs» (пистолеты / автоматы / дробовики).
# В репозиторий кладём ТОЛЬКО Lua: модели и звуки берутся из паков, которые игроки качают с сервера (Мастерская).
#
# Запуск: python3 -I tools/sandstorm/make.py <папка с распакованными паками (lua + models/*.mdl/.vvd)>
# Что делает:
#   - читает weapon_sand_*.lua паков: название, модель, обойма, темп, режимы огня, звуки выстрела/перезарядки;
#   - по мировой модели (w_*.mdl + .vvd, пространство кисти R_Hand) считает ось ствола (PCA + выравнивание по верху
#     затвора/цевья), дуло (attachment "muzzle" или передний срез), высоту прицела;
#   - переводит это в поля homigrad_base: WorldAng (поворот модели так, чтобы ствол смотрел в прицел и стоял ровно),
#     WorldPos (ствол на той же высоте/сбоку, что у шаблона Z-City), LocalMuzzlePos/Ang, ZoomPos, LHPos (цевьё);
#   - пишет lua/weapons/weapon_rem_sand_<имя>.lua (основы - weapon_rem_sand_pistol / _rifle / _shotgun).
import sys, os, re, glob, math, struct

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "lua", "weapons")

# ---------------- линейная алгебра (3x3, списки) ----------------
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def sub(a, b): return [x - y for x, y in zip(a, b)]
def add(a, b): return [x + y for x, y in zip(a, b)]
def mul(a, k): return [x * k for x in a]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def norm(a):
    l = math.sqrt(dot(a, a)); return [x / l for x in a]
def mat_cols(f, l, u): return [[f[0], l[0], u[0]], [f[1], l[1], u[1]], [f[2], l[2], u[2]]]
def mm(A, B): return [[sum(A[i][k]*B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
def tr(A): return [[A[j][i] for j in range(3)] for i in range(3)]
def mv(A, v): return [dot(A[i], v) for i in range(3)]
RX = [[1, 0, 0], [0, -1, 0], [0, 0, -1]]  # поворот на 180 вокруг оси вперёд (так делает homigrad_base)

def angles(M):
    # матрица (столбцы: вперёд, влево, вверх) -> Angle(pitch, yaw, roll) движка Source
    f = [M[0][0], M[1][0], M[2][0]]; l = [M[0][1], M[1][1], M[2][1]]; u = [M[0][2], M[1][2], M[2][2]]
    xy = math.hypot(f[0], f[1])
    if xy > 1e-3:
        yaw = math.degrees(math.atan2(f[1], f[0])); pitch = math.degrees(math.atan2(-f[2], xy))
        roll = math.degrees(math.atan2(l[2], u[2]))
    else:
        yaw = math.degrees(math.atan2(-l[0], l[1])); pitch = math.degrees(math.atan2(-f[2], xy)); roll = 0
    return [round(pitch, 3), round(yaw, 3), round(roll, 3)]

def pca(V):
    n = len(V); c = mul([sum(v[i] for v in V) for i in range(3)], 1 / n)
    C = [[0] * 3 for _ in range(3)]
    for v in V:
        d = sub(v, c)
        for i in range(3):
            for j in range(3): C[i][j] += d[i] * d[j]
    # степенной метод: первая и вторая главные оси
    def power(C, ortho=None):
        x = [1.0, 0.31, 0.17]
        for _ in range(200):
            if ortho: x = sub(x, mul(ortho, dot(x, ortho)))
            x = norm(mv(C, x))
        return x
    a1 = power(C); a2 = power(C, a1)
    return c, a1, a2

# ---------------- модели ----------------
def load_model(mdl):
    d = open(mdl, "rb").read()
    I = lambda o: struct.unpack_from("<i", d, o)[0]
    atts = {}
    na, ai = I(240), I(244)
    for i in range(na):  # кость одна (R_Hand) и в начале координат - точка в пространстве модели
        a = ai + i * 92
        name = d[a + I(a):d.index(b"\0", a + I(a))].decode().lower()
        m = struct.unpack_from("<12f", d, a + 12)
        atts[name] = [m[3], m[7], m[11]]
    vvd = open(mdl[:-4] + ".vvd", "rb").read()
    n = struct.unpack_from("<i", vvd, 16)[0]; vs = struct.unpack_from("<i", vvd, 56)[0]
    V = [list(struct.unpack_from("<3f", vvd, vs + k * 48 + 16)) for k in range(n)]
    return V, atts

def fit_slope(pts):
    # МНК: y = a + b*x, вернуть b
    n = len(pts)
    if n < 2: return 0
    mx = sum(p[0] for p in pts) / n; my = sum(p[1] for p in pts) / n
    sxx = sum((p[0]-mx)**2 for p in pts)
    return sum((p[0]-mx)*(p[1]-my) for p in pts) / sxx if sxx > 1e-6 else 0

def dist3(a, b): return math.sqrt(dot(sub(a, b), sub(a, b)))

def theil_sen(pts):
    # устойчивый наклон: медиана наклонов всех пар (мушка, выступы не тянут ось)
    sl = []
    for a in range(len(pts)):
        for b in range(a + 1, len(pts)):
            dx = pts[b][0] - pts[a][0]
            if abs(dx) > 1e-6: sl.append((pts[b][1] - pts[a][1]) / dx)
    sl.sort()
    return sl[len(sl) // 2] if sl else 0

def geometry(V, atts, ref=None, span_ref=10, method=None):
    import numpy as np
    A = np.array(V)
    c = A.mean(0)
    w, E = np.linalg.eigh(np.cov((A - c).T))
    lat = list(E[:, 0])            # самая тонкая ось - поперёк ружья (оно почти плоское)
    f = list(E[:, 2])              # самая длинная - вдоль
    muz = atts.get("muzzle")
    if muz:
        if dot(sub(muz, list(c)), f) < 0: f = mul(f, -1)
    else:
        t = A @ np.array(f); lo, hi = t.min(), t.max()
        e2 = np.cross(np.array(f), np.array(lat))
        def spread(mask):
            S = A[mask] @ e2
            return S.max() - S.min() if len(S) else 0
        if spread(t > hi - (hi - lo) * 0.12) > spread(t < lo + (hi - lo) * 0.12): f = mul(f, -1)
    # наклон в плоскости ружья: перебором угла - передняя часть (ствол, затвор, цевьё) - труба/брусок, её высота
    # минимальна, когда ось лежит ровно (верх затвора и мушки не тянут, как при подгонке по верхней линии)
    # все модели пака держатся кистью одинаково: если есть образец (ось ствола и "верх" удачной модели того же
    # класса) - бок берём так, чтобы верх смотрел туда же, а наклон ищем не дальше 25 градусов от образца
    span = 40
    if ref:
        if dot(cross(f, lat), ref[1]) < 0 and dot(f, ref[0]) > 0: lat = mul(lat, -1)
        if dot(f, ref[0]) < 0: f = mul(f, -1)
        if dot(cross(f, lat), ref[1]) < 0: lat = mul(lat, -1)
        f = list(ref[0]); span = span_ref
    f = norm(sub(f, mul(lat, dot(f, lat))))
    e1 = np.array(f); e2 = np.cross(np.array(lat), e1)
    best = None
    for k in range(-span * 2, span * 2 + 1):
        th = math.radians(k * 0.5)
        fv = e1 * math.cos(th) + e2 * math.sin(th)
        uv = np.cross(fv, np.array(lat))
        t = A @ fv; h = A @ uv
        hi = t.max(); lo = t.min(); fr = 0.2 if (hi - lo) < 14 else 0.3  # у пистолета спереди - только затвор, без скобы
        front = hi - (hi - lo) * fr
        if muz: front = min(front, float(np.dot(np.array(muz), fv)) - (hi - lo) * fr)
        sel = h[t > front]
        if len(sel) < 10: continue
        spread = np.percentile(sel, 98) - np.percentile(sel, 2)
        if best is None or spread < best[0]: best = (spread, list(fv))
    if best: f = best[1]
    # надёжнее перебора - две точки на оси канала: дуло и окно выброса гильзы (оно на высоте канала ствола)
    shell = atts.get("shell")
    if method == "search":
        pass  # только перебор (у этих моделей пара точек / средняя линия врут - проверено картинкой)
    elif muz and shell and dist3(muz, shell) > 6.5:
        d = sub(muz, shell); d = sub(d, mul(lat, dot(d, lat)))
        f = norm(d)
    elif best and method != "pistol":
        # нет пары точек: ось по средней линии передней части (ствол/цевьё симметричны вокруг канала)
        for _ in range(4):
            u_ = np.array(cross(f, list(lat))); fv = np.array(f)
            t = A @ fv; h = A @ u_; hi = t.max(); L = hi - t.min()
            pts = []
            for k in range(6):
                a0 = hi - L * (0.02 + 0.025 * (k + 1)); b0 = hi - L * (0.02 + 0.025 * k)
                sel = h[(t >= a0) & (t < b0)]
                if len(sel) >= 4: pts.append(((a0 + b0) / 2, (np.percentile(sel, 10) + np.percentile(sel, 90)) / 2))
            sl = theil_sen(pts)
            if abs(sl) < 2e-3: break
            f = norm(add(f, mul(list(u_), sl)))
    if not ref:
        # без образца: рукоять и магазин уходят от ствола вниз дальше, чем прицел вверх
        u = cross(f, list(lat))
        P = A @ np.array(mat_cols(f, list(lat), u))
        mz = mv(tr(mat_cols(f, list(lat), u)), muz)[2] if muz else float(np.percentile(P[P[:, 0] > P[:, 0].max() - 1][:, 2], 50))
        if (mz - P[:, 2].min()) < (P[:, 2].max() - mz):
            lat = mul(lat, -1)
    l = list(lat); u = cross(f, l)
    R = mat_cols(f, l, u)
    P = A @ np.array(R)
    m = mv(tr(R), muz) if muz else None
    lo, hi = P[:, 0].min(), P[:, 0].max(); L = hi - lo
    if m is None:
        S = P[P[:, 0] > hi - L * 0.05]
        m = [hi, (S[:, 1].min() + S[:, 1].max()) / 2, (S[:, 2].min() + S[:, 2].max()) / 2]
    cl = P[(np.abs(P[:, 1] - m[1]) < 0.6) & (P[:, 0] > lo + L * 0.05) & (P[:, 0] < m[0] - 0.3)]
    sight = float(cl[:, 2].max()) if len(cl) else m[2] + 1
    return R, [float(x) for x in m], sight, float(lo), float(hi), P

# ---------------- данные паков ----------------
AMMO = {  # калибр Z-City, гильза, выброс, урон, сила, пробитие
    "9x19": ("9x19 mm Parabellum", "9x19", "EjectBrass_9mm", 23, 25, 7),
    "45": (".45 ACP", "45acp", "EjectBrass_9mm", 25, 25, 7),
    "50ae": (".50 Action Express", "50ae", "EjectBrass_9mm", 40, 30, 11),
    "9x18": ("9x18 mm", "9x18", "EjectBrass_9mm", 20, 20, 5),
    "357": (".357 Magnum", "", "", 45, 77, 12),
    "762x25": ("7.62x25 mm", "9x19", "EjectBrass_9mm", 35, 35, 7),
    "765": ("7.65x17 mm", "9x19", "EjectBrass_9mm", 17, 25, 3),
    "556": ("5.56x45 mm", "556x45", "RifleShellEject", 35, 35, 11),
    "545": ("5.45x39 mm", "545x39", "RifleShellEject", 35, 35, 11),
    "762x39": ("7.62x39 mm", "762x39", "RifleShellEject", 50, 50, 15),
    "9x39": ("9x39 mm", "762x39", "RifleShellEject", 42, 42, 15),
    "12": ("12/70 gauge", "12x70", "ShotgunShellEject", 16, 12, 7),
    "23": ("23x75 SH10", "23x75sh10", "ShotgunShellEject", 20, 15, 8),
}
CAL = {
    "browning": "9x19", "deagle": "50ae", "glock17": "9x19", "l106a1": "9x19", "m1911": "45", "m45a1": "45", "m9": "9x19",
    "makarov": "9x18", "mr73": "357", "pf940": "9x19", "tariq": "9x19", "tk33": "762x25", "vanta9": "9x19", "welrod": "765",
    "ak74": "545", "aks74u": "545", "akm": "762x39", "akalpha": "762x39", "honeybadger": "762x39", "asval": "9x39",
    "ks23": "23", "ksg": "12", "m870": "12", "toz194": "12", "saiga12": "12", "usas12": "12",
}
RECOIL = {"556": 0.07, "545": 0.07, "762x39": 0.11, "9x39": 0.09, "12": 0.22}
PUMP = {"ks23", "ksg", "m870", "toz194"}
NICE = {"saiga12": "Saiga-12K", "honeybadger": "Honey Badger"}
PISTOL_T = dict(W=(4.5, -1.3, -2), M=(6, 0, 2.1), RH=(10, -4.5, 3), RHA=(0, -5, 90), LH=(-1.2, -1.4, -2.5), LHA=(5, 9, -100))
RIFLE_T = dict(W=(4.5, -1, -0.2), M=(30.901, 0.278, 3.398), RH=(1, -5, 3.5), RHA=(0, -15, 90), LH=(17, 0, -3.7), LHA=(-100, -90, -90))

def field(s, pat, default=None):
    m = re.search(pat, s)
    return m.group(1) if m else default

def first_sound(s, key):
    m = re.search(key + r'\s*=\s*\{\s*"([^"]+)"', s)
    return m.group(1) if m else None

def foley(s, words):
    for w in words:
        m = re.search(r'"(sandstorm/[^"]*' + w + r'[^"]*\.ogg)"', s, re.I)
        if m: return m.group(1)
    return None

def V3(v): return "Vector(%s)" % ", ".join(("%.3f" % x).rstrip("0").rstrip(".") if "." in "%.3f" % x else str(x) for x in v)
def A3(a): return "Angle(%s)" % ", ".join(("%.3f" % x).rstrip("0").rstrip(".") for x in a)

files = sorted(glob.glob(os.path.join(SRC, "**", "lua", "weapons", "weapon_sand_*.lua"), recursive=True))
models = {os.path.basename(p)[:-4]: p for p in glob.glob(os.path.join(SRC, "**", "models", "**", "w_*.mdl"), recursive=True)}
shotgun_snd = ""
for p in glob.glob(os.path.join(SRC, "**", "sandswep_shotguns", "sounds.lua"), recursive=True):
    shotgun_snd += open(p, encoding="utf-8", errors="ignore").read()
src_by = {os.path.basename(f)[12:-4]: open(f, encoding="utf-8", errors="ignore").read() for f in files}
made = []
DIAG = []
# образцы осей: модели, у которых ось и верх надёжно определяются сами (проверено картинкой)
# способ оси для моделей, где общий выбор ошибается (по картинке tools/sandstorm диагностики):
# search - только перебор по толщине передней части; copy - взять ось у модели того же семейства
METHOD = {"akalpha": "search", "honeybadger": "search", "qts11": "search", "m870": "search", "toz194": "search", "ks23": "search",
          "m16a2": ("copy", "m16a4")}
REF_MODEL = {"pistol": "browning", "rifle": "ak74", "shotgun": "ak74"}
REFS = {}
def ref_for(kind):
    nm = REF_MODEL[kind]
    if nm in REFS: return REFS[nm]
    srcf = [f for f in files if os.path.basename(f) == "weapon_sand_%s.lua" % nm][0]
    wmr = re.search(r'SWEP\.WorldModel\s*=\s*"([^"]+)"', open(srcf, encoding="utf-8", errors="ignore").read()).group(1)
    Vr, ar = load_model(models[os.path.basename(wmr)[:-4]])
    Rr = geometry(Vr, ar)[0]
    REFS[nm] = ([Rr[0][0], Rr[1][0], Rr[2][0]], [Rr[0][2], Rr[1][2], Rr[2][2]])
    return REFS[nm]
for name, s in sorted(src_by.items()):
    base_name = field(s, r'SWEP\.Base\s*=\s*"weapon_sand_(\w+)"')
    if base_name and base_name != "base":  # наследник (Galil SAR <- Galil): недостающее - из родителя
        s = s + "\n" + src_by.get(base_name, "")
    subcat = field(s, r'SWEP\.SubCategory\s*=\s*"([^"]+)"', "")
    wm = field(s, r'SWEP\.WorldModel\s*=\s*"([^"]+)"')
    hold = field(s, r'SWEP\.HoldType\s*=\s*"([^"]+)"', "ar2")
    kind = "pistol" if hold in ("pistol", "revolver") else ("shotgun" if name in PUMP else "rifle")
    mdl = models.get(os.path.basename(wm)[:-4]) if wm else None
    if not mdl:
        print("skip (no model):", name); continue
    V, atts = load_model(mdl)
    meth = METHOD.get(name, "pistol" if kind == "pistol" else None)
    if isinstance(meth, tuple):
        # та же модель другой версии: ось как у образца, точки - свои
        srcf = [f for f in files if os.path.basename(f) == "weapon_sand_%s.lua" % meth[1]][0]
        wm2 = re.search(r'SWEP\.WorldModel\s*=\s*"([^"]+)"', open(srcf, encoding="utf-8", errors="ignore").read()).group(1)
        V2, a2 = load_model(models[os.path.basename(wm2)[:-4]])
        R2 = geometry(V2, a2, ref_for(kind), 25)[0]
        R, m, sight, lo, hi, P = geometry(V, atts, ([R2[0][0], R2[1][0], R2[2][0]], [R2[0][2], R2[1][2], R2[2][2]]), 0, "search")
    else:
        R, m, sight, lo, hi, P = geometry(V, atts, ref_for(kind), 6 if kind == "pistol" else 25, meth)
    DIAG.append((name, P, m, sight))
    T = PISTOL_T if kind == "pistol" else RIFLE_T
    # WorldAng: модель повернуть так, чтобы M * R = прицел;  M = прицел * RX * W * RX  ->  W = RX * R^-1 * RX
    W = mm(mm(RX, tr(R)), RX)
    wang = angles(W)
    # WorldPos: кисть - как у шаблона по длине, ствол - на той же высоте и сбоку, что у шаблона
    wpos = [T["W"][0], T["W"][1] - T["M"][1] + m[1], T["W"][2] - T["M"][2] + m[2]]
    mang = angles(R)
    zoom = [0, m[1], sight]
    lh = list(T["LH"])
    if kind != "pistol": lh[0] = round(max(m[0] * 0.55, 6), 2)  # левая рука - на цевьё
    cal = AMMO[CAL.get(name, "12" if kind == "shotgun" else "556")]
    clip = int(field(s, r'Primary\.ClipSize\s*=\s*(\d+)', "30"))
    rpm = float(field(s, r'Primary\.RPM\s*=\s*([\d.]+)', "600"))
    modes = field(s, r'SWEP\.FireModes\s*=\s*\{([^}]*)\}', "")
    auto = '"auto"' in modes
    close = first_sound(s, r'\bClose') or first_sound(s, r'CloseSuppressed')
    dist = first_sound(s, r'\bDistant')
    pname = NICE.get(name, field(s, r'SWEP\.PrintName\s*=\s*"([^"]+)"', name.upper()))
    shot12 = CAL.get(name) in ("12", "23")
    L = []
    w = L.append
    w("-- Сгенерировано tools/sandstorm/make.py из пака Мастерской «Sandstorm SWEPs» (%s). Модель и звуки - из пака," % (subcat or kind))
    w("-- в сборке только Lua. Положение модели посчитано по её геометрии; прицел можно подогнать hg_setzoompos.")
    w('SWEP.Base = "weapon_rem_sand_%s"' % kind)
    w("SWEP.Spawnable = true")
    # категорию и AdminOnly пишем в каждом файле: меню спавна (list "Weapon") берёт их из таблицы самого оружия, без
    # наследования от основы - иначе ствол уезжает в «Прочее»
    w('SWEP.Category = "Sandstorm (Z-City)"')
    w("SWEP.AdminOnly = false")
    w('SWEP.PrintName = "%s"' % pname)
    w('SWEP.Instructions = "Insurgency: Sandstorm. %s"' % cal[0])
    w('SWEP.WorldModel = "%s"' % wm)
    w('SWEP.Primary.Ammo = "%s"' % cal[0])
    w("SWEP.Primary.ClipSize = %d" % clip)
    w("SWEP.Primary.DefaultClip = %d" % clip)
    w("SWEP.Primary.Automatic = %s" % ("true" if auto else "false"))
    w("SWEP.Primary.Wait = %s" % round(max(60 / rpm, 0.06 if kind != "pistol" else 0.1), 3))
    w("SWEP.Primary.Damage = %d" % cal[3])
    w("SWEP.Primary.Force = %d" % cal[4])
    w("SWEP.Penetration = %d" % cal[5])
    w('SWEP.CustomShell = "%s"' % cal[1])
    w('SWEP.ShellEject = "%s"' % cal[2])
    if shot12:
        w("SWEP.NumBullet = 8")
        w("SWEP.Primary.Spread = Vector(0.01, 0.01, 0.01)")
        w('SWEP.PPSMuzzleEffect = "pcf_jack_mf_mshotgun"')
    if close: w('SWEP.Primary.Sound = {"%s", %d, 95, 105}' % (close, 85 if kind == "pistol" else 90))
    if close: w('SWEP.SupressedSound = {"%s", 70, 95, 105}' % (first_sound(s, r'CloseSuppressed') or close))
    if dist: w('SWEP.DistSound = "%s"' % dist)
    if kind == "shotgun":
        ins = foley(shotgun_snd + s, [name + r"[^\"]*shell_insert", "shell_insert", "insert_single"]) or foley(s, ["insert"])
        pump = foley(shotgun_snd + s, [name + r"[^\"]*pump_back", "pump_back", "bolt", "charging"])
        if ins: w('SWEP.ReloadSound = "%s"' % ins)
        if pump: w('SWEP.CockSound = "%s"' % pump)
    else:
        mo = foley(s, ["mag_out", "magout"]); mi = foley(s, ["mag_in", "magin"])
        bo = foley(s, ["charging_handle_pull", "bolt_back", "boltback", "slide_release", "bolt_release", "slide_forward", "slide"])
        if mo or mi:
            w('SWEP.ReloadSoundes = {"none", "%s", "none", "%s", "%s", "none"}' % (mo or "none", mi or "none", bo or "none"))
    w("SWEP.WorldPos = %s" % V3(wpos))
    w("SWEP.WorldAng = %s" % A3(wang))
    w("SWEP.LocalMuzzlePos = %s" % V3(m and mv(R, m)))
    w("SWEP.LocalMuzzleAng = %s" % A3(mang))
    w("SWEP.ZoomPos = %s" % V3(zoom))
    w("SWEP.RHPos = %s" % V3(T["RH"]))
    w("SWEP.RHAng = %s" % A3(T["RHA"]))
    w("SWEP.LHPos = %s" % V3(lh))
    w("SWEP.LHAng = %s" % A3(T["LHA"]))
    w("SWEP.SandLHPos = SWEP.LHPos")
    w("SWEP.lengthSub = %d" % (6 if kind == "pistol" else max(10, int(m[0] * 0.5))))
    if kind != "pistol" and not shot12:
        k = RECOIL.get(CAL.get(name, "556"), 0.07)
        w("SWEP.Spray = {}")
        w("for i = 1, %d do SWEP.Spray[i] = i <= 12 and Angle(-%s, 0, 0) or Angle(-%s, (i %% 2 == 0) and %s or -%s, 0) end" % (max(clip, 30), k, k * 0.5, k, k))
    if name == "saiga12" or name == "usas12":
        w("SWEP.Spray = {}")
        w("for i = 1, %d do SWEP.Spray[i] = Angle(-0.4, (i %% 2 == 0) and 0.2 or -0.2, 0) end" % max(clip, 20))
    if name == "mr73":
        w('SWEP.HoldType = "revolver"')
    open(os.path.join(OUT, "weapon_rem_sand_%s.lua" % name), "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")
    made.append((name, kind, pname, [round(x, 1) for x in m], round(sight, 2), wang))
for x in made: print(*x)
print(len(made), "weapons")
if os.environ.get("DIAG"):
    # картинка для проверки: сбоку (вперёд-вверх) и сверху (вперёд-влево), красная - ось ствола, синяя - линия прицела
    from PIL import Image, ImageDraw
    cols = 4; cw, ch = 420, 260
    img = Image.new("RGB", (cols * cw, ((len(DIAG) + cols - 1) // cols) * ch), (24, 24, 28)); d = ImageDraw.Draw(img)
    only = os.environ.get("DIAG_ONLY")
    if only: DIAG[:] = [x for x in DIAG if x[0] in only.split(",")]
    for i, (name, P, m, sight) in enumerate(DIAG):
        ox, oy = (i % cols) * cw, (i // cols) * ch
        sc = 300 / max(float(os.environ.get("DIAG_MIN", "36")), P[:, 0].max() - P[:, 0].min() + 6)
        x0 = ox + 60 - P[:, 0].min() * sc
        for (yy, axis, base) in ((oy + 95, 2, 1), (oy + 205, 1, 1)):
            for p in P[::1]:
                d.point((x0 + p[0] * sc, yy - p[axis] * sc), fill=(200, 200, 200))
            d.line((x0 + P[:, 0].min() * sc, yy - m[axis] * sc, x0 + m[0] * sc, yy - m[axis] * sc), fill=(255, 60, 60))
            d.ellipse((x0 + m[0] * sc - 3, yy - m[axis] * sc - 3, x0 + m[0] * sc + 3, yy - m[axis] * sc + 3), outline=(255, 220, 0))
            d.ellipse((x0 - 3, yy - 3, x0 + 3, yy + 3), outline=(0, 255, 0))
        d.line((ox, oy + 95 - sight * sc, ox + cw, oy + 95 - sight * sc), fill=(80, 120, 255))
        d.text((ox + 6, oy + 4), name, fill=(255, 230, 120))
    img.save(os.environ["DIAG"])
