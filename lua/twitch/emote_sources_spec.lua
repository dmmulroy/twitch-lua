local t = require("spec_helper")
local emote_sources = require("twitch.emote_sources")
local json_codec = require("twitch.json_codec")

t.test("emote_sources: image URLs per provider, GIF for animated", function()
	t.equal(emote_sources.emote_download_source("twitch", "25", false), {
		url = "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0", format = "png",
	})
	t.equal(emote_sources.emote_download_source("twitch", "emotesv2_abc", true), {
		url = "https://static-cdn.jtvnw.net/emoticons/v2/emotesv2_abc/animated/dark/2.0", format = "gif",
	})
	t.equal(emote_sources.emote_download_source("bttv", "566ca38765dbbdab32ec0560", true).url, "https://cdn.betterttv.net/emote/566ca38765dbbdab32ec0560/2x.gif")
	t.equal(emote_sources.emote_download_source("bttv", "54fa8f1401e468494b85b537", false).url, "https://cdn.betterttv.net/emote/54fa8f1401e468494b85b537/2x.png")
	t.equal(emote_sources.emote_download_source("7tv", "01FCY771D800007PQ2DF3GDTN6", true), {
		url = "https://cdn.7tv.app/emote/01FCY771D800007PQ2DF3GDTN6/2x.gif", format = "gif",
	})
	local static_7tv = emote_sources.emote_download_source("7tv", "01F6MQ33FG000FFJ97ZB8MWV52", false)
	t.equal(static_7tv.format, "png")
	t.truthy(static_7tv.fallback_url:find("2x_static.png", 1, true))
	t.equal(emote_sources.emote_download_source("ffz", "28138", true).format, "png")
end)

t.test("emote_sources: unsafe ids and unknown providers are refused", function()
	for _, id in ipairs({ "", "../../etc/passwd", "a/b", "a?x=1", "a b", "a%2e", string.rep("a", 200) }) do
		t.equal(emote_sources.emote_download_source("twitch", id, false), nil)
		t.equal(emote_sources.is_safe_emote_id(id), false)
	end
	t.equal(emote_sources.is_safe_emote_id(25), false)
	t.equal(emote_sources.emote_download_source("giphy", "25", false), nil)
end)

t.test("emote_sources: the lists to fetch, channel after global", function()
	local lists = emote_sources.third_party_emote_lists("209286766")
	t.equal(#lists, 6)
	t.equal(lists[1].provider, "ffz")
	t.equal(lists[5], { provider = "bttv", url = "https://api.betterttv.net/3/cached/users/twitch/209286766" })
	t.equal(lists[6].url, "https://7tv.io/v3/users/twitch/209286766")
end)

t.test("emote_sources: BTTV global and channel lists", function()
	local global = json_codec.decode_json('[{"id":"54fa8f1401e468494b85b537","code":":tf:","imageType":"png","animated":false,"userId":"5561169bd6b9d206222a8c19"},{"id":"566ca38765dbbdab32ec0560","code":"SourPls","imageType":"gif","animated":true}]')
	t.equal(emote_sources.parse_third_party_emotes("bttv", global), {
		{ word = ":tf:", provider = "bttv", id = "54fa8f1401e468494b85b537" },
		{ word = "SourPls", provider = "bttv", id = "566ca38765dbbdab32ec0560", animated = true },
	})
	local channel = json_codec.decode_json('{"id":"x","bots":[],"avatar":"a","channelEmotes":[{"id":"aaa111","code":"chan","imageType":"png","animated":false}],"sharedEmotes":[{"id":"bbb222","code":"catJAM","imageType":"gif","animated":true}]}')
	t.equal(emote_sources.parse_third_party_emotes("bttv", channel), {
		{ word = "chan", provider = "bttv", id = "aaa111" },
		{ word = "catJAM", provider = "bttv", id = "bbb222", animated = true },
	})
end)

t.test("emote_sources: 7TV global set and channel user", function()
	local global = json_codec.decode_json('{"id":"global","emotes":[{"id":"01FCY771D800007PQ2DF3GDTN6","name":"RainTime","data":{"id":"01FCY771D800007PQ2DF3GDTN6","animated":true,"host":{"url":"//cdn.7tv.app/emote/01FCY771D800007PQ2DF3GDTN6"}}},{"id":"01F6MQ33FG000FFJ97ZB8MWV52","name":"FeelsOkayMan","data":{"animated":false}}]}')
	t.equal(emote_sources.parse_third_party_emotes("7tv", global), {
		{ word = "RainTime", provider = "7tv", id = "01FCY771D800007PQ2DF3GDTN6", animated = true },
		{ word = "FeelsOkayMan", provider = "7tv", id = "01F6MQ33FG000FFJ97ZB8MWV52" },
	})
	local channel = json_codec.decode_json('{"id":"u","emote_set":{"id":"s","emotes":[{"id":"01ABC","name":"peepoHey","data":{"animated":true}}]}}')
	t.equal(emote_sources.parse_third_party_emotes("7tv", channel), { { word = "peepoHey", provider = "7tv", id = "01ABC", animated = true } })
	-- a user with no 7TV account
	t.equal(emote_sources.parse_third_party_emotes("7tv", json_codec.decode_json('{"status_code":404,"error":"Unknown User"}')), {})
end)

t.test("emote_sources: FFZ sets, with numeric ids", function()
	local body = json_codec.decode_json('{"default_sets":[3],"sets":{"3":{"id":3,"emoticons":[{"id":28138,"name":"LilZ","urls":{"1":"https://cdn.frankerfacez.com/emote/28138/1"}},{"id":9,"name":"ZrehplaR"}]}}}')
	local emotes = emote_sources.parse_third_party_emotes("ffz", body)
	table.sort(emotes, function(a, b)
		return a.word < b.word
	end)
	t.equal(emotes, { { word = "LilZ", provider = "ffz", id = "28138" }, { word = "ZrehplaR", provider = "ffz", id = "9" } })
end)

t.test("emote_sources: junk in a list is skipped, never raised on", function()
	t.equal(emote_sources.parse_third_party_emotes("bttv", nil), {})
	t.equal(emote_sources.parse_third_party_emotes("bttv", "nope"), {})
	local odd = json_codec.decode_json('[{"id":"../x","code":"bad"},{"id":"ok1","code":"two words"},{"id":"ok2","code":""},{"code":"noid"},"str",{"id":"ok3","code":"fine"}]')
	t.equal(emote_sources.parse_third_party_emotes("bttv", odd), { { word = "fine", provider = "bttv", id = "ok3" } })
	t.equal(emote_sources.parse_third_party_emotes("7tv", json_codec.decode_json('{"emotes":"x"}')), {})
	t.equal(emote_sources.parse_third_party_emotes("unknown", {}), {})
end)

t.test("emote_sources: later lists win when two define the same word", function()
	local index = emote_sources.build_emote_word_index({
		{ { word = "catJAM", provider = "ffz", id = "1" }, { word = "LilZ", provider = "ffz", id = "2" } },
		{ { word = "catJAM", provider = "7tv", id = "3", animated = true } },
	})
	t.equal(index.count, 2)
	t.equal(index.words.catJAM, { provider = "7tv", id = "3", animated = true })
	t.equal(index.words.LilZ, { provider = "ffz", id = "2" })
end)
