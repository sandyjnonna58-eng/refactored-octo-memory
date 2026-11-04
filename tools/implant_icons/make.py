# Иконки имплантов (weapon_implant_*): тёмно-синяя капсула-кейс с голубым свечением и белым значком Tabler Icons (MIT).
# Запуск: python3 tools/implant_icons/make.py <папка tabler/icons/outline>
import io, os, re, sys
import cairosvg
from PIL import Image, ImageDraw, ImageFilter

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'materials', 'entities')
ICONS = {'heart': 'heart-bolt', 'lungs': 'lungs', 'nanites': 'droplet-bolt', 'painblock': 'shield-check', 'adrenal': 'battery-charging-2'}

def glyph(name, size, color):
    svg = open(os.path.join(SRC, name + '.svg')).read().replace('currentColor', color)
    svg = re.sub(r'stroke-width="[\d.]+"', 'stroke-width="1.8"', svg)
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size))).convert('RGBA')

for key, name in ICONS.items():
    S = 256
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([28, 28, 228, 228], radius=34, fill=(14, 26, 48, 255))
    shine = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shine).ellipse([70, 60, 186, 176], fill=(40, 90, 150, 200))
    shine = shine.filter(ImageFilter.GaussianBlur(28))
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([28, 28, 228, 228], radius=34, fill=255)
    im.paste(Image.alpha_composite(im, shine), (0, 0), mask)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([28, 28, 228, 228], radius=34, outline=(70, 170, 230, 255), width=6)
    glow = glyph(name, 150, '#5fd3ff').filter(ImageFilter.GaussianBlur(7))
    im.alpha_composite(glow, (53, 53))
    im.alpha_composite(glyph(name, 140, '#ffffff'), (58, 58))
    d = ImageDraw.Draw(im)
    for x in (52, 76, 180, 204):
        d.rectangle([x, 222, x + 8, 236], fill=(70, 170, 230, 255))
    im.save(os.path.join(OUT, 'weapon_implant_%s.png' % key))
print('ok')
