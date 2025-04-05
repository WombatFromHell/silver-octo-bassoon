#!/usr/bin/env bash

DEFAULT_APP="com.brave.Browser"

show_usage() {
	cat <<EOF
Usage: $0 [options]
    --user         : Use user installation
    --app APP_ID   : Specify Flatpak app ID (default: $DEFAULT_APP)
    --local PATH   : Local NV driver path
EOF
	exit 1
}

do_overrides() {
	local app=$1
	local dri=$2
	local user_opt=$3

	flatpak override "$user_opt" --reset "$APP" 2>/dev/null
	flatpak override "$user_opt" \
		--env=LIBVA_DRIVER_NAME=nvidia \
		--env=LIBVA_DRIVERS_PATH="$dri" \
		--env=NVD_BACKEND=direct "$app"
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

APP="${APP_NAME:-$DEFAULT_APP}"
LOCAL_DRI_PATH="${LOCAL_PATH:-/usr/lib64/dri/nvidia_drv_video.so}"
BASE_DIR="$(realpath "$HOME")/.var/app/$APP"
DRI_PATH="$BASE_DIR/dri"
REMOTE_DRI_PATH="$DRI_PATH/nvidia_drv_video.so"
user_opt="${USER_FLAG:+--user}"

[ -z "$APP_NAME" ] && APP_NAME=$APP

if ! (flatpak "$user_opt" list | grep -q "$APP"); then
	echo "App '$APP' not found in flatpak"
	exit 1
fi

if [ -r "$REMOTE_DRI_PATH" ]; then
	do_overrides "$APP" "$REMOTE_DRI_PATH" "$user_opt"
	echo "Detected '$REMOTE_DRI_PATH', fix has already run, redoing overrides..."
	exit 0
fi

[ ! -r "$LOCAL_DRI_PATH" ] && echo "Can't find driver at $LOCAL_DRI_PATH" && exit 1

rm -rf "$DRI_PATH" &&
	mkdir -p "$DRI_PATH" &&
	cp -f "$LOCAL_DRI_PATH" "$DRI_PATH/nvidia_drv_video.so"

do_overrides "$APP" "$REMOTE_DRI_PATH" "$user_opt"

echo "NVIDIA driver configured for $APP at $DRI_PATH"
