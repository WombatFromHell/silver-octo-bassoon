#!/usr/bin/env bash

check_cmd() {
	if cmd_path=$(command -v "$1"); then
		echo "$cmd_path"
	else
		echo ""
	fi
}

dep_check() {
	SCX="${SCX:-}"
	#
	PPCTL="$(check_cmd "powerprofilesctl")"
	TUNED="$(check_cmd "tuned-adm")"
	#
	if [ -z "$PPCTL" ] && [ -z "$TUNED" ]; then
		echo "Error: 'powerprofilesctl' or 'tuned-adm' are required, exiting!"
		exit 1
	fi
	#
	if ! INHIBIT="$(check_cmd "systemd-inhibit")"; then
		echo "Error: 'systemd-inhibit' is required, exiting!"
		exit 1
	fi
	if ! DBUS_SEND="$(check_cmd "dbus-send")"; then
		echo "Error: 'dbus-send' is required, exiting!"
		exit 1
	fi
}
dep_check # do dependency check early for safety

scx_wrapper() {
	local scx="${2:-scx_bpfland}"
	BPFLAND="$(check_cmd "$scx")"
	[ -z "$SCX" ] && return
	if [ -z "$BPFLAND" ]; then
		echo "Error: '$scx' required for scx_wrapper(), skipping..."
		return
	fi

	if [ "$1" = "load" ]; then
		"$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.StartScheduler string:"$scx" uint32:0
	elif [ "$1" = "unload" ]; then
		"$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.StopScheduler
	fi
}

cleanup() {
	if [ -n "$TUNED" ]; then
		"$TUNED" profile "$DESK_PROF"
	fi
	scx_wrapper unload
}

handle_tool() {
	local ENV_PREFIX=(env PULSE_LATENCY_MSEC=60)

	# pre-commands
	scx_wrapper load

	if [ -n "$PPCTL" ]; then
		if ! "$PPCTL" list 2>&1 | grep -q 'performance:'; then
			"${ENV_PREFIX[@]}" "$@" # used when no 'performance' governor exists
		else
			"${ENV_PREFIX[@]}" "$INHIBIT" --why "perfboost.sh is running" \
				"$PPCTL" launch -p performance -r "Launched with perfboost.sh utility" -- "$@"
		fi
	elif [ -n "$TUNED" ]; then
		GAME_PROF="throughput-performance-bazzite"
		DESK_PROF="balanced-bazzite"

		if ! "$TUNED" list 2>&1 | grep -q "$GAME_PROF"; then
			"${ENV_PREFIX[@]}" "$@"
		else
			"$TUNED" profile "$GAME_PROF"
			"${ENV_PREFIX[@]}" "$INHIBIT" --why "perfboost.sh is running" -- "$@"
			"$TUNED" profile "$DESK_PROF"
		fi
	else
		echo "Error: 'powerprofilesctl' or 'tuned-adm' required, aborting!"
		exit 1
	fi

	# post-commands
	scx_wrapper unload
}

trap "cleanup" EXIT
handle_tool "$@"
