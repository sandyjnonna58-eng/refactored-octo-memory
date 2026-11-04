# Текстуры напитков и сигарет из фото (личный пак, в репозиторий не кладутся: materials/rem_drinks_private/).
# Для бутылок: фон (белый, связанный с краями) убирается заливкой, по силуэту снимается профиль (радиус по высоте) -
# он печатается как Lua-таблица для SWEP.Bottle.photo, картинка обрезается по силуэту и ложится на модель спереди.
# Для пачки: перспективой вырезается передняя грань, и кусок фильтра.
# Запуск: python3 -I tools/drink_textures/make.py <пиво> <вино> <водка> <пачка> <папка вывода>
import sys, os
import numpy as np
from PIL import Image, ImageFilter

beer, wine, vodka, pack, out = sys.argv[1:6]
os.makedirs(out, exist_ok=True)

def mask_of(img, thr=236):
    a = np.asarray(img.convert('RGB')).astype(int)
    h, w, _ = a.shape
    light = (a.min(axis=2) > thr) & ((a.max(axis=2) - a.min(axis=2)) < 18)
    bg = np.zeros((h, w), bool)
    stack = [(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)]
    for y in range(h):
        stack += [(y, 0), (y, w - 1)]
    for x in range(w):
        stack += [(0, x), (h - 1, x)]
    while stack:
        y, x = stack.pop()
        if y < 0 or x < 0 or y >= h or x >= w or bg[y, x] or not light[y, x]:
            continue
        bg[y, x] = True
        stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
    m = ~bg
    # убрать одиночный мусор
    mi = Image.fromarray((m * 255).astype('uint8')).filter(ImageFilter.MedianFilter(5))
    return np.asarray(mi) > 127

def bottle(path, name, height, tex_size, flat=None):
    img = Image.open(path).convert('RGB')
    m = mask_of(img)
    ys, xs = np.where(m)
    y0, y1 = ys.min(), ys.max()
    rows = []
    for y in range(y0, y1 + 1):
        xx = np.where(m[y])[0]
        if len(xx): rows.append((y, xx.min(), xx.max()))
    cx = np.median([(a + b) / 2 for _, a, b in rows])
    half = max(max(cx - a, b - cx) for _, a, b in rows)
    scale = height / (y1 - y0)
    # профиль: ~40 точек снизу вверх, радиус - средняя полуширина строки, сглажено
    radii = {y: (b - a) / 2 for y, a, b in rows}
    pts = []
    for i in range(41):
        y = int(round(y1 - i * (y1 - y0) / 40))
        win = [radii[yy] for yy in range(y - 3, y + 4) if yy in radii]
        pts.append((round((y1 - y) * scale, 2), round(float(np.mean(win)) * scale, 2)))
    # текстура: обрезка по рамке x: cx +- half, y: y0..y1, вне силуэта - прозрачно
    x0, x1 = int(cx - half), int(cx + half) + 1
    crop = img.crop((x0, y0, x1, y1 + 1)).convert('RGBA')
    alpha = Image.fromarray((m[y0:y1 + 1, x0:x1] * 255).astype('uint8'))
    crop.putalpha(alpha)
    crop = crop.resize(tex_size, Image.LANCZOS)
    crop.save(os.path.join(out, name + '.png'))
    lua = '{' + ', '.join('{%g, %g}' % p for p in pts) + '}'
    print('%s: H=%g R=%.2f' % (name, height, half * scale))
    print('  profile = ' + lua)

bottle(beer, 'beer', 12.9, (256, 1024))
bottle(wine, 'wine', 15.6, (256, 1024))
bottle(vodka, 'vodka', 13.6, (256, 512))

# пачка: передняя грань перспективой (углы на фото 320x320), кусок фильтра
p = Image.open(pack).convert('RGB')
quad = (99, 107, 38, 224, 156, 297, 196, 175)  # TL, BL, BR, TR
front = p.transform((256, 384), Image.QUAD, quad, Image.BICUBIC)
front.save(os.path.join(out, 'pack_front.png'))
p.crop((176, 88, 186, 98)).resize((64, 64), Image.BICUBIC).save(os.path.join(out, 'filter.png'))  # кусок пробкового фильтра
print('pack ok')
