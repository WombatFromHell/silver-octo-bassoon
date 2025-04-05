#!/usr/bin/env bash

FIREFOX_APP="org.mozilla.firefox"

do_overrides() {
	local app=$1
	local outdir=$2

	echo "Clearing firefox flatpak overrides"
	flatpak override --user --reset "$app"
	echo "Adding firefox flatpak overrides"
	flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications "$app"
	flatpak override --user --filesystem=xdg-run/app/org.keepassxc.KeePassXC "$app"
	flatpak override --user \
		--env=MOZ_DISABLE_RDD_SANDBOX=1 \
		--env=LIBVA_DRIVERS_PATH="$outdir" \
		--env=LIBVA_DRIVER_NAME=nvidia \
		--env=NVD_BACKEND=direct \
		"$app"
}

basedir="$HOME/.var/app/$FIREFOX_APP"
outdir="$basedir/dri"
dri_lib="/usr/lib64/dri/nvidia_drv_video.so"
remote_dri="$outdir/nvidia_drv_video.so"
if ! [ -r "$dri_lib" ]; then
	echo "Error: unable to access '$dri_lib'!"
	exit 1
fi
if [ -r "$remote_dri" ]; then
	echo "Detected '', fix already applied, redoing overrides..."
	do_overrides "$FIREFOX_APP" "$outdir"
	exit 0
fi

mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
if ! cp -f "$dri_lib" "$outdir"; then
	echo "Error: unable to copy '$dri_lib' to '$outdir'!"
	exit 1
fi

flatpak --system --noninteractive install \
	runtime/org.freedesktop.Platform.ffmpeg-full//23.08
do_overrides "$FIREFOX_APP" "$outdir"

cat <<"EOF"

    Now open about:config and change `media.ffmpeg.vaapi.enabled` to true.

EOF
