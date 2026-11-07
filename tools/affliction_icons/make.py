# Белые значки-основа для плиток осмотра (lua/homigrad/cl_health_indicator.lua) -> tools/affliction_icons/base/*.png
# Большинство - Tabler Icons (MIT, лицензия в materials/radialmenu_rem/LICENSE-tabler-icons.txt), O2 и печень нарисованы тут.
# Запуск: python3 tools/affliction_icons/make.py <папка tabler/icons/outline>
import io, os, re, sys
import cairosvg
from PIL import Image, ImageDraw, ImageFont

SRC = sys.argv[1]
# белая основа; готовые значки в стиле Fading Vitality из неё делает make_fv.py -> materials/rem_affl
OUT = os.path.join(os.path.dirname(__file__), 'base')
os.makedirs(OUT, exist_ok=True)
SIZE = 96

TABLER = {
    'bleeding': 'droplet', 'arterial': 'droplets', 'bloodloss': 'droplet-half-2',
    'fracture': 'bone', 'skull': 'skull',
    'concussion': 'spiral', 'brain': 'brain', 'seizure': 'bolt', 'unconscious': 'zzz',
    'pain': 'mood-nervous', 'shock': 'activity', 'critical': 'alert-triangle',
    'arrhythmia': 'heart-rate-monitor', 'fibrillation': 'activity-heartbeat', 'cardiac_arrest': 'heart-off',
    'heart': 'heart-broken', 'pressure_low': 'gauge', 'pressure_high': 'gauge',
    'lungs': 'lungs', 'lung_failure': 'lungs-off', 'hot': 'temperature-plus', 'cold': 'temperature-minus',
    'freezing': 'snowflake', 'vessels_narrow': 'arrows-minimize', 'vessels_wide': 'arrows-maximize',
    'alcohol': 'bottle', 'nausea': 'mood-sick', 'fear': 'ghost-2', 'depression': 'cloud-rain',
    'adrenaline': 'heartbeat', 'haste': 'run', 'painkillers': 'pill', 'fatigue': 'battery-1',
    'blind': 'eye-off', 'burning': 'flame', 'gas': 'cloud-fog', 'infection': 'virus',
    'incapacitated': 'wheelchair', 'rage': 'swords',
    'nicotine': 'smoking', 'nicotine_wd': 'smoking-no', 'alcohol_wd': 'glass-off', 'tremor': 'hand-move',
    'anger': 'mood-angry',
}

def tabler(name, out):
    svg = open(os.path.join(SRC, name + '.svg')).read()
    svg = svg.replace('currentColor', '#ffffff')
    svg = re.sub(r'stroke-width="[\d.]+"', 'stroke-width="2.1"', svg)
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=SIZE - 16, output_height=SIZE - 16)
    icon = Image.open(io.BytesIO(png)).convert('RGBA')
    im = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    im.alpha_composite(icon, (8, 8))
    im.save(out)

def o2(out):
    # кислород: маленькая "O2" и график, который падает вниз (ломаная со стрелкой у самого низа)
    S = 4
    im = Image.new('RGBA', (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    font = os.path.join(os.path.dirname(__file__), '..', '..', 'resource', 'fonts', 'ShareTechMono-Regular.ttf')
    big, small = ImageFont.truetype(font, 28 * S), ImageFont.truetype(font, 22 * S)
    d.text((4 * S, -2 * S), 'O', font=big, fill='white', stroke_width=S, stroke_fill='white')
    d.text((21 * S, 9 * S), '2', font=small, fill='white', stroke_width=int(1.5 * S), stroke_fill='white')
    w = int(6 * S)
    # оси (отдельно от графика)
    d.line([(8 * S, 44 * S), (8 * S, 90 * S), (92 * S, 90 * S)], fill='white', width=w, joint='curve')
    # падающий график: справа от надписи, ломаная вниз
    pts = [(42, 12), (54, 30), (62, 24), (74, 48), (80, 42), (86, 62)]
    d.line([(x * S, y * S) for x, y in pts], fill='white', width=w, joint='curve')
    for x, y in pts:
        d.ellipse([(x - 3) * S, (y - 3) * S, (x + 3) * S, (y + 3) * S], fill='white')
    # стрелка вниз на конце
    d.polygon([(89 * S, 78 * S), (78 * S, 62 * S), (94 * S, 58 * S)], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

def liver(out):
    S = 4
    im = Image.new('RGBA', (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pts = [(14, 40), (22, 26), (40, 22), (62, 20), (80, 22), (86, 30), (80, 40), (66, 50), (52, 62), (42, 72), (34, 70), (24, 60), (16, 50)]
    d.line([(x * S, y * S) for x, y in pts + pts[:1]], fill='white', width=int(4.5 * S), joint='curve')
    d.line([(52 * S, 22 * S), (48 * S, 46 * S)], fill='white', width=int(3.5 * S))
    for x, y in pts:
        d.ellipse([(x - 2.2) * S, (y - 2.2) * S, (x + 2.2) * S, (y + 2.2) * S], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

def canvas():
    # рисуем в 4 раза крупнее и уменьшаем - ровные края
    im = Image.new('RGBA', (SIZE * 4, SIZE * 4), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)

def P(pts):
    return [(x * 4, y * 4) for x, y in pts]

def done(im, out, angle=0):
    if angle: im = im.rotate(angle, Image.BICUBIC)
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

def outline(d, pts, w=6):
    # замкнутый контур со скруглёнными углами
    d.line(P(pts + pts[:1]), fill='white', width=w * 4, joint='curve')
    for x, y in pts:
        d.ellipse(P([(x - w / 2, y - w / 2), (x + w / 2, y + w / 2)]), fill='white')

def wound(out):
    # рана: кусок кожи, на нём рваный порез (порез - отдельная деталь, make_fv красит его в красный)
    im, d = canvas()
    outline(d, [(14, 24), (40, 16), (72, 18), (86, 34), (84, 62), (64, 80), (30, 80), (12, 62)])
    d.polygon(P([(24, 66), (34, 50), (42, 52), (50, 38), (58, 40), (72, 28), (66, 46), (58, 48), (50, 60), (42, 58)]), fill='white')
    done(im, out)

def internal(out):
    # внутреннее кровотечение: туловище, внутри капля крови
    im, d = canvas()
    outline(d, [(40, 6), (56, 6), (58, 16), (78, 22), (86, 36), (74, 50), (74, 90), (22, 90), (22, 50), (10, 36), (18, 22), (38, 16)])
    d.polygon(P([(48, 34), (60, 60), (36, 60)]), fill='white')
    d.ellipse(P([(35, 50), (61, 76)]), fill='white')
    done(im, out)

def immobilized(out):
    # обездвижен: рука в гипсе с бинтами (наискосок)
    im, d = canvas()
    d.rounded_rectangle(P([(6, 28), (90, 68)]), radius=18 * 4, outline='white', width=6 * 4)
    for x in (30, 48, 66):
        d.rounded_rectangle(P([(x - 2.5, 41), (x + 2.5, 55)]), radius=8, fill='white')
    done(im, out, 30)

def amputation(out):
    # ампутация: рука обрублена - ровный срез, на срезе красное мясо
    im, d = canvas()
    d.rounded_rectangle(P([(6, 28), (82, 68)]), radius=18 * 4, outline='white', width=6 * 4, corners=(True, False, False, True))
    d.ellipse(P([(58, 40), (68, 56)]), fill='white')
    done(im, out, 30)

def dislocation(out):
    # вывих: две кости, сустав разошёлся
    bone = Image.open(os.path.join(OUT, 'fracture.png')).convert('RGBA').resize((58, 58), Image.LANCZOS)
    im = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    im.alpha_composite(bone, (0, 38))   # нижняя кость
    im.alpha_composite(bone, (38, 0))   # верхняя, сдвинута вбок от сустава
    im.save(out)

def mark(path, plus):
    # значок "+" / "-" в правом верхнем углу (давление высокое / низкое)
    S = 4
    im = Image.open(path).convert('RGBA').resize((SIZE * S, SIZE * S), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    d.rectangle([66 * S, 12 * S, 90 * S, 17 * S], fill='white')
    if plus: d.rectangle([75.5 * S, 2.5 * S, 80.5 * S, 26.5 * S], fill='white')
    im.resize((SIZE, SIZE), Image.LANCZOS).save(path)

for key, name in TABLER.items():
    tabler(name, os.path.join(OUT, key + '.png'))
mark(os.path.join(OUT, 'pressure_high.png'), True)
mark(os.path.join(OUT, 'pressure_low.png'), False)
o2(os.path.join(OUT, 'hypoxia.png'))
liver(os.path.join(OUT, 'liver.png'))
for f in (wound, internal, immobilized, amputation, dislocation):
    f(os.path.join(OUT, f.__name__ + '.png'))
print(len(TABLER) + 7, 'icons')
