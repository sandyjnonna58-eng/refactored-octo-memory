# Контур предплечья для мини-игры самоповреждения (lua/homigrad/selfharm/cl_selfharm_game.lua) -> materials/rem_selfharm/arm.png
# Свой рисунок в духе Fading Vitality: белая линия, кулак сверху, предплечье уходит вниз-вправо. Прозрачный фон.
# Запуск из корня репозитория: python3 tools/selfharm/make.py
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'rem_selfharm')
os.makedirs(OUT, exist_ok=True)
N = 512
S = 4  # рисуем крупнее и уменьшаем - линия мягче
rnd = random.Random(7)


def wob(pts, amp=1.5):
    return [(x + rnd.uniform(-amp, amp), y + rnd.uniform(-amp, amp)) for x, y in pts]


def curve(p0, p1, p2, n=24):
    # квадратичная кривая Безье
    out = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        out.append((x, y))
    return out


def P(x, y):
    return (x * N * S, y * N * S)


im = Image.new('RGBA', (N * S, N * S), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
W = 3 * S
white = (255, 255, 255, 255)

# предплечье: две линии от запястья вниз-вправо, к локтю расходятся
left = curve(P(0.30, 0.44), P(0.33, 0.70), P(0.43, 1.02))
right = curve(P(0.47, 0.42), P(0.52, 0.70), P(0.66, 1.02))
d.line(wob(left, 2), fill=white, width=W, joint='curve')
d.line(wob(right, 2), fill=white, width=W, joint='curve')

# кулак: ладонь (скруглённый контур) и четыре костяшки сверху, большой палец слева
palm = []
palm += curve(P(0.30, 0.44), P(0.24, 0.36), P(0.25, 0.25))  # левый край вверх
palm += curve(P(0.25, 0.25), P(0.26, 0.17), P(0.31, 0.16))  # к первой костяшке
# костяшки
kx = [0.31, 0.36, 0.41, 0.46]
top = [0.16, 0.13, 0.13, 0.155]
for i, x in enumerate(kx):
    x2 = kx[i + 1] if i + 1 < len(kx) else 0.50
    y1 = top[i]
    y2 = top[i + 1] if i + 1 < len(top) else 0.19
    palm += curve(P(x, y1), P((x + x2) / 2, y1 - 0.045), P(x2, y2))
palm += curve(P(0.50, 0.19), P(0.52, 0.30), P(0.47, 0.42))  # правый край вниз
d.line(wob(palm, 2), fill=white, width=W, joint='curve')
# большой палец: петля слева поверх ладони
thumb = curve(P(0.27, 0.30), P(0.20, 0.27), P(0.235, 0.21))
thumb += curve(P(0.235, 0.21), P(0.27, 0.20), P(0.30, 0.25))
d.line(wob(thumb, 2), fill=white, width=W, joint='curve')
# складки пальцев на кулаке (короткие штрихи)
for x in kx[1:]:
    d.line(wob([P(x, 0.21), P(x - 0.01, 0.27)], 1.5), fill=white, width=int(W * 0.7))

im = im.resize((N, N), Image.LANCZOS)
# лёгкое свечение вокруг линии
glow = im.filter(ImageFilter.GaussianBlur(2))
g = glow.split()[3].point(lambda a: int(a * 0.35))
glow.putalpha(g)
out = Image.alpha_composite(glow, im)
out.save(os.path.join(OUT, 'arm.png'))
print('ok')
