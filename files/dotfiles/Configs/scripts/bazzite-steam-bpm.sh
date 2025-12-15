#!/usr/bin/env bash

add_if_exists() {
  local array_name="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    eval "$array_name+=(\"$file\")"
  fi
}

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
  --mangoapp
  -e
  --
)
ENV_VARS=(
  env
  PROTON_USE_NTSYNC=1
  PROTON_ENABLE_WAYLAND=1
  DXVK_FRAME_RATE=72
  VKD3D_FRAME_RATE=72
  MESA_VK_WSI_PRESENT_MODE="mailbox"
)

# include some optional wrappers conditionally
OTHER_WRAPPERS=()
add_if_exists "OTHER_WRAPPERS" "$HOME/mesa/mesa-run.sh"
add_if_exists "OTHER_WRAPPERS" "$SCRIPTS/perfboost.sh"

#
CMD=(
  "${ENV_VARS[@]}"
  "${OTHER_WRAPPERS[@]}"
  "${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}"
  "${STEAM}" "${STEAM_ARGS[@]}"
)

"${CMD[@]}" "${@}"
