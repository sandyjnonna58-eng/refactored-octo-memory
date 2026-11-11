-- Text tools shared by the language filter (server: what a character writes) and the reader
-- (client: what a character makes of what it reads). UTF-8 throughout: the chat is as often
-- Cyrillic as Latin.

local NT = NeuroTrauma
NT.Text = NT.Text or {}
local X = NT.Text
local floor = math.floor

function X.Chars(s)
	local out = {}
	for _, code in utf8.codes(s) do out[#out + 1] = utf8.char(code) end
	return out
end

function X.Words(text)
	local out = {}
	for w in string.gmatch(text, "%S+") do out[#out + 1] = w end
	return out
end

local PUNCT = { ["."] = true, [","] = true, ["!"] = true, ["?"] = true, [":"] = true, [";"] = true, [")"] = true, ["("] = true, ['"'] = true }

-- A word as characters, and the punctuation that hangs on its end.
function X.Split(word)
	local cs = X.Chars(word)
	local tail = {}
	while #cs > 1 and PUNCT[cs[#cs]] do table.insert(tail, 1, table.remove(cs)) end
	return cs, table.concat(tail)
end

-- The letters of a word in another order: a word that is none.
function X.Scramble(word, rng)
	local cs, tail = X.Split(word)
	for i = #cs, 2, -1 do
		local j = 1 + floor(rng:Next() * i)
		cs[i], cs[j] = cs[j], cs[i]
	end
	return table.concat(cs) .. tail
end

function X.Hash(s)
	local h = 7
	for i = 1, #s do h = (h * 31 + string.byte(s, i)) % 2147483629 end
	return h
end

-- letters next to each other on the two keyboards that matter here
X.neighbour = {}
for _, row in ipairs({ "qwertyuiop", "asdfghjkl", "zxcvbnm", "йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю" }) do
	local cs = X.Chars(row)
	for i, c in ipairs(cs) do X.neighbour[c] = { cs[i - 1], cs[i + 1] } end
end

-- What a reader who has lost part of understanding makes of a text: a share of the words turn
-- into strings of letters [P]. loss 0..1.
function X.Misread(text, loss, rng)
	if loss <= 0.05 then return text end
	local words = X.Words(text)
	for i, w in ipairs(words) do
		if rng:Next() < loss * 0.9 then words[i] = X.Scramble(w, rng) end
	end
	return table.concat(words, " ")
end
