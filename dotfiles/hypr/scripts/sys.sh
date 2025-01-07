#!/usr/bin/env bash

PREFIX=""
if command -v uwsm >/dev/null; then
	PREFIX="uwsm app --"
fi

close_steam() {
	pkill -SIGTERM -x "steam"
	current_time=$(date +%s)
	start_time=$(date +%s)
	# limit waiting to 30s
	max_wait=30
	while true; do
		COUNT=$(pgrep "steam" | wc -l)
		if [ "$COUNT" -eq 0 ]; then
			return
		fi

		current_time=$(date +%s)
		elapsed_time=$((current_time - start_time))
		if [ "$elapsed_time" -ge "$max_wait" ]; then
			return
		fi
		sleep 1
	done
}

graceful_exit() {
	notify-send "System" "Gracefully closing apps..."

	systemctl --user stop waybar.service
	systemctl --user stop pipewire.service
	systemctl --user stop wireplumber.service
	sleep 1

	# close all client windows
	HYPRCMDS=$(hyprctl --instance 0 -j clients | jq -j '.[] | "dispatch closewindow address:\(.address); "')
	hyprctl --instance 0 --batch "$HYPRCMDS" >/tmp/hyprgraceexit.log 2>&1
	sleep 1

	close_steam

	COUNT=$(hyprctl clients | grep -c "class:")
	if [ "$COUNT" -eq "0" ]; then
		sleep 1
		return
	else
		notify-send "System" "Some apps didn't close. Aborting exit."
		systemctl --user start waybar.service
		systemctl --user start pipewire.service
		systemctl --user start wireplumber.service
		exit 1
	fi
}

hypr_exit() {
	if pgrep -x "Hyprland" >/dev/null; then
		graceful_exit
		loginctl kill-session "$XDG_SESSION_ID"
	fi
}

hypr_shutdown() {
	graceful_exit
	systemctl poweroff
}

# MAIN #
if [ "$1" == "lock" ]; then
	$PREFIX hyprlock --immediate &
	sleep 3
	hyprctl dispatch dpms off
elif [ "$1" == "softlock" ] && pgrep -x "hypridle"; then
	loginctl lock-session
elif [ "$1" == "exit" ]; then
	hypr_exit
elif [ "$1" == "suspend" ]; then
	systemctl suspend
elif [ "$1" == "shutdown" ]; then
	hypr_shutdown
fi
