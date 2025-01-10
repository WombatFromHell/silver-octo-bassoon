#!/usr/bin/env bash
# set -euxo pipefail

EXT_OUT="HDMI-0"
PC_OUT="DP-4"
TARGET_EXT_RES="3840x2160@120"
TARGET_PC_RES="2560x1440@144"

filter_by_res() {
  local output=""
  local dev="$1"
  local res="$2"
  if command -v "kscreen-id.py" &>/dev/null; then
    output=$(kscreen-id.py "$dev" "$res")
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
      echo "$output"
    else
      echo ""
    fi
  else
    echo ""
  fi
}

DEFAULT_ID=$(wpctl status | awk '/Game/ {gsub(/\*|\./, "", $0); print $2}')
HDMI_ID=$(wpctl status | awk '/HDMI/ {gsub(/\*|\./, "", $0); print $2}')
PC_MON_ID=$(filter_by_res "$PC_OUT" "$TARGET_PC_RES")
EXT_MON_ID=$(filter_by_res "$EXT_OUT" "$TARGET_EXT_RES")

echo "$PC_OUT -> $PC_MON_ID & ${EXT_OUT} -> ${EXT_MON_ID}"

#
# switch to secondary monitor only
if [ -n "$EXT_MON_ID" ]; then
  kscreen-doctor output."$PC_OUT".disable output."$EXT_OUT".mode."$EXT_MON_ID" output."$EXT_OUT".enable
  # switch to HDMI audio out
  wpctl set-default "${HDMI_ID}"
  # force nvidia powermizer performance mode
  # nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1"
else
  echo "Error: No matching external monitor mode found, not changing modes!"
fi

#
# wait until the game exits
PULSE_LATENCY_MSEC=60 "$@"

#
# reset the monitor configuration
if [ -n "$PC_MON_ID" ]; then
  kscreen-doctor output."$EXT_OUT".disable output."$PC_OUT".mode."$PC_MON_ID" output."$PC_OUT".enable
  # switch to Game audio out
  wpctl set-default "${DEFAULT_ID}"
  # nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0"
else
  echo "Error: No matching local monitor mode found, not changing modes!"
fi
