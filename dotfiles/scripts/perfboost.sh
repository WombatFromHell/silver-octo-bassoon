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
	"$INHIBIT" --why "perfboost.sh is running" -- "$@"
	# Reset back to default profile
	"$TUNEDADM" profile "$DESK_PROF"
fi
