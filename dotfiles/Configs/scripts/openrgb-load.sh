#!/usr/bin/env bash

if command -v openrgb &>/dev/null; then
	OPENRGB="$(command -v openrgb)"
elif command -v flatpak &>/dev/null; then
	OPENRGB="$(command -v flatpak) run org.openrgb.OpenRGB"
else
	echo "Error: OpenRGB cannot be found in PATH, aborting!"
	exit 1
fi

do_lightsout() {
	NUM_DEVICES=$("$OPENRGB" --noautoconnect --list-devices | grep -cE '^[0-9]+: ')

	for i in $(seq 0 $((NUM_DEVICES - 1))); do
		"$OPENRGB" --noautoconnect --device "$i" --mode static --color 000000
	done
}

if [ "$1" == "--fallback" ]; then
	do_lightsout
else
	eval "$OPENRGB" --noautoconnect -p lightsout
fi
