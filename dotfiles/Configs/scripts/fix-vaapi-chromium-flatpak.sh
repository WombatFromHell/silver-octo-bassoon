#!/usr/bin/env bash

show_usage() {
	cat <<EOF
Usage: $0 [options]
    --user         : Use user installation
    --app APP_ID   : Specify Flatpak app ID
    --local PATH   : Local NV driver path
EOF
	exit 1
}

USER_FLAG=false
APP_NAME=""
LOCAL_PATH=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--user)
		USER_FLAG=true
		shift
		;;
	--app=*)
		APP_NAME="${1#--app=}"
		shift
		;;
	--app)
		if [ "$#" -gt 1 ]; then
			APP_NAME="$2"
			shift 2
		else
			echo "Error: --app requires argument"
			show_usage
		fi
		;;
	--local=*)
		LOCAL_PATH="${1#--local=}"
		shift
		;;
	--local)
		if [ "$#" -gt 1 ]; then
			LOCAL_PATH="$2"
			shift 2
		else
			echo "Error: --local requires argument"
			show_usage
		fi
		;;
	*)
		echo "Unknown option: $1"
		show_usage
		;;
	esac
done

APP="${APP_NAME:-com.brave.Browser}"
LOCAL_DRI_PATH="${LOCAL_PATH:-/usr/lib64/dri/nvidia_drv_video.so}"
DRI_PATH="$HOME/.var/app/$APP/dri"
user_opt="${USER_FLAG:+--user}"

[ -z "$APP_NAME" ] && APP_NAME=$APP

if ! (flatpak "$user_opt" list | grep -q "$APP"); then
	echo "App '$APP' not found in flatpak"
	exit 1
fi

[ ! -r "$LOCAL_DRI_PATH" ] && echo "Can't find driver at $LOCAL_DRI_PATH" && exit 1

rm -rf "$DRI_PATH" &&
	mkdir -p "$DRI_PATH" &&
	cp -f "$LOCAL_DRI_PATH" "$DRI_PATH/nvidia_drv_video.so"

flatpak override "$user_opt" --reset "$APP" 2>/dev/null
flatpak override "$user_opt" \
	--env=LIBVA_DRIVER_NAME=nvidia \
	--env=LIBVA_DRIVERS_PATH="$DRI_PATH" \
	--env=NVD_BACKEND=direct "$APP"

echo "NVIDIA driver configured for $APP at $DRI_PATH"
