# Текстуры вихря смерти (vortexdeath/cl_vortexdeath.lua) из vortex_centre.png (чёрное пятно с зернистым краем):
#   vortex_core.png - то же пятно белым и плотнее (512x512): красится SetDrawColor в тёмно-красный, как в Fading Vitality;
#   vortex_gap.png  - полоса между половинами: вертикальный профиль пятна по середине (сглажен - растянутое зерно
#                     дало бы полосы), белая, 8 x 512.
# Запуск из корня репозитория: python3 tools/vortex/make.py
from PIL import Image, ImageFilter

SRC = "materials/rem_death/vortex_centre.png"
CORE_BOOST = 2.2
src = Image.open(SRC).convert("RGBA")
w, h = src.size
alpha = src.split()[3]

# плотнее: середина глухая до самого края пятна, рукава под ней не просвечивают (как в видео)
core_a = alpha.filter(ImageFilter.GaussianBlur(2)).point(lambda v: min(255, round(v * CORE_BOOST)))
core = Image.new("RGBA", (w, h), (255, 255, 255, 0))
core.putalpha(core_a)
core = core.resize((512, 512), Image.LANCZOS)
core.save("materials/rem_death/vortex_core.png")

cx = w // 2
col = alpha.crop((cx - 24, 0, cx + 24, h)).resize((1, h), Image.BOX)
col = col.filter(ImageFilter.GaussianBlur(6))
mx = col.getextrema()[1] or 1
col = col.point(lambda v: min(255, round(v * 255 / mx * CORE_BOOST)))  # середина глухая, край - как у ядра
col = col.resize((1, 512), Image.LANCZOS)
gap = Image.new("RGBA", (8, 512), (255, 255, 255, 0))
gap.putalpha(col.resize((8, 512), Image.NEAREST))
gap.save("materials/rem_death/vortex_gap.png")
print("ok")
