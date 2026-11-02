# Иконки для weapon_hg_vodka / weapon_hg_beer: бутылка, нарисованная фигурами. Запуск: python3 tools/alcohol/icons.py
from PIL import Image, ImageDraw, ImageFilter

def bottle(path, glass, liquid, label, label_text_col, neck_len, cap):
    S = 4
    W = H = 256 * S
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = W // 2
    body_w, body_top, body_bot = 70 * S, 110 * S, 236 * S
    neck_w, neck_top = 26 * S, (110 - neck_len) * S
    # тело
    d.rounded_rectangle([cx - body_w // 2, body_top, cx + body_w // 2, body_bot], radius=16 * S, fill=glass)
    # плечи
    d.polygon([(cx - body_w // 2, body_top + 12 * S), (cx - neck_w // 2, body_top - 28 * S), (cx + neck_w // 2, body_top - 28 * S), (cx + body_w // 2, body_top + 12 * S)], fill=glass)
    # горлышко
    d.rectangle([cx - neck_w // 2, neck_top, cx + neck_w // 2, body_top - 26 * S], fill=glass)
    # жидкость
    d.rounded_rectangle([cx - body_w // 2 + 6 * S, body_top + 18 * S, cx + body_w // 2 - 6 * S, body_bot - 6 * S], radius=12 * S, fill=liquid)
    # этикетка
    d.rectangle([cx - body_w // 2, 150 * S, cx + body_w // 2, 200 * S], fill=label)
    for i, y in enumerate((162, 174, 186)):
        w = (44, 30, 38)[i] * S
        d.rectangle([cx - w // 2, y * S, cx + w // 2, y * S + 5 * S], fill=label_text_col)
    # крышка
    d.rectangle([cx - neck_w // 2 - 3 * S, neck_top - 10 * S, cx + neck_w // 2 + 3 * S, neck_top + 4 * S], fill=cap)
    # блик
    d.rounded_rectangle([cx - body_w // 2 + 10 * S, body_top + 6 * S, cx - body_w // 2 + 20 * S, body_bot - 20 * S], radius=5 * S, fill=(255, 255, 255, 70))
    d.rectangle([cx - neck_w // 2 + 4 * S, neck_top + 6 * S, cx - neck_w // 2 + 9 * S, body_top - 30 * S], fill=(255, 255, 255, 60))
    im = im.resize((256, 256), Image.LANCZOS)
    shadow = Image.new('RGBA', im.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 120), (3, 4), im.split()[3])
    out = Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(3)), im)
    out.save(path)

bottle('materials/entities/weapon_hg_vodka.png', (215, 230, 235, 150), (235, 245, 250, 120), (236, 236, 228, 255), (190, 30, 30, 255), 46, (200, 30, 30, 255))
bottle('materials/entities/weapon_hg_beer.png', (110, 60, 20, 235), (150, 85, 25, 220), (232, 206, 120, 255), (90, 40, 20, 255), 40, (190, 160, 60, 255))
