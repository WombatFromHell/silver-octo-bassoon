#!/usr/bin/env bash
DRI_PATH=${HOME}/.var/app/org.mozilla.firefox/dri

echo "Clearing firefox flatpak overrides"
flatpak override --user --reset org.mozilla.firefox

echo "Adding firefox flatpak overrides"
flatpak override --user --env=LIBVA_DRIVER_NAME=nvidia \
                        --env=LIBVA_DRIVERS_PATH=${DRI_PATH} \
                        --env=LIBVA_MESSAGING_LEVEL=1 \
                        --env=MOZ_DISABLE_RDD_SANDBOX=1 \
                        --env=NVD_BACKEND=direct \
                        org.mozilla.firefox

# uncomment the following if you use keepass running on the host
# flatpak override --user --filesystem=xdg-run/app/org.keepassxc.KeePassXC org.mozilla.firefox

echo "Copying nvidia vaapi driver into ${DRI_PATH}"
mkdir -p ${DRI_PATH}
cp -f /usr/lib64/dri/nvidia_drv_video.so ${DRI_PATH}/nvidia_drv_video.so

cat <<"EOF"

    Now open about:config and change `gfx.webrender.all` and `media.ffmpeg.vaapi.enabled` to true.

EOF
