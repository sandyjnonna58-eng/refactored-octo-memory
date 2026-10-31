# Пояс смертника: та же геометрия, что в lua/weapons/weapon_suicidevest.lua (BuildVest), для иконки.
# Запуск из корня репозитория: python3 tools/suicide_vest/vest.py materials/entities/weapon_suicidevest.png
# Оси как у бронежилетов на кости Spine2: x - вперёд (грудь), y - влево, z - вверх.
import sys, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

RED, CAP, TAPE = (185, 38, 28), (214, 196, 160), (24, 24, 24)
BOX, LED, SCREEN = (38, 38, 40), (255, 30, 20), (60, 230, 90)
KHAKI, WIRES = (98, 88, 62), [(220, 30, 30), (40, 80, 230), (230, 200, 40)]
L = np.array([0.45, 0.35, 0.82]); L /= np.linalg.norm(L)

def shade(col, n):
    k = 0.42 + 0.58 * max(0.0, float(np.dot(n, L)))
    return tuple(int(min(255, c * k)) for c in col)

tris = []  # (p1, p2, p3, color)

def quad(a, b, c, d, col, n):
    s = shade(col, n)
    tris.append((a, b, c, s)); tris.append((a, c, d, s))

def box(mn, mx, col):
    x0, y0, z0 = mn; x1, y1, z1 = mx
    P = lambda x, y, z: np.array([x, y, z], float)
    quad(P(x1,y0,z0),P(x1,y1,z0),P(x1,y1,z1),P(x1,y0,z1),col,np.array([1,0,0]))
    quad(P(x0,y0,z0),P(x0,y0,z1),P(x0,y1,z1),P(x0,y1,z0),col,np.array([-1,0,0]))
    quad(P(x0,y1,z0),P(x0,y1,z1),P(x1,y1,z1),P(x1,y1,z0),col,np.array([0,1,0]))
    quad(P(x0,y0,z0),P(x1,y0,z0),P(x1,y0,z1),P(x0,y0,z1),col,np.array([0,-1,0]))
    quad(P(x0,y0,z1),P(x1,y0,z1),P(x1,y1,z1),P(x0,y1,z1),col,np.array([0,0,1]))
    quad(P(x0,y0,z0),P(x0,y1,z0),P(x1,y1,z0),P(x1,y0,z0),col,np.array([0,0,-1]))

def cylinder(cx, cy, z0, z1, r, col, cap, seg=10):
    for i in range(seg):
        a0, a1 = 2*math.pi*i/seg, 2*math.pi*(i+1)/seg
        p0 = np.array([cx+r*math.cos(a0), cy+r*math.sin(a0)]); p1 = np.array([cx+r*math.cos(a1), cy+r*math.sin(a1)])
        n = np.array([math.cos((a0+a1)/2), math.sin((a0+a1)/2), 0])
        quad(np.array([*p0,z0]),np.array([*p1,z0]),np.array([*p1,z1]),np.array([*p0,z1]),col,n)
        c = np.array([cx,cy,z1]); tris.append((c,np.array([*p0,z1]),np.array([*p1,z1]),shade(cap,np.array([0,0,1]))))
        c = np.array([cx,cy,z0]); tris.append((c,np.array([*p1,z0]),np.array([*p0,z0]),shade(cap,np.array([0,0,-1]))))

def segment(p1, p2, thick, col, width=None):
    # брусок вдоль отрезка (провод, лямка)
    p1, p2 = np.array(p1, float), np.array(p2, float)
    d = p2 - p1; ln = np.linalg.norm(d); f = d / ln
    side = np.cross(f, [1, 0, 0]);
    if np.linalg.norm(side) < 1e-3: side = np.cross(f, [0, 0, 1])
    side /= np.linalg.norm(side); up = np.cross(side, f)
    w = (width or thick) / 2; t = thick / 2
    c = [p1 + side*sx*w + up*ux*t for sx, ux in ((-1,-1),(1,-1),(1,1),(-1,1))]
    e = [q + d for q in c]
    for i in range(4):
        j = (i + 1) % 4
        n = (side*((-1,1,1,-1)[i]+(-1,1,1,-1)[j]) + up*((-1,-1,1,1)[i]+(-1,-1,1,1)[j])); n = n/ (np.linalg.norm(n) or 1)
        quad(c[i], c[j], e[j], e[i], col, n)

def build():
    tris.clear()
    # задняя панель и лямки через плечи
    box((-7.4, -8.6, -3.6), (-6.4, 8.6, 3.8), KHAKI)
    for y in (-4.6, 4.6):
        segment((6.6, y, 4.2), (2.0, y * 1.05, 11.6), 0.6, KHAKI, 2.2)
        segment((2.0, y * 1.05, 11.6), (-4.0, y * 1.05, 11.0), 0.6, KHAKI, 2.2)
        segment((-4.0, y * 1.05, 11.0), (-6.9, y, 3.8), 0.6, KHAKI, 2.2)
    # шашки: спереди 7, по бокам по 3
    for i in range(7):
        y = -6.6 + i * 2.2
        cylinder(7.4, y, -4.6, 4.6, 1.05, RED, CAP)
    for s in (-1, 1):
        for i in range(3):
            cylinder(4.6 - i * 3.3, s * 9.2, -4.4, 4.4, 1.05, RED, CAP)
    # изолента
    for z in (-2.9, 2.6):
        box((6.1, -7.9, z - 0.6), (8.6, 7.9, z + 0.6), TAPE)
        for s in (-1, 1):
            box((-2.8, s * 9.2 - 1.25, z - 0.55), (5.8, s * 9.2 + 1.25, z + 0.55), TAPE)
    # детонатор: коробка, огонёк, экранчик
    box((8.4, -2.4, -1.6), (10.3, 2.4, 1.6), BOX)
    box((10.3, 1.0, 0.5), (10.7, 1.6, 1.1), LED)
    box((10.3, -1.8, -0.7), (10.5, 0.3, 0.5), SCREEN)
    # провода от детонатора к шашкам
    for k, (col, y0, y1, z1) in enumerate(zip(WIRES, (-1.8, 0.0, 1.8), (-5.5, 0.4, 5.7), (4.0, 4.4, 3.9))):
        mid = (10.0, (y0 + y1) / 2, 3.2)
        segment((10.2, y0, 1.6), mid, 0.32, col)
        segment(mid, (8.5, y1, z1), 0.32, col)
    return tris

def render(path, size=512):
    tris = build()
    yaw, pitch = math.radians(-32), math.radians(14)
    def cam(p):
        x, y, z = p
        x, y = x*math.cos(yaw) - y*math.sin(yaw), x*math.sin(yaw) + y*math.cos(yaw)
        x, z = x*math.cos(pitch) + z*math.sin(pitch), -x*math.sin(pitch) + z*math.cos(pitch)
        return np.array([x, y, z])
    pts = [(np.array([cam(a), cam(b), cam(c)]), col) for a, b, c, col in tris]
    allp = np.concatenate([p for p, _ in pts]); ys, zs = allp[:,1], allp[:,2]
    S = 4; W = size * S
    sc = W * 0.86 / max(ys.max()-ys.min(), zs.max()-zs.min())
    cy, cz = (ys.max()+ys.min())/2, (zs.max()+zs.min())/2
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    for p, col in sorted(pts, key=lambda t: t[0][:,0].mean()):   # дальние первыми
        poly = [(W/2 - (q[1]-cy)*sc, W/2 - (q[2]-cz)*sc) for q in p]
        d.polygon(poly, fill=col + (255,))
    img = img.resize((size, size), Image.LANCZOS)
    a = img.split()[3].filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(3))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0)); out.paste((0, 0, 0, 150), (0, 0), a)
    out.alpha_composite(img); out.save(path)

if __name__ == "__main__":
    render(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 512)
