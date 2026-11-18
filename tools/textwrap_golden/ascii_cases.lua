-- deterministic random chat-like messages
local seed = 20261118
local function rand(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
local pieces = { "hello", "world", "a", "I", "rex", "chat", "pog", "LUL", "KEKW", "x", "test-case", "well-known", "--flag", "re-re-re",
  "https://example.com/some/long/path?query=1&b=2", "foo/bar", "a.b.c", "(parens)", "\"quoted\"", "it's", "don't", "100%", "$5",
  "日本語", "中文字符", "한국어", "😀", "👍🏿", "🎉🎉", "café", "naïve", "über-cool", "!!!", "???", "...", "@someone", "#hashtag",
  "supercalifragilisticexpialidocious", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1234567890", "e.g.", "—", "–dash", "ok,", "no;", "yes:" }
local out = {}
for case = 1, 400 do
  local words = {}
  for _ = 1, 1 + rand(18) do
    words[#words + 1] = pieces[rand(#pieces) + 1]
  end
  local text = ""
  for i, w in ipairs(words) do
    local gap = (rand(10) == 0) and "   " or " "
    text = text .. (i > 1 and gap or "") .. w
  end
  if rand(15) == 0 then text = text .. "  " end
  local width = 8 + rand(60)
  local indent = rand(math.min(30, width + 4))
  out[#out + 1] = width .. "\t" .. indent .. "\t" .. text
end
io.write(table.concat(out, "\n"), "\n")
