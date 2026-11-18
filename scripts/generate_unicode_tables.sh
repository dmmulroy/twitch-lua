#!/bin/sh
# Rebuilds lua/twitch/unicode_tables.lua from the Rust crates twitch-tui (twt) uses:
# unicode-linebreak 0.1.5 (line break classes and its pair table) and unicode-width 0.2.2,
# plus Rust's char::is_alphanumeric. Needs cargo and the crates in the local registry
# (building twt once puts them there).
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$(ls -d "$HOME"/.cargo/registry/src/*/unicode-linebreak-0.1.5 | head -1)"
work="$(mktemp -d)"
cp -R "$repo/tools/generate_unicode_tables/." "$work/"
sed -i '' "s|UNICODE_LINEBREAK_SRC|$src|g" "$work/src/main.rs"
(cd "$work" && cargo run --offline --release --quiet -- "$repo/lua/twitch/unicode_tables.lua")
rm -rf "$work"
