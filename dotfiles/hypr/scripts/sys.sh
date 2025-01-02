#!/usr/bin/env bash

PREFIX=""
if
	command -v uwsm &
	/dev/null
then
	PREFIX="uwsm app --"
fi

hypr_exit() {
	if pgrep -x "Hyprland" &>/dev/null; then
		$PREFIX hyprctl dispatch exit
	fi
}
lock() {
	$PREFIX hyprlock &
}
sys_suspend() {
	lock
	disown
	systemctl suspend
}

if [ "$1" == "lock" ]; then
	lock
elif [ "$1" == "exit" ]; then
	hypr_exit
elif [ "$1" == "suspend" ]; then
	sys_suspend
fi
