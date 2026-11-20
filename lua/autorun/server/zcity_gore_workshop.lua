-- |Z-CITY| GORE : Workshop content delivery
--
-- When this addon is installed from the Steam Workshop, clients only get its models / materials if the
-- SERVER tells them to download the workshop item. After you publish the addon, put its Workshop ID here
-- (the number at the end of the workshop URL: ...filedetails/?id=1234567890).
--
-- Leave it empty while testing locally: the files are then sent directly with resource.AddFile instead
-- (see sv_gore.lua / sv_torso.lua).
ZCITY_GORE_WORKSHOP_ID = ""

if ZCITY_GORE_WORKSHOP_ID ~= "" then
	resource.AddWorkshop(ZCITY_GORE_WORKSHOP_ID)
end
