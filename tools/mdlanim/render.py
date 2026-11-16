# Скелеты всех анимаций MDL (свой декодер mdlanim.py) - листы PNG по 7 анимаций: вид спереди и сбоку, 6 кадров.
# Запуск: python3 tools/mdlanim/render.py <путь к .mdl> [папка для PNG]. Чужие модели в репозиторий не кладём.
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFont
from mdlanim import MDL
MDL_PATH = sys.argv[1] if len(sys.argv) > 1 else 'model_anim.mdl'
OUT = sys.argv[2] if len(sys.argv) > 2 else '.'
m = MDL(MDL_PATH)
SKIP = ('Finger', 'Attachment', 'forward', 'faceplate')
keep = [i for i, b in enumerate(m.bones) if not any(s in b['name'] for s in SKIP)]
COL = {'R_': (230, 60, 60), 'L_': (60, 120, 230)}
def col(name):
    for k, c in COL.items():
        if k in name: return c
    return (30, 30, 30)
NF = 6
CW, CH = 150, 170
font = ImageFont.load_default()

def views(world):
    # вид спереди (y, z) и сбоку (x, z); Source: x вперёд, y влево, z вверх
    return [[(-p[1], p[2]) for p, q in world], [(p[0], p[2]) for p, q in world]]

def draw_seq(si):
    s = m.seqs[si]
    ai = s['anims'][0]
    a = m.anims[ai]
    n = a['frames']
    frames = sorted(set(int(round(k * (n - 1) / (NF - 1))) for k in range(NF))) if n > 1 else [0]
    worlds = [m.world(m.frame_pose(ai, f)) for f in frames]
    img = Image.new('RGB', (CW * NF * 2 + 10, CH + 18), (245, 245, 240))
    dr = ImageDraw.Draw(img)
    dr.text((4, 2), '%s  (%d frames, %s)' % (s['name'], n, 'loop' if a['flags'] & 1 else 'once'), fill=(0, 0, 0), font=font)
    for vi in range(2):
        pts_all = [views(w)[vi] for w in worlds]
        xs = [p[0] for pts in pts_all for i, p in enumerate(pts) if i in keep]
        ys = [p[1] for pts in pts_all for i, p in enumerate(pts) if i in keep]
        span = max(max(xs) - min(xs), max(ys) - min(ys), 1)
        sc = (CH - 20) / span
        for fi, pts in enumerate(pts_all):
            ox = vi * (CW * NF + 10) + fi * CW
            cx = ox + CW / 2; 
            mx = (max(xs) + min(xs)) / 2; my = (max(ys) + min(ys)) / 2
            def P(p): return (cx + (p[0] - mx) * sc, 18 + (CH - 20) / 2 - (p[1] - my) * sc)
            dr.rectangle([ox + 1, 16, ox + CW - 2, CH + 16], outline=(200, 200, 200))
            for i in keep:
                par = m.bones[i]['parent']
                if par >= 0 and par in keep:
                    dr.line([P(pts[par]), P(pts[i])], fill=col(m.bones[i]['name']), width=3)
            hp = P(pts[6]); dr.ellipse([hp[0]-5, hp[1]-5, hp[0]+5, hp[1]+5], outline=(0, 0, 0), width=2)
            dr.text((ox + 4, CH + 2), ('front ' if vi == 0 else 'side ') + 'f%d' % frames[fi], fill=(90, 90, 90), font=font)
    return img

rows = [draw_seq(i) for i in range(len(m.seqs))]
per = 7
for k in range(0, len(rows), per):
    part = rows[k:k + per]
    sheet = Image.new('RGB', (part[0].width, sum(r.height for r in part)), (255, 255, 255))
    y = 0
    for r in part: sheet.paste(r, (0, y)); y += r.height
    sheet.save('%s/anims_%d.png' % (OUT, k // per + 1))
print('ok', len(rows))
