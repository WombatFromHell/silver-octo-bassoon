#!/usr/bin/env bash
#
# modified from: https://github.com/CachyOS/CachyOS-Settings/blob/master/usr/bin/game-performance
#

if command -v powerprofilesctl &>/dev/null; then
	PPCTL="$(which powerprofilesctl)"
elif command -v tuned-adm &>/dev/null; then
	TUNEDADM="$(which tuned-adm)"
	GAME_PROF="throughput-performance-bazzite"
	DESK_PROF="balanced-bazzite"
else
	echo "Error: powerprofilesctl or tuned-adm not found!"
	exit 1
fi
if ! command -v systemd-inhibit &>/dev/null; then
	echo "Error: systemd-inhibit not found" >&2
	exit 1
else
	INHIBIT="$(which systemd-inhibit)"
fi
if ! command -v dbus-send &>/dev/null; then
	echo "Error: dbus-send not found" >&2
	exit 1
else
	DBUS_SEND="$(which dbus-send)"
fi

scx_wrapper() {
	local scx="${2:-scx_bpfland}"
	if [ "$1" == "load" ]; then
		"$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.StartScheduler string:"$scx" uint32:0
	elif [ "$1" == "unload" ]; then
		"$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.StopScheduler
	fi
}

# Don't fail if the CPU driver doesn't support performance power profile
if [ -n "$PPCTL" ] && ! "$PPCTL" list | grep -q 'performance:'; then
	exec "$@"
elif [ -n "$PPCTL" ]; then
	# Set performance governors, as long the game is launched
	"$INHIBIT" --why "perfboost.sh is running" \
		"$PPCTL" launch -p performance -r "Launched with perfboost.sh utility" -- "$@"
fi

if [ -n "$TUNEDADM" ] && ! "$TUNEDADM" list | grep -q "$GAME_PROF"; then
	exec "$@"
elif [ -n "$TUNEDADM" ]; then
	# Set performance mode before launching
	"$TUNEDADM" profile "$GAME_PROF"
	[ -n "$SCX" ] && scx_wrapper load
	"$INHIBIT" --why "perfboost.sh is running" -- "$@"
	# Reset back to default profile
	"$TUNEDADM" profile "$DESK_PROF"
	[ -n "$SCX" ] && scx_wrapper unload
fi
