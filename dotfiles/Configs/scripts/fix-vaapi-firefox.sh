#!/usr/bin/env bash
DRI_PATH=${HOME}/.var/app/org.mozilla.firefox/dri

echo "Clearing firefox flatpak overrides"
flatpak override --user --reset org.mozilla.firefox

echo "Adding firefox flatpak overrides"
flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications org.mozilla.firefox
flatpak override --user --filesystem=xdg-run/app/org.keepassxc.KeePassXC org.mozilla.firefox

outdir="$HOME/.var/app/org.mozilla.firefox/dri"
mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
cp -f /usr/lib64/dri/nvidia_drv_video.so "$outdir"

flatpak --system --noninteractive install \
    runtime/org.freedesktop.Platform.ffmpeg-full//23.08

flatpak override --user \
    --env=MOZ_DISABLE_RDD_SANDBOX=1 \
    --env=LIBVA_DRIVERS_PATH="$outdir" \
    --env=LIBVA_DRIVER_NAME=nvidia \
    --env=NVD_BACKEND=direct \
    org.mozilla.firefox

cat <<"EOF"

    Now open about:config and change `media.ffmpeg.vaapi.enabled` to true.

EOF
