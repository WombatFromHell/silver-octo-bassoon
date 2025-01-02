#!/usr/bin/env bash

PREFIX=""
if command -v uwsm &>/dev/null; then
	PREFIX="uwsm app --"
fi

capture_window() {
	window_info=$(hyprctl -j activewindow)
	x=$(echo "$window_info" | jq -r '.at[0]')
	y=$(echo "$window_info" | jq -r '.at[1]')
	width=$(echo "$window_info" | jq -r '.size[0]')
	height=$(echo "$window_info" | jq -r '.size[1]')

	echo "$x,$y ${width}x${height}"
}

if [ "$1" == "region" ]; then
	$PREFIX grim -g "$(slurp)"
elif [ "$1" == "window" ]; then
	$PREFIX grim -g "$(capture_window)"
else
	$PREFIX grim
fi
