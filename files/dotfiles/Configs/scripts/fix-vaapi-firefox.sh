#!/usr/bin/env bash

FIREFOX_APP="org.mozilla.firefox"

echo "Clearing firefox flatpak overrides"
flatpak override --user --reset "$FIREFOX_APP"

echo "Adding firefox flatpak overrides"
flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications "$FIREFOX_APP"
flatpak override --user --filesystem=xdg-run/app/org.keepassxc.KeePassXC "$FIREFOX_APP"

basedir="$HOME/.var/app/$FIREFOX_APP"
runfile="$basedir/.firefox-vaapi-fix-applied"
if [ -e "$runfile" ]; then
	echo "Detected '$runfile', fix has probably been applied, aborting..."
	exit 1
fi

outdir="$basedir/dri"
dri_lib="/usr/lib64/dri/nvidia_drv_video.so"
if ! [ -r "$dri_lib" ]; then
	echo "Error: unable to access '$dri_lib'!"
	exit 1
fi

mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
if ! cp -f "$dri_lib" "$outdir"; then
	echo "Error: unable to copy '$dri_lib' to '$outdir'!"
	exit 1
fi

flatpak --system --noninteractive install \
	runtime/org.freedesktop.Platform.ffmpeg-full//23.08

flatpak override --user \
	--env=MOZ_DISABLE_RDD_SANDBOX=1 \
	--env=LIBVA_DRIVERS_PATH="$outdir" \
	--env=LIBVA_DRIVER_NAME=nvidia \
	--env=NVD_BACKEND=direct \
	"$FIREFOX_APP"

mkdir -p "$basedir" && touch "$runfile"

cat <<"EOF"

    Now open about:config and change `media.ffmpeg.vaapi.enabled` to true.

EOF
