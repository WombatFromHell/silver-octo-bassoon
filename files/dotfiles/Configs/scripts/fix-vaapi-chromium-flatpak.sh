#!/usr/bin/env bash

set -euxo pipefail
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

detect_gpu() {
	local base_dir="/usr/lib64/dri"
	! [ -d "/usr/lib64/dri" ] && base_dir="/usr/lib/dri" # fallback
	local drivers=("nvidia_drv_video.so" "radeonsi_drv_video.so")

	for driver in "${drivers[@]}"; do
		local path="$base_dir/$driver"
		if [ -r "$path" ]; then
			echo "$path"
			return 0
		fi
	done
	echo ""
}

do_overrides() {
	local app=$1
	local local_dri=$2
	local remote_dri=$3
	local user_opt=$4

	flatpak override "$user_opt" --reset "$app" 2>/dev/null

	# Set LIBVA_DRIVER_NAME based on GPU type
	local libva_driver=()
	if [[ "$local_dri" == *nvidia* ]]; then
		libva_driver=("--env=LIBVA_DRIVER_NAME=nvidia --env=NVD_BACKEND=direct")
	fi

	flatpak override "$user_opt" \
		--env=LIBVA_DRIVERS_PATH="$(dirname "$remote_dri")" \
		"${libva_driver[@]}" \
		"$app"
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
LOCAL_DRI_PATH="${LOCAL_PATH:-$(detect_gpu)}"
BASE_DIR="$(realpath "$HOME")/.var/app/$APP"
DRI_PATH="$BASE_DIR/dri"
REMOTE_DRI_PATH="$DRI_PATH/$(basename "$LOCAL_DRI_PATH")"
user_opt="${USER_FLAG:+--user}"

[ -z "$APP_NAME" ] && APP_NAME=$APP

if ! (flatpak "$user_opt" list | grep -q "$APP"); then
	echo "App '$APP' not found in flatpak"
	exit 1
fi

if ! [ -r "$LOCAL_DRI_PATH" ]; then
	echo "Unable to detect a supported VAAPI GPU driver, exiting..."
	exit 1
fi

if [ -r "$REMOTE_DRI_PATH" ]; then
	do_overrides "$APP" "$REMOTE_DRI_PATH" "$user_opt"
	echo "Detected '$REMOTE_DRI_PATH', fix has already run, redoing overrides..."
	exit 0
fi

rm -rf "$DRI_PATH" &&
	mkdir -p "$DRI_PATH" &&
	cp -f "$LOCAL_DRI_PATH" "$REMOTE_DRI_PATH"

do_overrides "$APP" "$LOCAL_DRI_PATH" "$REMOTE_DRI_PATH" "$user_opt"

echo "VAAPI GPU driver configured for $APP at $DRI_PATH"
