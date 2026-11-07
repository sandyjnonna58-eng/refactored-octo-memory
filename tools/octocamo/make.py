# Картинка OctoCamo для меню CAMO аддона Снейка (свой рисунок) -> materials/mgsv_snake/loadout/drabs/rem_octo.png
# Слева серый "нейтральный" костюм с мелкой рябью, справа он уже перенял кирпич - переход волной.
# Запуск из корня репозитория: python3 tools/octocamo/make.py
import os, random, math
from PIL import Image, ImageDraw, ImageFilter

W, H = 136, 68
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'mgsv_snake', 'loadout', 'drabs', 'rem_octo.png')
random.seed(4)

base = Image.new('RGB', (W, H), (78, 82, 84))
d = ImageDraw.Draw(base)
for _ in range(260):  # рябь
    x, y, r = random.uniform(0, W), random.uniform(0, H), random.uniform(1, 3.5)
    c = random.randint(62, 100)
    d.ellipse([x - r, y - r, x + r, y + r], fill=(c, c + 3, c + 4))
base = base.filter(ImageFilter.GaussianBlur(0.8))

brick = Image.new('RGB', (W, H), (60, 40, 34))
b = ImageDraw.Draw(brick)
bw, bh = 22, 9
for row in range(H // bh + 1):
    off = (bw // 2) if row % 2 else 0
    for col in range(-1, W // bw + 2):
        x0, y0 = col * bw + off, row * bh
        c = (random.randint(128, 160), random.randint(62, 80), random.randint(48, 60))
        b.rectangle([x0 + 1, y0 + 1, x0 + bw - 2, y0 + bh - 2], fill=c)

mask = Image.new('L', (W, H), 0)
m = mask.load()
for y in range(H):
    for x in range(W):
        edge = W * 0.48 + math.sin(y / H * math.pi * 3) * 9
        m[x, y] = max(0, min(255, int((x - edge) * 16)))
out = Image.composite(brick, base, mask).convert('RGBA')
ImageDraw.Draw(out).rectangle([0, 0, W - 1, H - 1], outline=(30, 32, 34, 255))
out.save(OUT)
print('ok', OUT)


# свои запасные текстуры поверхностей для OctoCamo (трава/земля/песок/снег на дисплейсментах) -> materials/rem_octo/*.png
def surface(name, base, spots, n=900, rmax=4, blur=0.6, strokes=None):
    rnd = random.Random(name)
    im = Image.new('RGB', (256, 256), base)
    dr = ImageDraw.Draw(im)
    for _ in range(n):
        x, y, r = rnd.uniform(0, 256), rnd.uniform(0, 256), rnd.uniform(1, rmax)
        c = rnd.choice(spots)
        j = rnd.randint(-10, 10)
        dr.ellipse([x - r, y - r, x + r, y + r], fill=tuple(max(0, min(255, v + j)) for v in c))
    for _ in range(strokes or 0):  # травинки
        x, y, l, a = rnd.uniform(0, 256), rnd.uniform(0, 256), rnd.uniform(6, 16), rnd.uniform(-0.5, 0.5)
        dr.line([(x, y), (x + a * l, y - l)], fill=rnd.choice(spots), width=2)
    out = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'rem_octo')
    os.makedirs(out, exist_ok=True)
    im.filter(ImageFilter.GaussianBlur(blur)).save(os.path.join(out, name + '.png'))


surface('grass', (58, 82, 32), [(70, 104, 38), (48, 70, 26), (92, 120, 48), (40, 58, 22)], n=500, strokes=1400)
surface('dirt', (92, 72, 50), [(110, 86, 60), (76, 58, 40), (124, 100, 72), (66, 50, 36)])
surface('sand', (186, 164, 120), [(200, 180, 136), (170, 148, 106), (210, 192, 150)], rmax=2.5)
surface('snow', (222, 226, 232), [(236, 240, 246), (206, 212, 222), (246, 248, 252)], rmax=5, blur=1.2)
print('surfaces ok')
