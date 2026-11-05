# Иконки для weapon_hg_vodka / weapon_hg_beer / weapon_hg_wine / weapon_hg_cigarettes: нарисованы фигурами. Запуск: python3 tools/alcohol/icons.py
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

# пачка сигарет (weapon_hg_cigarettes): красно-белая пачка, открыта, торчат три сигареты
def cig_pack(path):
    S = 4
    W = H = 256 * S
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    x0, x1, y0, y1 = 70 * S, 186 * S, 92 * S, 236 * S
    # сигареты (за крышкой)
    for i, (cx, top) in enumerate(((100, 40), (128, 26), (156, 48))):
        d.rectangle([(cx - 11) * S, top * S, (cx + 11) * S, 110 * S], fill=(244, 242, 234, 255))
        d.rectangle([(cx - 11) * S, top * S, (cx + 11) * S, (top + 26) * S], fill=(214, 150, 70, 255))
        for k in range(3):
            d.ellipse([(cx - 6 + k * 5) * S, (top + 6 + (k % 2) * 8) * S, (cx - 3 + k * 5) * S, (top + 9 + (k % 2) * 8) * S], fill=(170, 105, 45, 255))
    # пачка
    d.rounded_rectangle([x0, y0, x1, y1], radius=6 * S, fill=(236, 234, 228, 255))
    d.rectangle([x0, y0, x1, y0 + 44 * S], fill=(196, 28, 32, 255))
    d.polygon([(x0, y0 + 44 * S), (x1, y0 + 44 * S), (x1, y0 + 66 * S), ((x0 + x1) // 2, y0 + 86 * S), (x0, y0 + 66 * S)], fill=(196, 28, 32, 255))
    d.rectangle([x0, y0 - 6 * S, x1, y0 + 4 * S], fill=(170, 20, 24, 255))
    for i, w in enumerate((60, 44)):
        d.rectangle([(128 - w // 2) * S, (190 + i * 14) * S, (128 + w // 2) * S, (196 + i * 14) * S], fill=(60, 60, 64, 255))
    d.rectangle([x0 + 8 * S, y0 + 10 * S, x0 + 16 * S, y1 - 12 * S], fill=(255, 255, 255, 90))
    im = im.resize((256, 256), Image.LANCZOS)
    shadow = Image.new('RGBA', im.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 120), (3, 4), im.split()[3])
    out = Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(3)), im)
    out.save(path)

cig_pack('materials/entities/weapon_hg_cigarettes.png')

# вино (weapon_hg_wine): тёмно-зелёная бутылка, длинная бордовая фольга на горлышке, светлая этикетка
bottle('materials/entities/weapon_hg_wine.png', (30, 66, 36, 235), (120, 12, 30, 230), (238, 230, 210, 255), (120, 20, 35, 255), 54, (125, 16, 32, 255))

# виски, коньяк, ром, самогон, шампанское, абсент
bottle('materials/entities/weapon_hg_whiskey.png', (225, 225, 215, 120), (190, 105, 30, 230), (24, 24, 26, 255), (200, 160, 70, 255), 40, (25, 25, 25, 255))
bottle('materials/entities/weapon_hg_cognac.png', (225, 220, 205, 120), (150, 70, 20, 235), (232, 214, 160, 255), (120, 30, 25, 255), 44, (200, 160, 60, 255))
bottle('materials/entities/weapon_hg_rum.png', (80, 45, 20, 235), (110, 50, 15, 230), (236, 226, 196, 255), (170, 30, 25, 255), 42, (30, 20, 15, 255))
bottle('materials/entities/weapon_hg_moonshine.png', (225, 235, 230, 110), (235, 240, 225, 90), (214, 196, 150, 255), (60, 50, 40, 255), 40, (150, 120, 80, 255))
bottle('materials/entities/weapon_hg_champagne.png', (30, 70, 40, 235), (235, 215, 140, 230), (240, 232, 205, 255), (210, 175, 70, 255), 58, (210, 175, 70, 255))
bottle('materials/entities/weapon_hg_absinthe.png', (220, 235, 220, 120), (90, 200, 70, 220), (240, 238, 220, 255), (30, 110, 40, 255), 44, (20, 60, 25, 255))
