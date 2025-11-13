#!/usr/bin/env bash
STEAM_SCRIPT="$(which bazzite-steam || which steam)"
STEAM_ARGS=(
  -steamos3 # for Steam Input in Wayland
  +gyro_force_sensor_rate 250
)

# throw in some overrides
if [[ -n $STEAM_SCRIPT ]]; then
  exec "${STEAM_SCRIPT}" "${STEAM_ARGS[@]}" "$@"
else
  echo "Error! Couldn't find 'steam'!"
  exit 1
fi
