#!/usr/bin/env bash

BRAVE_VAR_APP="$HOME/.var/app/com.brave.Browser"
DRI_PATH="$BRAVE_VAR_APP/dri"
LOCAL_DRI_PATH="/usr/lib64/dri/nvidia_drv_video.so"

if [ -r "$LOCAL_DRI_PATH" ]; then
	mkdir -p "$DRI_PATH"
	cp -f "$LOCAL_DRI_PATH" "$DRI_PATH"/nvidia_drv_video.so
else
	echo "Error: Cannot locate nvidia_drv_video.so in lib path!"
	exit 1
fi

flatpak override --user --reset com.brave.Browser
flatpak override --user \
	--env=LIBVA_DRIVER_NAME=nvidia \
	--env=LIBVA_DRIVERS_PATH="${DRI_PATH}" \
	--env=NVD_BACKEND=direct \
	com.brave.Browser

echo "Copied nvidia-vaapi-driver to Flatpak config path!"
