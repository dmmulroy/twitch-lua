# twitch-lua

Twitch chat in a [Rex](https://www.superlogical.com/rex/) pane, written in Lua. One
process holds the only connection to Twitch, and every tab's chat pane reads from it, so
the number of tabs never runs into Twitch's limit of 3 EventSub connections per account.

It looks like [twitch-tui](https://github.com/Xithrius/twitch-tui) (twt), which it replaces:

```text
┌[ Time: Wed Nov 18 08:44:10 2026 ] [ ┐
│Twitch: Joined #dillon               │
│⭐bishalr0y: how's you experience    │
│with rex?                            │
│🔨StreamElements: Thank you for      │
│following @dillon ▣▣                 │   <- emote images; animated ones move
└─────────────────────────────────────┘
┌[ Chat ]─────────────────────────────┐   green when the line can be sent, red when empty
│hello                                │
└[ 5 / 500 ]──────────────────────────┘
```

twt's details are copied: its pastel name colors (picked from the name, not Twitch's
colors), emoji badges (💎 VIP, 🔨 moderator, ⭐ subscriber, 👑 Prime), `Twitch:` and
`System:` lines in bold red, your login highlighted in a message, `/me` in italics, deleted
messages removed, and line breaks exactly where twt puts them (a port of textwrap 0.16.2,
checked against the real crate on 1,900 messages).

## Requirements

- Rex, for the panes (`rex do`).
- OpenSSL 1.1 or newer from Homebrew (`brew install openssl`). macOS's own `openssl` is
  LibreSSL, which cannot check that a certificate matches its hostname, so it is not used.
- `curl`, for Helix calls and emote downloads.
- A Twitch user access token with the `user:read:chat` and `user:write:chat` scopes, alone
  in `~/.config/twitch-lua/token` (mode 600). Moderation commands need their own scopes.

## Running it

In a Rex terminal:

```sh
rex do /path/to/twitch-lua/rex/chat_pane.lua tty="$(tty)" rex="$(command -v rex)"
```

The pane starts the connection process if none is running. The connection exits by itself
about 20 seconds after the last pane closes.

| Key | Does |
| --- | --- |
| Enter | Send the message, or run a `/command` |
| Up / Down | Recall sent messages |
| PageUp / PageDown, mouse wheel | Scroll the feed |
| Esc | Jump to the newest message (the chat box's bottom edge says `[ n new ]` while scrolled up) |
| Ctrl-A / Ctrl-E, Alt-B / Alt-F | Move in the line |
| Ctrl-W, Ctrl-U, Ctrl-K | Delete a word, to the start, to the end |
| Ctrl-L | Redraw |
| Ctrl-C | Quit |

Commands: `/help`, `/clear`, `/ban user [reason]`, `/timeout user [seconds] [reason]`,
`/unban user`, `/title text`, `/category name`, `/announce text`, `/shoutout user`,
`/slow [seconds]`, `/slowoff`, `/emoteonly`, `/emoteonlyoff`, `/subscribers`,
`/subscribersoff`, `/followers [minutes]`, `/followersoff`, `/uniquechat`,
`/uniquechatoff`. `/me text` is sent as a chat message.

## Settings

Optional, in `~/.config/twitch-lua/settings.json`:

```json
{
  "channel": "somelogin",
  "animation": "terminal",
  "emotes": true,
  "max_messages": 500
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `channel` | the token's own channel | The chat room to join |
| `animation` | `"terminal"` | Animated emotes: `"terminal"` (the terminal plays the frames), `"lua"` (a timer switches them) or `"off"` (first frame only) |
| `emotes` | `true` | `false` shows emote names as text |
| `max_messages` | `500` | Messages a pane keeps for scrolling |

## Files it uses

| Path | What |
| --- | --- |
| `~/.config/twitch-lua/token` | The Twitch token |
| `~/.config/twitch-lua/settings.json` | Settings |
| `~/.local/state/twitch-lua/events.ndjson` | Chat events, written by the connection, followed by panes |
| `~/.local/state/twitch-lua/twitch-lua.log` | Warnings and errors from every process |
| `~/.cache/twitch-lua/emotes/` | Emote images, shared by all panes; cut back when over 256 MB |

`XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` are honoured.

## Layout

```text
lua/twitch/                  # the library: pure Lua 5.1, no I/O outside host/ and rex/
├── websocket_client.lua     # RFC 6455: bytes in, events out
├── eventsub_session.lua     # one EventSub session: messages in, effects out
├── eventsub_connection.lua  # keeps a connection alive: subscribe, reconnect, backoff
├── chat_events.lua          # Twitch notifications -> the events panes draw
├── chat_event_log.lua       # the shared event log file
├── chat_store.lua           # the messages a pane holds; deletes and clears
├── twitch_auth.lua          # token file and token validation
├── gif_decoder.lua          # animated GIF -> RGBA frames
├── emote_sources.lua        # emote URLs and third-party emote lists
├── emote_cache.lua          # the emote cache on disk
├── terminal_text.lua        # safe text, cell widths, grapheme clusters
├── unicode_tables.lua       # generated: line break classes and widths from twt's Rust crates
├── tui/                     # the pane: twt's layout and wrapping, input box, keys, commands, emotes
├── host/rex_host.lua        # timers, helper processes and TLS on Rex's Lua API
└── rex/                     # the three processes, as functions
rex/                         # entry points: chat_pane.lua, chat_connection.lua, emote_worker.lua
vendor/                      # distilled-lua runtime and the generated Helix client
spec/                        # test helpers and the runner; specs sit next to their modules
docs/DESIGN.md               # how it works, and what was measured
```

## Tests

```sh
lua spec/run_specs.lua           # also: luajit spec/run_specs.lua
rex do spec/run_specs.lua        # the same specs inside Rex's Lua
lua spec/run_specs.lua websocket # one file
```

`spec/rex_emote_terminal_check.lua` checks, in a real Rex terminal, that the terminal
accepts every emote command (see the file's header).

## Regenerating the Unicode data

`scripts/generate_unicode_tables.sh` rebuilds `lua/twitch/unicode_tables.lua` from the
Rust crates twt uses (unicode-linebreak 0.1.5, unicode-width 0.2.2).
`scripts/check_wrap_against_textwrap.sh` reruns the real textwrap on the recorded cases in
`spec/fixtures/textwrap/`. Both need cargo; the generators are in `tools/`.

## The Helix client

`vendor/twitch` is [distilled-lua](https://github.com/dmmulroy/distilled-lua)'s generated Twitch
client (one service per page of Twitch's API reference), from Distilled's Twitch model, which is
read from those reference pages. `lua/twitch/helix_client.lua` maps the operations this library
calls to their services. `scripts/regenerate_helix_client.sh` refreshes the client and the
runtime in `vendor/distilled` (Apache-2.0; its LICENSE and NOTICE are kept beside it).
