#!/usr/bin/env bash
STEAM_SCRIPT="$(which bazzite-steam || which steam)"
# throw in some overrides
if [[ -n $STEAM_SCRIPT ]]; then
  # exec "${STEAM_SCRIPT}" +gyro_force_sensor_rate 250 -steamos3 "$@"
  exec "${STEAM_SCRIPT}" +gyro_force_sensor_rate 250 "$@"
else
  echo "Error! Couldn't find 'steam'!"
  exit 1
fi
