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
    'wound': 'cut', 'bleeding': 'droplet', 'arterial': 'droplets', 'bloodloss': 'droplet-half-2',
    'fracture': 'bone', 'dislocation': 'stretching', 'amputation': 'hand-off', 'skull': 'skull',
    'concussion': 'spiral', 'brain': 'brain', 'seizure': 'bolt', 'unconscious': 'zzz',
    'shock': 'activity', 'critical': 'alert-triangle',
    'arrhythmia': 'heart-rate-monitor', 'fibrillation': 'activity-heartbeat', 'cardiac_arrest': 'heart-off',
    'heart': 'heart-broken', 'pressure_low': 'gauge', 'pressure_high': 'gauge',
    'lungs': 'lungs', 'lung_failure': 'lungs-off', 'hot': 'temperature-plus', 'cold': 'temperature-minus',
    'freezing': 'snowflake', 'vessels_narrow': 'arrows-minimize', 'vessels_wide': 'arrows-maximize',
    'alcohol': 'bottle', 'nausea': 'mood-sick', 'fear': 'ghost-2', 'depression': 'cloud-rain',
    'adrenaline': 'heartbeat', 'haste': 'run', 'painkillers': 'pill', 'fatigue': 'battery-1',
    'blind': 'eye-off', 'burning': 'flame', 'gas': 'cloud-fog', 'infection': 'virus',
    'immobilized': 'link', 'incapacitated': 'wheelchair', 'internal': 'stethoscope', 'rage': 'swords',
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

def sad(out):
    # боль: классический грустный смайлик =( - круг, две точки-глаза, рот дугой вниз
    S = 4
    im = Image.new('RGBA', (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse([10 * S, 10 * S, 86 * S, 86 * S], outline='white', width=int(6 * S))
    for x in (35, 61):
        d.ellipse([(x - 5) * S, 30 * S, (x + 5) * S, 46 * S], fill='white')
    d.arc([31 * S, 60 * S, 65 * S, 88 * S], 205, 335, fill='white', width=int(6 * S))
    im.resize((SIZE, SIZE), Image.LANCZOS).save(out)

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
sad(os.path.join(OUT, 'pain.png'))
print(len(TABLER) + 3, 'icons')
