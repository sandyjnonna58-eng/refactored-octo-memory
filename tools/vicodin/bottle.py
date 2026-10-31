# Флакон викодина: та же геометрия, что в lua/weapons/weapon_hg_vicodin.lua (BuildBottle), для иконки.
# Запуск из корня репозитория: python3 tools/vicodin/bottle.py materials/entities/weapon_hg_vicodin.png
# Оси: начало координат - центр дна, z - вверх.
import sys, math, random
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

GLASS = (248, 158, 30, 105)                       # прозрачное оранжевое тело
SHINE = (255, 240, 210, 90)                       # блик на пластике
CAP, LABEL, INK, STRIPE = (240, 240, 236, 255), (246, 244, 236, 255), (70, 70, 74, 255), (200, 40, 40, 255)
PILLS = [(252, 214, 52, 255), (246, 188, 38, 255), (250, 200, 60, 255)]
L = np.array([0.45, -0.35, 0.82]); L /= np.linalg.norm(L)

def shade(col, n):
    k = 0.45 + 0.55 * max(0.0, float(np.dot(n, L)))
    return tuple(int(min(255, c * k)) for c in col[:3]) + (col[3],)

tris = []
def quad(a, b, c, d, col, n):
    s = shade(col, n); tris.append((a, b, c, s)); tris.append((a, c, d, s))

def cylinder(z0, z1, r, col, top=None, bottom=None, a0=0.0, a1=360.0, seg=24):
    for i in range(seg):
        u0 = math.radians(a0 + (a1 - a0) * i / seg); u1 = math.radians(a0 + (a1 - a0) * (i + 1) / seg)
        p0 = np.array([r*math.cos(u0), r*math.sin(u0)]); p1 = np.array([r*math.cos(u1), r*math.sin(u1)])
        n = np.array([math.cos((u0+u1)/2), math.sin((u0+u1)/2), 0])
        quad(np.array([*p0,z0]), np.array([*p1,z0]), np.array([*p1,z1]), np.array([*p0,z1]), col, n)
        if top: tris.append((np.array([0,0,z1]), np.array([*p0,z1]), np.array([*p1,z1]), shade(top, np.array([0,0,1]))))
        if bottom: tris.append((np.array([0,0,z0]), np.array([*p1,z0]), np.array([*p0,z0]), shade(bottom, np.array([0,0,-1]))))

def segment(p1, p2, thick, col, width=None):
    p1, p2 = np.array(p1, float), np.array(p2, float)
    d = p2 - p1; f = d / np.linalg.norm(d)
    side = np.cross(f, [0, 0, 1])
    if np.linalg.norm(side) < 1e-3: side = np.cross(f, [1, 0, 0])
    side /= np.linalg.norm(side); up = np.cross(side, f)
    w = (width or thick) / 2; t = thick / 2
    sx, ux = (-1, 1, 1, -1), (-1, -1, 1, 1)
    c = [p1 + side*sx[i]*w + up*ux[i]*t for i in range(4)]; e = [q + d for q in c]
    for i in range(4):
        j = (i + 1) % 4
        n = side*(sx[i]+sx[j]) + up*(ux[i]+ux[j]); n = n / (np.linalg.norm(n) or 1)
        quad(c[i], c[j], e[j], e[i], col, n)
    quad(c[0], c[3], c[2], c[1], col, -f); quad(e[0], e[1], e[2], e[3], col, f)

def pills():
    # таблетки-капсулы внутри, раскиданы как попало (детерминированно - и в игре, и на иконке одинаково)
    rnd = random.Random(7)
    out = []
    for i in range(24):
        a = rnd.uniform(0, 2*math.pi); rr = rnd.uniform(0, 0.8)
        cx, cy, cz = rr*math.cos(a), rr*math.sin(a), 0.3 + (i // 4) * 0.42 + rnd.uniform(-0.12, 0.12)
        da = rnd.uniform(0, 2*math.pi); tilt = rnd.uniform(-0.5, 0.5)
        d = np.array([math.cos(da)*0.5, math.sin(da)*0.5, tilt*0.5])
        out.append(((cx, cy, cz), d, PILLS[i % 3]))
    return out

def build():
    tris.clear()
    for c, d, col in pills():
        c = np.array(c); segment(c - d, c + d, 0.42, col, 0.5)
    # этикетка: белая лента с окошком, красная полоса сверху, строчки "текста"
    # этикетка только на задней половине: спереди видно таблетки
    cylinder(1.3, 3.6, 1.49, LABEL, a0=-95, a1=95, seg=20)
    cylinder(3.25, 3.6, 1.5, STRIPE, a0=-95, a1=95, seg=20)
    for z, a0, a1 in ((2.85, -60, 70), (2.5, -60, 45), (2.15, -60, 75), (1.7, -60, 20)):
        cylinder(z - 0.09, z + 0.09, 1.505, INK, a0=a0, a1=a1, seg=10)
    # крышка
    cylinder(4.85, 6.0, 1.58, CAP, top=CAP)
    cylinder(4.6, 4.85, 1.2, GLASS)
    # прозрачное тело - последним, поверх таблеток
    cylinder(0.0, 4.6, 1.45, GLASS, top=None, bottom=GLASS)
    # блик: узкая светлая полоса на пластике
    cylinder(0.4, 4.3, 1.46, SHINE, a0=200, a1=214, seg=2)
    return tris

def render(path, size=512):
    build()
    yaw, pitch = math.radians(180), math.radians(18)
    def cam(p):
        x, y, z = p
        x, y = x*math.cos(yaw) - y*math.sin(yaw), x*math.sin(yaw) + y*math.cos(yaw)
        x, z = x*math.cos(pitch) + z*math.sin(pitch), -x*math.sin(pitch) + z*math.cos(pitch)
        return np.array([x, y, z])
    pts = [(np.array([cam(a), cam(b), cam(c)]), col) for a, b, c, col in tris]
    allp = np.concatenate([p for p, _ in pts]); ys, zs = allp[:, 1], allp[:, 2]
    S = 4; W = size * S
    sc = W * 0.86 / max(ys.max()-ys.min(), zs.max()-zs.min())
    cy, cz = (ys.max()+ys.min())/2, (zs.max()+zs.min())/2
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    for p, col in sorted(pts, key=lambda t: t[0][:, 0].mean()):
        poly = [(W/2 - (q[1]-cy)*sc, W/2 - (q[2]-cz)*sc) for q in p]
        layer = Image.new("RGBA", (W, W), (0, 0, 0, 0)); ImageDraw.Draw(layer).polygon(poly, fill=col)
        img.alpha_composite(layer) if col[3] < 255 else ImageDraw.Draw(img).polygon(poly, fill=col)
    img = img.resize((size, size), Image.LANCZOS)
    a = img.split()[3].filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(3))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0)); out.paste((0, 0, 0, 140), (0, 0), a)
    out.alpha_composite(img); out.save(path)

if __name__ == "__main__":
    render(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 512)
