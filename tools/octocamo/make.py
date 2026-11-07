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
