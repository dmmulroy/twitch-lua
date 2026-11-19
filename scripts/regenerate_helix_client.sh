#!/bin/sh
# Refreshes vendor/distilled (the distilled-lua runtime) and vendor/distilled/clients/twitch
# (the generated Twitch Helix client, module distilled.clients.twitch as in the rock
# distilled-twitch) from a distilled-lua checkout. vendor/ is for working in a checkout;
# the twitch-lua rock depends on the rocks instead (rockspecs/).
#
#   scripts/regenerate_helix_client.sh [path to distilled-lua]
#
# The client is distilled-lua's clients/twitch: one service per page of Twitch's API
# reference, generated from Distilled's Twitch model (alchemy-run/distilled#1341). To
# regenerate it there: `verify/dl models sync twitch && verify/dl gen-all twitch`.
# lua/twitch/helix_client.lua maps the operations this library calls to their services.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
distilled_lua="${1:-$repo/../distilled-lua}"

if [ ! -f "$distilled_lua/clients/twitch/init.lua" ]; then
  echo "regenerate_helix_client: no Twitch client in $distilled_lua/clients/twitch" >&2
  exit 1
fi

cd "$distilled_lua"
lua bin/distilled-lua vendor --out "$repo/vendor"
mkdir -p "$repo/vendor/distilled/clients"
rm -rf "$repo/vendor/distilled/clients/twitch"
cp -R clients/twitch "$repo/vendor/distilled/clients/twitch"
cp LICENSE NOTICE "$repo/vendor/distilled/"
