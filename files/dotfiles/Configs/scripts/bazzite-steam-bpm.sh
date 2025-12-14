#!/usr/bin/env bash

SCRIPTS="$HOME/.local/bin/scripts"
#
# STEAM=$(which steam)
STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -steamos3
  -tenfoot
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.pyz"
GAMESCOPE_ARGS=(
  -p std
  -p hdr
  -e
  --
)
ENV_VARS=(
  env
  PROTON_ENABLE_WAYLAND=1
  DXVK_FRAME_RATE=72
  VKD3D_FRAME_RATE=72
)
PRE_WRAPPER="$SCRIPTS/perfboost.sh"
#
CMD=(
  "${ENV_VARS[@]}"
  "${PRE_WRAPPER}"
  "${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}"
  "${STEAM}" "${STEAM_ARGS[@]}"
)

"${CMD[@]}" "${@}"
