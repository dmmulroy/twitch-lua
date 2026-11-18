return {
  name = "twitch",
  title = "Twitch",
  base_url = { default = "https://api.twitch.tv/helix", option = "base_url", env = "TWITCH_API_BASE_URL" },
  auth = { kind = "bearer", from = "access_token", env = "TWITCH_ACCESS_TOKEN" },
  options = { client_id = { env = "TWITCH_CLIENT_ID" } },
  headers = { ["Client-Id"] = "{client_id}" },
  unknown_tag = "UnknownTwitchError",
  parse_tag = "TwitchParseError",
  naming = { members = "wire" },
}
