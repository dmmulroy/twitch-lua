#!/bin/sh
# Regenerates vendor/distilled (the distilled-lua runtime) and vendor/twitch (the Helix
# client) from a distilled-lua checkout that has the Twitch model.
#
#   scripts/regenerate_helix_client.sh [path to distilled-lua]
#
# The model (models/twitch/twitch.json) comes from Distilled's Twitch package:
# in the distilled-lua checkout, run `verify/dl models sync twitch` first.
# To call another Helix operation, add its name to OPERATIONS and run this again.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
distilled_lua="${1:-$repo/../distilled-lua}"
model="$distilled_lua/models/twitch/twitch.json"

OPERATIONS="get_users,create_eventsub_subscription,delete_eventsub_subscription,get_eventsub_subscriptions,send_chat_message,get_global_chat_badges,get_channel_chat_badges,delete_chat_messages,ban_user,unban_user,modify_channel_information,get_channel_information,get_games,send_chat_announcement,send_a_shoutout,update_chat_settings,get_channel_emotes,get_global_emotes,get_emote_sets,get_user_chat_color"

if [ ! -f "$model" ]; then
  echo "regenerate_helix_client: no Twitch model at $model (run 'verify/dl models sync twitch' in distilled-lua)" >&2
  exit 1
fi

cd "$distilled_lua"
lua bin/distilled-lua vendor --out "$repo/vendor"
lua bin/distilled-lua generate --model "$model" --provider "$repo/providers/twitch.lua" \
  --out "$repo/vendor/twitch" --ops "$OPERATIONS"
cp LICENSE NOTICE "$repo/vendor/distilled/"
