#!/usr/bin/env bash
set -euxo pipefail

IMAGE="${2:-/mnt/linuxgames/VFIO/win11.img}"
DEVMAP_ROOT="/dev/mapper/loop0p3" # assumes a win11 install
MOUNTPOINT="${3:-/mnt/rawimage}"


mount () {
	sudo mkdir -p "$MOUNTPOINT"
	sudo kpartx -av "$IMAGE"
	sudo mount "$DEVMAP_ROOT" "$MOUNTPOINT"
}

umount () {
	sudo umount "$MOUNTPOINT"
	sudo kpartx -d "$IMAGE"
	sudo rmdir "$MOUNTPOINT"
}

if [[ $# -gt 0 ]] && [[ $1 == "mount" ]]; then
	mount "$1"
elif [[ $# -gt 0 ]] && [[ $1 == "unmount" ]]; then
	umount "$1"
else
	echo "Usage: [ mount | unmount ] [IMAGE PATH] [MOUNTPOINT]"
	exit 1
fi

exit 0

