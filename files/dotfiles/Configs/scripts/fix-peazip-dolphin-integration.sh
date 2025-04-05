#!/usr/bin/env bash

function do_overrides() {
	local app=$1
	local dolphin_exports=$2
	local srv_menu_path=$3

	"$FLATPAK" ${MODE:+$MODE} override --filesystem=~/.local/share/kio/servicemenus "$app"
	"$FLATPAK" ${MODE:+$MODE} run --command=sh "$app" -c \
		"mkdir -p $srv_menu_path && \
      cp -f $dolphin_exports/* $srv_menu_path/ && \
      chmod +x $srv_menu_path/*"
}

function fix_context_menu() {
	local app="io.github.peazip.PeaZip"

	if ! FLATPAK=$(which flatpak); then
		echo "Error: 'flatpak' not found!"
		exit 1
	fi
	if ! AWK=$(which awk); then
		echo "Error: 'awk' not found!"
		exit 1
	fi
	if ! GREP=$(which grep); then
		echo "Error: 'grep' not found!"
		exit 1
	fi

	local app_installed
	app_installed=$("$FLATPAK" list --app | "$GREP" "$app")
	local result="$?"
	if [ $result -ne 0 ]; then
		echo "Error: '$app' app is not installed!"
		exit 1
	fi

	local MODE
	MODE="$(echo "$app_installed" | "$AWK" '{print $NF}')"
	if [ "$MODE" == "user" ]; then
		MODE="--user"
	else
		MODE=""
	fi

	local srv_menu_path="$HOME/.local/share/kio/servicemenus"
	local dolphin_exports="/app/peazip/res/share/batch/freedesktop_integration/KDE-servicemenus/KDE5-dolphin"

	if [ -r "$srv_menu_path/peazipadd.desktop" ]; then
		echo "Detected remnants of servicemenus at '$srv_menu_path', fix has been applied before, skipping..."
		do_overrides "$app" "$dolphin_exports" "$srv_menu_path"
		exit 0
	else
		do_overrides "$app" "$dolphin_exports" "$srv_menu_path"
	fi

	echo "Copied KDE5/6 Dolphin context menu entries to $srv_menu_path!"
}

fix_context_menu
