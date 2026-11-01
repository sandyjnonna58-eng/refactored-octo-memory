# Иконки для weapon_fc3_*: силуэт по настоящей геометрии модели (.vvd вершины + .dx90.vtx треугольники),
# клинок стальной, рукоять тёмная. Запуск: python3 tools/fc3_icons/render.py <model без расширения> <рукоять до z> <out.png>
import sys, struct, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

def vvd(path):
    d = open(path, "rb").read()
    nv = struct.unpack("<i", d[16:20])[0]; vs = struct.unpack("<i", d[56:60])[0]
    P = np.array([struct.unpack("<3f", d[vs+i*48+16:vs+i*48+28]) for i in range(nv)])
    N = np.array([struct.unpack("<3f", d[vs+i*48+28:vs+i*48+40]) for i in range(nv)])
    return P, N

def vtx(path):
    d = open(path, "rb").read()
    i32 = lambda o: struct.unpack("<i", d[o:o+4])[0]
    tris = []
    nbp, bpo = i32(28), i32(32)
    for b in range(nbp):
        bp = bpo + b * 8
        for m in range(i32(bp)):
            mo = bp + i32(bp + 4) + m * 8
            lod = mo + i32(mo + 4)                         # только LOD 0
            for me in range(i32(lod)):
                mh = lod + i32(lod + 4) + me * 9
                for s in range(i32(mh)):
                    sg = mh + i32(mh + 4) + s * 25
                    nverts, vo, nidx, io = i32(sg), i32(sg+4), i32(sg+8), i32(sg+12)
                    orig = [struct.unpack("<H", d[sg+vo+k*9+4:sg+vo+k*9+6])[0] for k in range(nverts)]
                    idx = struct.unpack("<%dH" % nidx, d[sg+io:sg+io+nidx*2])
                    for k in range(0, nidx - 2, 3):
                        tris.append((orig[idx[k]], orig[idx[k+1]], orig[idx[k+2]]))
    return tris

def render(base, grip_z, out, size=512):
    P, N = vvd(base + ".vvd"); T = vtx(base + ".dx90.vtx")
    L = np.array([0.3, 0.5, 0.8]); L /= np.linalg.norm(L)
    # кладём по диагонали: длинная ось z -> из левого нижнего угла в правый верхний, смотрим сбоку по x
    a = math.radians(45)
    def proj(p):
        y, z = p[1], p[2]
        return np.array([y*math.cos(a) + z*math.sin(a), -y*math.sin(a) + z*math.cos(a)]), p[0]
    pts = []
    for t in T:
        tri = [P[i] for i in t]
        n = sum(N[i] for i in t); n = n / (np.linalg.norm(n) or 1)
        zc = sum(p[2] for p in tri) / 3
        base_col = (70, 52, 38) if zc < grip_z else (190, 196, 204)
        k = 0.35 + 0.65 * abs(float(np.dot(n, L)))
        col = tuple(int(c * k) for c in base_col)
        pp = [proj(p) for p in tri]
        pts.append(([q[0] for q in pp], sum(q[1] for q in pp) / 3, col))
    allp = np.array([q for p, _, _ in pts for q in p])
    S = 4; W = size * S
    sc = W * 0.88 / (allp.max(0) - allp.min(0)).max()
    c = (allp.max(0) + allp.min(0)) / 2
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    for poly, depth, col in sorted(pts, key=lambda t: t[1]):
        d.polygon([(W/2 + (q[0]-c[0])*sc, W/2 - (q[1]-c[1])*sc) for q in poly], fill=col + (255,))
    img = img.resize((size, size), Image.LANCZOS)
    a_ = img.split()[3].filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(3))
    o = Image.new("RGBA", (size, size), (0, 0, 0, 0)); o.paste((0, 0, 0, 150), (0, 0), a_)
    o.alpha_composite(img); o.save(out)

if __name__ == "__main__":
    render(sys.argv[1], float(sys.argv[2]), sys.argv[3])
