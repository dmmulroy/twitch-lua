#!/bin/sh
# Regenerates spec/fixtures/textwrap/expected.txt by running the real textwrap 0.16.2 (the
# version twt uses) on spec/fixtures/textwrap/cases.txt. The spec twt_text_wrap_spec.lua
# then checks the Lua port against it. Each case line is: width <tab> indent <tab> text.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
cp -R "$repo/tools/textwrap_golden/." "$work/"
(cd "$work" && cargo build --offline --release --quiet)
"$work/target/release/wrapcheck" < "$repo/spec/fixtures/textwrap/cases.txt" > "$repo/spec/fixtures/textwrap/expected.txt"
rm -rf "$work"
