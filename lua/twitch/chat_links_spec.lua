local t = require("spec_helper")
local chat_links = require("twitch.chat_links")

local function url_of(word)
	local link = chat_links.find_chat_link_in_word(word)
	return link and link.url or nil
end

-- The part of the word that is the link.
local function linked_text(word)
	local link = chat_links.find_chat_link_in_word(word)
	return link and word:sub(link.first, link.last) or nil
end

t.test("chat_links: http and https links, kept as written", function()
	t.equal(url_of("https://github.com/Xithrius/twitch-tui"), "https://github.com/Xithrius/twitch-tui")
	t.equal(url_of("http://example.com"), "http://example.com")
	t.equal(url_of("HTTPS://Example.COM/A?b=1&c=%20#top"), "HTTPS://Example.COM/A?b=1&c=%20#top")
	-- with a scheme any host is a link, top-level domain or not
	t.equal(url_of("http://localhost:8080/x"), "http://localhost:8080/x")
	t.equal(url_of("https://192.168.1.10/"), "https://192.168.1.10/")
	t.equal(url_of("https://main.rs"), "https://main.rs")
end)

t.test("chat_links: bare hosts with a known top-level domain open as https", function()
	t.equal(url_of("twitch.tv/dillon"), "https://twitch.tv/dillon")
	t.equal(url_of("youtu.be/dQw4w9WgXcQ"), "https://youtu.be/dQw4w9WgXcQ")
	t.equal(url_of("discord.gg/abc"), "https://discord.gg/abc")
	t.equal(url_of("traits.sh"), "https://traits.sh")
	t.equal(url_of("bun.sh/docs"), "https://bun.sh/docs")
	-- every IANA top-level domain counts, file-extension look-alikes included
	t.equal(url_of("main.rs"), "https://main.rs")
	t.equal(url_of("setup.py"), "https://setup.py")
	t.equal(url_of("cool.zip"), "https://cool.zip")
	t.equal(url_of("my.photography/x"), "https://my.photography/x")
	t.equal(url_of("Google.COM"), "https://Google.COM")
	t.equal(url_of("bbc.co.uk/news"), "https://bbc.co.uk/news")
	t.equal(url_of("example.com:8443/path"), "https://example.com:8443/path")
	t.equal(url_of("www.rust-lang.org?x=1"), "https://www.rust-lang.org?x=1")
end)

t.test("chat_links: words that only look like links stay text", function()
	for _, word in ipairs({
		"index.js", "app.ts", "init.lua", "notes.txt", "foo.notatld",
		"e.g.", "i.e.", "v1.2.3", "3.14", "a..com", "-bad.com", "bad-.com", ".com", "com",
		"me@gmail.com", "user@twitch.tv/x", "https://", "https://-", "http:/x.com", "ftp://x.com",
		"hello", "wait...what", "😀.com",
	}) do
		t.equal(url_of(word), nil, word)
	end
end)

t.test("chat_links: punctuation around a link is left out of it", function()
	t.equal(linked_text("(twitch.tv/dillon)."), "twitch.tv/dillon")
	t.equal(linked_text("\"https://x.com/a\","), "https://x.com/a")
	t.equal(linked_text("<https://x.com>"), "https://x.com")
	t.equal(linked_text("twitch.tv!!!"), "twitch.tv")
	t.equal(linked_text("see:twitch.tv"), nil) -- not at the start of the word
	-- a ")" that closes a "(" inside the link stays
	t.equal(linked_text("https://en.wikipedia.org/wiki/Lua_(programming_language)"), "https://en.wikipedia.org/wiki/Lua_(programming_language)")
	t.equal(linked_text("(https://en.wikipedia.org/wiki/Lua_(programming_language))"), "https://en.wikipedia.org/wiki/Lua_(programming_language)")
	local link = chat_links.find_chat_link_in_word("(twitch.tv)")
	t.equal({ link.first, link.last }, { 2, 10 })
end)

t.test("chat_links: a link ends at the first byte that cannot be in a URL", function()
	t.equal(linked_text("https://x.com/日本"), "https://x.com/")
	t.equal(linked_text("https://x.com/a\"b"), "https://x.com/a")
	t.equal(linked_text("https://x.com/a|b"), "https://x.com/a")
	t.equal(linked_text("https://x.com/a" .. string.char(27) .. "]8;;evil"), "https://x.com/a")
end)

t.test("chat_links: links longer than MAX_CHAT_LINK_BYTES are not links", function()
	t.equal(url_of("https://x.com/" .. string.rep("a", chat_links.MAX_CHAT_LINK_BYTES)), nil)
	local long = "https://x.com/" .. string.rep("a", chat_links.MAX_CHAT_LINK_BYTES - 14)
	t.equal(url_of(long), long)
end)

t.test("chat_links: a link only ever holds printable ASCII", function()
	for _, word in ipairs({ "https://x.com/a\7b", "twitch.tv/\0x", "https://x.com/\127", "https://x.com/\226\128\174" }) do
		local url = url_of(word)
		t.truthy(url and not url:find("[^\33-\126]"), word)
	end
end)
