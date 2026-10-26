-- анимации сдачи в плен и стойки на коленях (из MELEECITY): lua/homigrad/surrender
wOS.DynaBase:RegisterSource({
    Name = "ZCity | Surrender animations",
    Type = WOS_DYNABASE.EXTENSION,
    Shared = "models/surrender_anim/m_surrender.mdl",
    Female = "models/surrender_anim/f_surrender.mdl",
    Male = "models/surrender_anim/m_surrender.mdl"
})

hook.Add("PreLoadAnimations", "wOS.DynaBase.MountSurrender_anim", function(gender)
    if gender == WOS_DYNABASE.FEMALE then
        IncludeModel("models/surrender_anim/f_surrender.mdl")
    else
        IncludeModel("models/surrender_anim/m_surrender.mdl")
    end
end)
