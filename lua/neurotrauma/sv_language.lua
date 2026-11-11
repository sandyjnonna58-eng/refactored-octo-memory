-- What an injured brain does to language: chat and voice.
--
-- Z-City scrambles the chat of a character and mutes its voice from one number, its brain damage,
-- whatever the injury is. With neuro_zcity_takeover on, a character that has a neurological record
-- is handled here instead (Z-City's two rules are wrapped, not edited; its other chat rules, a
-- broken jaw, pain, lack of air, still run): what comes out depends on which part of the language
-- network is hurt, and on the hands that type.
--
--   non-fluent     the frontal part of the network or its starter: few words, the small ones
--                  dropped, pauses; at the worst a word or nothing [S: N35 N37 N18]
--   fluent         the temporal part: as many words as ever, but wrong ones and made-up ones
--                  [S: N36 N64]
--   conduction     the junction and its fibres: the sounds of longer words come out in the wrong
--                  order [S: N78]
--   writing        spelling falls apart: letters left out, doubled [S: N79]
--   typing         weak or clumsy hands hit the neighbouring key and miss keys; this is not a
--                  language disorder and leaves the words themselves intact [S: N49 for the
--                  distinction between speech as movement and language]
--   confusion      a brain that is injured as a whole loses the thread: words repeat, the sentence
--                  breaks off [P]
--
-- Speech as sound cannot be changed from Lua: voice is either heard or not. It is cut when
-- language production or articulation is nearly gone, and left alone otherwise.
-- Commands (a message that begins with ! or /) are never touched. Admins pass unless
-- neuro_chat_admins is 1. Everything is decided on the server.

local NT = NeuroTrauma
NT.Language = NT.Language or {}
local LG = NT.Language
local C, Z, E = NT.Config, NT.ZC, NT.E
local CL = C.Language
local Clamp, floor, min, max = math.Clamp, math.floor, math.min, math.max

------------------------------------------------------------------------------------------
-- Text tools: sh_text.lua
------------------------------------------------------------------------------------------
local X = NT.Text
local Chars, Words, Split, Hash, neighbour = X.Chars, X.Words, X.Split, X.Hash, X.neighbour
local function Neologism(word, rng) return X.Scramble(word, rng) end

------------------------------------------------------------------------------------------
-- The disorders, each on a list of words
------------------------------------------------------------------------------------------
local function NonFluent(words, sev, rng)
	local n = #words
	local keep = {}
	for _, w in ipairs(words) do
		local cs = Split(w)
		-- the small words go first
		local small = #cs <= 3
		if not (small and rng:Next() < sev * 1.2) then keep[#keep + 1] = w end
	end
	if #keep == 0 then keep[1] = words[rng:Next() < 0.5 and 1 or n] end
	local limit = max(1, floor(n * (1 - 0.8 * sev) + 0.5))
	while #keep > limit do table.remove(keep, 1 + floor(rng:Next() * #keep)) end
	local out = {}
	for i, w in ipairs(keep) do
		out[#out + 1] = w
		if i < #keep and rng:Next() < sev * 0.7 then out[#out + 1] = "..." end
	end
	if sev > 0.9 and rng:Next() < 0.5 then return { "..." } end
	return out
end


local function Fluent(words, sev, rng)
	local n = #words
	local out = {}
	for i, w in ipairs(words) do
		local r = rng:Next()
		if r < sev * 0.35 and n > 2 then
			-- a real word, the wrong one
			out[i] = words[1 + floor(rng:Next() * n)]
		elseif r < sev * 0.7 then
			out[i] = Neologism(w, rng)
		else
			out[i] = w
		end
	end
	return out
end

local function Conduction(words, sev, rng)
	local out = {}
	for i, w in ipairs(words) do
		local cs, tail = Split(w)
		if #cs >= 5 and rng:Next() < sev then
			local swaps = 1 + floor(rng:Next() * sev * 2)
			for _ = 1, swaps do
				local k = 2 + floor(rng:Next() * (#cs - 2))
				cs[k], cs[k + 1] = cs[k + 1] or cs[k], cs[k]
			end
			out[i] = table.concat(cs) .. tail
		else
			out[i] = w
		end
	end
	return out
end

local function Spelling(words, sev, rng)
	local out = {}
	for i, w in ipairs(words) do
		local cs, tail = Split(w)
		local res = {}
		for k, c in ipairs(cs) do
			local r = rng:Next()
			if r < sev * 0.12 and #cs > 2 then
				-- left out
			elseif r < sev * 0.2 then
				res[#res + 1] = c
				res[#res + 1] = c
			else
				res[#res + 1] = c
			end
		end
		if #res == 0 then res[1] = cs[1] end
		out[i] = table.concat(res) .. tail
	end
	return out
end

local function Typing(words, sev, rng)
	local out = {}
	for i, w in ipairs(words) do
		local cs = Chars(w)
		local res = {}
		for _, c in ipairs(cs) do
			local r = rng:Next()
			local nb = neighbour[string.lower(c)] or neighbour[c]
			if r < sev * 0.22 and nb then
				local pick = nb[rng:Next() < 0.5 and 1 or 2] or nb[1] or nb[2]
				res[#res + 1] = pick or c
			elseif r < sev * 0.3 then
				-- key missed
			elseif r < sev * 0.36 then
				res[#res + 1] = c
				res[#res + 1] = c
			else
				res[#res + 1] = c
			end
		end
		if #res == 0 then res[1] = cs[1] end
		out[i] = table.concat(res)
	end
	return out
end

local function Confusion(words, sev, rng)
	local out = {}
	for i, w in ipairs(words) do
		out[#out + 1] = w
		if rng:Next() < sev * 0.25 then out[#out + 1] = w end
	end
	if #out > 3 and rng:Next() < sev * 0.6 then
		local cut = 2 + floor(rng:Next() * (#out - 2))
		while #out > cut do table.remove(out) end
		out[#out + 1] = "..."
	end
	return out
end

------------------------------------------------------------------------------------------
-- What a character's injury does to its writing: severities 0..1 of each disorder
------------------------------------------------------------------------------------------
local function Sev(x, from)
	return Clamp((1 - x - from) / (1 - from), 0, 1)
end

function LG.Profile(st)
	local an = st.an
	local ch = NT.Anatomy.Channels(st)
	local stg = an.stg and an.stg.language_production
	-- the frontal part of the network and its starter against the temporal part
	local frontal = stg and min(stg[1], stg[4], stg[5]) or ch.language_production
	local posterior = ch.language_comprehension
	local hands = max(st.handL * st.coordL, st.handR * st.coordR)
	local both = 0.5 * (st.handL * st.coordL + st.handR * st.coordR)
	local p = {
		nonfluent = Sev(frontal, CL.from),
		fluent = Sev(posterior, CL.from),
		conduction = Sev(ch.language_repetition, CL.from),
		spelling = Sev(ch.writing, CL.from),
		-- one good hand types slowly but hits the keys; two bad ones do not
		typing = Sev(0.7 * hands + 0.3 * both, CL.from),
		confusion = Sev(st.cognitive, CL.confusionFrom),
		comprehension = ch.language_comprehension, reading = ch.reading,
		speech = min(ch.language_production, ch.articulation),
		awake = st.effective or st.consciousness,
	}
	p.any = max(p.nonfluent, p.fluent, p.conduction, p.spelling, p.typing, p.confusion)
	return p
end


-- The text as this character can produce it. Returns the new text and what was applied.
function LG.Transform(st, text, seed)
	local p = LG.Profile(st)
	if p.any <= 0.02 then return text, nil end
	local rng = NT.RNG(seed or (Hash(text) + floor(CurTime())))
	local words = Words(text)
	if #words == 0 then return text, nil end
	local did = {}
	-- order: what the brain puts together first (the words), then how it spells them, then what
	-- the hands make of it
	if p.confusion > 0.05 then words = Confusion(words, p.confusion, rng) did[#did + 1] = string.format("confusion %.2f", p.confusion) end
	if p.fluent > 0.05 then words = Fluent(words, p.fluent, rng) did[#did + 1] = string.format("fluent %.2f", p.fluent) end
	if p.nonfluent > 0.05 then words = NonFluent(words, p.nonfluent, rng) did[#did + 1] = string.format("non-fluent %.2f", p.nonfluent) end
	if p.conduction > 0.05 then words = Conduction(words, p.conduction, rng) did[#did + 1] = string.format("conduction %.2f", p.conduction) end
	if p.spelling > 0.05 then words = Spelling(words, p.spelling, rng) did[#did + 1] = string.format("spelling %.2f", p.spelling) end
	if p.typing > 0.05 then words = Typing(words, p.typing, rng) did[#did + 1] = string.format("typing %.2f", p.typing) end
	local out = table.concat(words, " ")
	-- hands that hardly work do not finish a long message
	if p.typing > 0.5 then
		local cap = floor(CL.typingChars * (1 - p.typing) + 6)
		local cs = Chars(out)
		if #cs > cap then
			out = table.concat(cs, "", 1, cap) .. "..."
		end
	end
	return out, table.concat(did, ", ")
end

-- What a listener with a comprehension or reading deficit makes of a text (the listener's own
-- client applies it: cl_senses.lua uses the same function through the shared file).

------------------------------------------------------------------------------------------
-- The hooks
------------------------------------------------------------------------------------------
LG.count = LG.count or 0

local function Exempt(ply, text)
	if not C.sv.chat:GetBool() then return true end
	local first = string.sub(text, 1, 1)
	if first == "!" or first == "/" then return true end
	if not C.sv.chatAdmins:GetBool() and IsValid(ply) and ply:IsAdmin() then return true end
	return false
end

local function Record(ply)
	local org = IsValid(ply) and ply.organism
	return istable(org) and NT.Get(org) or nil, org
end

-- Chat: Z-City's own garbler runs with its brain rule switched off for this character, then ours.
local function Say(orig, ply, txtTbl, text)
	local st, org = Record(ply)
	if not st or not Z.Takeover() or not NT.Enabled() then return orig(ply, txtTbl, text) end
	local keep = org.brain
	org.brain = 0
	local ok, a, b = pcall(orig, ply, txtTbl, text)
	org.brain = keep
	if not ok then ErrorNoHalt("[NeuroTrauma] Z-City chat hook: " .. tostring(a) .. "\n") a, b = nil, nil end
	local cur = txtTbl[1]
	if isstring(cur) and cur ~= "" and not Exempt(ply, text) then
		local new, did = LG.Transform(st, cur)
		if did then
			txtTbl[1] = new
			LG.count = LG.count + 1
			if C.sv.log:GetBool() then NT.Print("chat of %s (%s): '%s' -> '%s'", ply:Nick(), did, cur, new) end
			if NT.TestLog then NT.TestLog("  chat %s (%s): '%s' -> '%s'", ply:Nick(), did, cur, new) end
		end
	end
	return a, b
end

-- Voice: heard or not.
local function Voice(orig, listener, speaker)
	local st = Record(speaker)
	if not st or not Z.Takeover() or not NT.Enabled() then return orig(listener, speaker) end
	local ch = NT.Anatomy.Channels(st)
	if min(ch.language_production, ch.articulation) < CL.voiceFrom then return false, false end
	-- (and nothing from Z-City's brain number: the model has said what this brain can do)
end

LG.wrapped = LG.wrapped or false
local function Wrap()
	if LG.wrapped then return true end
	local ht = hook.GetTable()
	local say = ht.HG_PlayerSay and ht.HG_PlayerSay.huy
	local voice = ht.HG_PlayerCanHearPlayersVoice and ht.HG_PlayerCanHearPlayersVoice.BrainDamage
	if not isfunction(say) or not isfunction(voice) then return false end
	LG.origSay, LG.origVoice = say, voice
	hook.Add("HG_PlayerSay", "huy", function(ply, txtTbl, text) return Say(LG.origSay, ply, txtTbl, text) end)
	hook.Add("HG_PlayerCanHearPlayersVoice", "BrainDamage", function(listener, speaker) return Voice(LG.origVoice, listener, speaker) end)
	LG.wrapped = true
	Z.has.chat = true
	return true
end

hook.Add("InitPostEntity", "NT_LanguageWrap", function()
	if Wrap() then return end
	timer.Create("NT_LanguageWrapRetry", 1, 30, function()
		if Wrap() then timer.Remove("NT_LanguageWrapRetry") end
	end)
end)
hook.Add("HomigradRun", "NT_LanguageWrap", function() timer.Simple(0, Wrap) end)
