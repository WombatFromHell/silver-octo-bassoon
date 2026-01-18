#!/usr/bin/env bash

add_if_exists() {
  local array_name="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    eval "$array_name+=(\"$file\")"
  fi
}

SCRIPTS="$HOME/.local/bin/scripts"

# STEAM=$(which steam)
STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -steamos3
  -tenfoot
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.pyz"
GAMESCOPE_ARGS=(
  -p std
  -p vsr4k
  --mangoapp
  -e
  --
)

# Local Steam-specific variables (kept as requested) as array
LOCAL_STEAM_ENV_VARS=(
  "PROTON_ENABLE_WAYLAND=1"
)

# Add local Steam-specific variables using env
CMD+=(
  env "${LOCAL_STEAM_ENV_VARS[@]}"
)

# include some optional wrappers conditionally
OTHER_WRAPPERS=()
add_if_exists "OTHER_WRAPPERS" "$HOME/mesa/mesa-run.sh"
add_if_exists "OTHER_WRAPPERS" "$SCRIPTS/perfboost.sh"

# Add the rest of the command chain
CMD+=(
  "${OTHER_WRAPPERS[@]}"
  "${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}"
  "${STEAM}" "${STEAM_ARGS[@]}"
)

# Execute the full command chain
"${CMD[@]}" "${@}"
