#!/usr/bin/env bash

install() {
	systemctl --user enable {hypridle,hyprpaper,waybar}.service
}
uninstall() {
	systemctl --user disable --now {hypridle,hyprpaper,waybar}.service
}

if [ "$1" == "enable" ]; then
	install
	chmod 000 ~/.config/autostart/*.*
elif [ "$1" == "disable" ]; then
	uninstall
	chmod 644 ~/.config/autostart/*.*
else
	echo "$0 [enable | disable]"
	exit 0
fi
