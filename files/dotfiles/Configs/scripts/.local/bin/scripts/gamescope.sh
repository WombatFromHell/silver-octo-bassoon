#!/usr/bin/env bash

# make sure to:
# sudo setcap 'cap_sys_nice=eip' $(which gamescope)

get_preferred_resolution() {
  output=$1
  if [ "$XDG_CURRENT_DESKTOP" == "KDE" ]; then
    kscreen-id.py --mode
    return
  fi

  if ! wlr-randr --output "$output" | grep -q "Enabled: yes"; then
    echo "Error: no enabled output found!"
    exit 1
  fi
  wlr-randr | grep -A 1 "Modes:" | grep "preferred" |
    sed -E 's/[[:space:]]+([0-9]+)x([0-9]+) px, ([0-9.]+) Hz.*$/\1 \2 \3/' |
    awk '{printf "%d %d %.0f\n", $1, $2, $3}'
}

OUTPUT="DP-3"
GPR=$(get_preferred_resolution "$OUTPUT")
WIDTH=$(echo "$GPR" | cut -d' ' -f1)
HEIGHT=$(echo "$GPR" | cut -d' ' -f2)
#RATE=$(echo "$GPR" | cut -d' ' -f3)

# hyprland gamemode cmd
HYPRGM="$HOME/.config/hypr/scripts/gamemode.sh"
#PERFUTIL="gamemoderun"
PERFUTIL=$(which game-performance)
GAMESCOPE=$(which gamescope)
PREFIX=("DXVK_FRAME_RATE=72")
ARGS=("$@")

GS_CLI=("-W ${WIDTH} -H ${HEIGHT} --hdr-enabled --force-grab-cursor --backend=wayland -f")

if [ "$XDG_CURRENT_DESKTOP" == "Hyprland" ] && [ "$1" == "--gm" ]; then
  ARGS=("${@:2}")
  echo "Got args: ${PREFIX[*]} $HYPRGM $PERFUTIL $GAMESCOPE ${GS_CLI[*]} ${ARGS[*]}" 2>&1 | tee /tmp/gamemode_log.txt
  {
    env "${PREFIX[*]}" \
      "$HYPRGM" "$PERFUTIL" "$GAMESCOPE" ${GS_CLI[*]} "${ARGS[@]}"
  } 2>&1 | tee -a /tmp/gamemode_log.txt
else
  ARGS=("${@:2}")
  echo "Got args: ${PREFIX[*]} $PERFUTIL $GAMESCOPE ${GS_CLI[*]} ${ARGS[*]}" 2>&1 | tee /tmp/gamemode_log.txt
  {
    env "${PREFIX[*]}" \
      "$PERFUTIL" "$GAMESCOPE" ${GS_CLI[*]} "${ARGS[@]}"
  } 2>&1 | tee -a /tmp/gamemode_log.txt
fi
