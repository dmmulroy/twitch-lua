# How twitch-lua works

Twitch chat for Rex in Lua: one Twitch connection per machine, a chat pane in every tab
with its own size, scrollback and message box, and emote images including animated ones.

## Processes

```mermaid
flowchart TB
    Twitch[(Twitch)]
    subgraph one ["one per machine"]
        C["rex/chat_connection.lua<br/>the only EventSub websocket"]
        W["rex/emote_worker.lua<br/>downloads and decodes emotes"]
    end
    subgraph many ["one per tab"]
        P["rex/chat_pane.lua"]
    end
    Twitch <-- "1 websocket (TLS via openssl)" --> C
    C -- "appends chat events" --> L[("events.ndjson")]
    L -- "tail -F" --> P
    P -- "send, moderate: Helix over HTTPS" --> Twitch
    P -- "starts it if it is not running" --> C
    C -- "starts, restarts" --> W
    P -- "asks for missing emotes" --> Q[("emote_requests.ndjson")]
    Q --> W
    W --> E[("emote cache<br/>PNG, RGBA frames, word index")]
    E -- "file paths" --> P
```

Sending does not use the websocket. A pane calls Helix, and its own message comes back
through the event log like anyone else's.

The pane and the palette actions (`rex/palette_actions.lua`) share two modules:
`channel_session.lua` turns the token file into a Helix client for the channel, and
`chat_commands.lua` holds each operation (send, ban, set the title, ...) taking plain
values. The pane's `/commands` only parse a line and call one of them.

Palette actions ask through `rex.ui`, which only works in an action's own call chain:
not under `pcall`/`xpcall`, so never inside `host.guard`, and not in `rex.on` handlers or
the pane's key callbacks. That is why prompts live in actions and not in the pane. An
action has 30 seconds not counting an open prompt; the set-title action makes up to three
Twitch requests before asking and one after, each limited to 6 seconds.

## Why the number of tabs does not matter

Twitch allows 3 EventSub websocket connections per account, and refuses the next
subscription with `429 Too Many Requests`. One chat program per tab ran into that at the
fourth tab.

- Only `chat_connection.lua` opens a websocket, and a lock file allows one of it per
  machine. It holds 5 subscriptions on that connection (the limit is 300 and these cost
  nothing against the account's budget).
- A pane never connects to EventSub. It reads the event log and sends with ordinary HTTPS
  calls, which do not count.

What can still reach the limit:

| Case | Result |
| --- | --- |
| Something else uses the account's connections: another chat program, or this on a second machine | Each one is +1. Three in total still work. |
| A reconnect while Twitch still counts the old connection | Twitch answers 429 for a few seconds. The connection waits and retries (1 s doubling to 60 s) and says so in the feed; it does not exit. |
| The connection process dies | A pane starts a new one within 5 seconds. Panes keep running. |
| A pane dies | Only that pane is affected. |

## The connection

`eventsub_connection.lua` is driven by an injected host (a byte stream, timers, a clock),
so the specs run it against a scripted server with a manual clock.

```text
open the stream, write the websocket handshake
on text frame
  session_welcome    -> create the 5 chat subscriptions through Helix (Twitch gives 10 s)
  session_keepalive  -> resets the silence timer (every message does)
  notification       -> chat event -> event log
  session_reconnect  -> open the URL Twitch gave; when that connection is welcomed, close
                        the old one; subscriptions carry over
  revocation         -> a warning; "authorization revoked" stops for good
on ping              -> masked pong
on close frame, stream end, or silence longer than the keepalive timeout + 5 s
                     -> reconnect after 1 s, doubling to 60 s; the delay resets after a
                        minute of being joined
on subscribe: 401 -> stop ("token invalid")   403 on chat messages -> stop ("needs user:read:chat")
              429 -> retry later              409 -> already subscribed, fine
```

After a token problem the connection stays up and looks at the token file every 30
seconds, so replacing the token is enough. It validates the token with Twitch at start and
every hour, as Twitch requires.

TLS is `openssl s_client -verify_return_error -verify_hostname` run as a helper process.
macOS's `/usr/bin/openssl` is LibreSSL and has no hostname check (measured: it accepted
`wrong.host.badssl.com`), so a Homebrew OpenSSL is required and the connection refuses to
start without one.

## The event log

One JSON object per line with a rising `seq`:

```json
{"seq":42,"at":1795016551,"kind":"message","id":"…","name":"Viewer","color":"#5B99FF","text":"hi Kappa","parts":[{"type":"text","text":"hi "},{"type":"emote","text":"Kappa","emote_id":"25"}]}
```

Kinds: `message`, `notice` (subs, raids), `delete`, `clear`, `clear_user`, `status`.
Panes follow it with `tail -n +1 -F`: history first, then live. Past 2,000 lines it is
replaced with its last 500; `tail -F` replays the new file and panes skip the sequence
numbers they have seen.

## The pane

`tui/chat_pane.lua` takes key bytes, event log bytes and size changes, and writes the
screen through one `write` function, so the specs run it against a small fake terminal.
It is drawn like twitch-tui (twt), which it replaces:

```text
row 1        ┌[ Time: Wed Nov 18 08:44:10 2026 ] [ Channel: dillon ]─┐   clock redrawn every second
rows 2..n-4  │ the feed, newest at the bottom                         │
row n-3      └──────────────────────────────────────────────[ 3 new ]┘   while scrolled up
rows n-2..n  ┌[ Chat ]┐ │ the line being typed │ └[ 12 / 500 ]┘           green, red when empty
```

What is copied from twt (its source, `src/ui`, `src/utils/styles.rs`, `src/handlers/data.rs`):

- Colors: chat text bright white; "Time", "Channel", "Twitch" and "System" bold red; the
  input box green or red. Name colors are twt's "pastel" palette: the sum of the name's
  bytes picks a hue (`hsl_to_rgb` ported; checked against the Rust code for 311 names).
- Badges as emoji before the name: 💎 VIP, 🔨 moderator, ⭐ subscriber, 👑 Prime.
- Your login anywhere in a message is bold black on white (and the "@" before the first one).
- `/me` messages are italic in the name's color.
- Connection and Twitch notices are `Twitch: ...` lines; problems are `System: ...`.
- Deleted messages and a banned person's messages are removed; a clear says "Chat was
  cleared for non-Moderators viewing this room".
- Line breaks: twt calls textwrap 0.16.2 with its defaults, so `tui/twt_text_wrap.lua`
  ports that: Unicode line break opportunities (unicode-linebreak's tables, generated into
  `unicode_tables.lua`), hyphen splitting, breaking over-long words, and the optimal-fit
  algorithm with its penalties and the SMAWK search (tie-breaking included). Checked against
  the real crate on 1,900 messages: every line equal. The wrap width is twt's: the box's
  inside less one, with the author's length in bytes reserved on the first line.

Where this differs from twt on purpose: a line is laid out with emote images at their real
width (twt wraps by the emote's name and can overflow), there is no normal/insert mode
(the input box is always there), and links can be clicked.

Links:

- Twitch sends no link fragments, so `chat_links.lua` looks at each word of a message:
  `http://` and `https://` with any host, and bare hosts such as `twitch.tv/dillon` when the
  last label is a real top-level domain (opened as `https://`). The list is IANA's, in
  `top_level_domains.lua` (`scripts/generate_top_level_domains.sh` refreshes it). Some
  top-level domains are also file extensions (`.rs`, `.py`, `.md`, `.sh`, `.zip`), so
  `main.rs` is a link too; `.js`, `.ts`, `.lua` and `.txt` are not domains and stay text.
  Punctuation around a link and an unbalanced `)` are left out.
- A link is drawn as an OSC 8 hyperlink, underlined in the text's own style. Its URL holds
  only printable ASCII URL characters, and the shown text is always the URL itself. The
  `id=` is the same on every row the link wraps onto, so it hovers and opens as one link.
- Wrapping does not change: the URL is still one word to the textwrap port.
- The pane reports mouse clicks for the wheel; Rex's terminal (Ghostty's core) opens a link
  with Cmd-click.

Other behaviour:

- Keys come from a helper that puts the pane's terminal in raw mode; Rex passes each
  chunk to a Lua callback. `io.read` is not used: it blocks timers.
- Every redraw is absolute: each row is cleared and rewritten inside a synchronized
  update, with line wrapping off, and the right border is drawn at its own column.
- Chat text is untrusted. Control characters (including ESC) and invalid UTF-8 are
  removed before layout, so a message cannot send escape sequences to the terminal.
- Width is counted per grapheme cluster with unicode-width's table: combining marks and
  joiners add nothing, an emoji with its modifiers or a flag is one unit.

## Emotes

No WebP decoder is needed: Twitch, BTTV and 7TV serve animated emotes as GIF. Still
emotes are PNG, which the terminal decodes itself. FFZ emotes are shown as still images
(their global set has no animated ones; their channel sets were not checked).

- **`gif_decoder.lua`** decodes a GIF to RGBA frames: LZW, global and per-frame color
  tables, transparency, the three disposal modes, interlacing, frame delays. It was
  compared with ffmpeg on 43 real emotes (2,257 frames): every pixel equal, under lua,
  luajit and Rex. The specs keep four of those emotes and test each feature on small
  generated images. It never raises, whatever the bytes are.
- **The worker** is its own process because decoding in Rex takes about 2.5 ms a frame
  (1.5 s for the largest emote seen, 492 frames). It builds URLs itself from a provider
  and an id made only of letters, digits, `_` and `-`; a request cannot name a URL or a
  path.
- **The cache** holds, per emote, a small JSON file plus either the PNG or all frames back
  to back as raw RGBA. A pane never reads pixels: it gives the terminal the file's path
  and each frame's byte offset.
- **Limits**: an animation keeps at most 120 frames and 4 MB; past that every n-th frame
  is kept and takes over the dropped frames' time. A pane's terminal holds at most 48 MB
  of images; emotes off screen are unloaded first. The disk cache is cut back past 256 MB.
- **Until an emote is ready** its name is drawn as text. Panes look for emotes they asked
  for twice a second and redraw when one arrives.
- **Third-party emotes** are plain words in a message. The worker fetches the channel's
  BTTV, 7TV and FFZ lists in the background (they can take 15 seconds or more), writes a
  word index as each arrives, and retries a list that failed.

Animation, set by `animation` in the settings:

| | `terminal` (default) | `lua` | `off` |
| --- | --- | --- | --- |
| How | One image; every frame is added with its delay and the terminal loops it | One image per frame; a 40 ms timer works out the current frame from the clock and the pane redraws when it changes | First frame only |
| Cost while running | None in Lua | About 0.4% CPU for 4 emotes (measured) | None |

Both `terminal` and `lua` were seen animating in Rex. Rex's terminal answered OK to every
command in all three modes (`spec/rex_emote_terminal_check.lua`).

## What Rex's Lua needs

All measured; each is handled where noted.

| What Rex does | How it is handled |
| --- | --- |
| An error inside an output callback is swallowed and stops that command's output for good | Every callback goes through `host.guard`, which logs the error |
| A command started in a timer or handler must be detached to outlive it, and a detached command outlives the script (an orphaned `openssl` stayed connected for 40 s or more) | Every helper is detached and tied to its owner: it reads stdin and stops at end of input, or runs under a small wrapper that watches the stdin pipe |
| `rex.exec.start` has no exit callback | One timer polls the helpers |
| Output callbacks never run during `rex.sleep` or a blocking wait | The pane and the connection only use timers; only the worker sleeps |
| `rex.on` only works at script load | Handlers register at the top level |
| `pcall` can corrupt closures | `compat.pcall` from distilled-lua |
| `tonumber(nil)` and `tostring()` of no value raise | A fallback before the call |
| `os.date` gets `%a` wrong and does not know `%e` or `%T` | twt's clock text is built from `os.date("*t")` |
| `a, b = f(x), y` assigning to existing variables crashed with a nil pointer dereference in one function | Two statements there, with a comment |
| `for x in f().field:gmatch(...)` fails with "attempt to index nil" | The value goes in a local first |
| `debug.getinfo(1, "S").source` has no leading `@` | An optional `@` is stripped |
| A `rex do` script sent SIGTERM or SIGINT exits with status 130 | Whoever watches a pane treats 130 as "it was asked to stop" |
| The tty holds about 1 KB of unread terminal replies and drops the rest | Graphics commands are sent with `q=2` (no replies) |
| `rex.json.decode` drops `null`, also inside arrays | Wanted here; the pure-Lua fallback does the same |

## Not covered

- Sending a message to a live chat was never run by the tests; the Helix call was checked
  with a request Twitch rejects (an empty message).
- Badge images, an emote picker, search, and a channel switcher are not there.
- Very busy chats: frame parsing is per byte in Lua and was not measured at hundreds of
  messages a second.
- FFZ animated emotes show as still images.
