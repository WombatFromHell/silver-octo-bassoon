#!/usr/bin/env bash

SCRIPTS="$HOME/.local/bin/scripts"
#
# STEAM=$(which steam)
STEAM="$SCRIPTS/bazzite-steam.sh"
# STEAM_ARGS=()
STEAM_ARGS=(
  -steamos3
  -steamdeck
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.py"
GAMESCOPE_ARGS=(
  -p std
  -p hdr
  -e
  --
)
#
CMD=(
  "${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}"
  "${STEAM}" "${STEAM_ARGS[@]}"
)

"${CMD[@]}" "${@}" steam://open/bigpicture
