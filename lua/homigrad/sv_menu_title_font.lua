-- главное меню в стиле хакерского терминала (cl_menu_wd.lua): шрифт Share Tech Mono (SIL Open Font License,
-- resource/fonts/ShareTechMono-OFL.txt), загрузка - VT323 (раздаёт vortexdeath/sv_vortexdeath.lua), картинки materials/rem_wd/
resource.AddSingleFile("resource/fonts/ShareTechMono-Regular.ttf")
for _, name in ipairs({"scene_rings", "scene_rings_b", "scene_city", "scene_city_b", "scene_skulls", "scene_skulls_b", "scene_hood", "scene_hood_b", "scene_noise",
	"logo", "card_discord", "card_appearance", "card_skills", "card_achievements", "card_settings"}) do
	resource.AddSingleFile("materials/rem_wd/" .. name .. ".png")
end
