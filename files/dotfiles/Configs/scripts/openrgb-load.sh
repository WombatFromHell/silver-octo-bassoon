#!/usr/bin/env bash

if which openrgb &>/dev/null; then
	OPENRGB="$(which openrgb)"
elif [ -e "$HOME/AppImages/openrgb.appimage" ]; then
	OPENRGB="$HOME/AppImages/openrgb.appimage"
elif which flatpak &>/dev/null; then
	OPENRGB="$(which flatpak) run org.openrgb.OpenRGB"
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
