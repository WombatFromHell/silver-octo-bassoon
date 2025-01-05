#!/usr/bin/env bash

# make sure to:
# sudo setcap 'cap_sys_nice=eip' /usr/bin/gamescope

get_preferred_resolution() {
	output=$1
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

#PERFUTIL="gamemoderun"
PERFUTIL="game-performance"
GAMESCOPE=$(which gamescope)

HYPRGAMEMODE=$(hyprctl getoption animations:enabled | awk 'NR==1{print $2}')
if [ "$HYPRGAMEMODE" -eq 1 ]; then
	hyprctl --batch "\
        keyword animations:enabled 0;\
        keyword decoration:shadow:enabled 0;\
        keyword decoration:blur:enabled 0;\
        keyword general:gaps_in 0;\
        keyword general:gaps_out 0;\
        keyword general:border_size 1;\
        keyword decoration:rounding 0"
	$PERFUTIL "$GAMESCOPE" \
		-W "$WIDTH" -H "$HEIGHT" \
		--hdr-enabled \
		-f "$@"
fi
hyprctl reload
