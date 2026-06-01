#!/usr/bin/env bash

help() {
  echo "Usage: [ mount | unmount ] [IMAGE PATH] <MOUNTPOINT | /mnt/iso>"
  exit 1
}

MOUNTPOINT="${3:-/mnt/iso}"

iso_mount() {
  sudo mkdir -p "$MOUNTPOINT"
  sudo mount -o loop "$IMAGE" "$MOUNTPOINT"
}

iso_umount() {
  sudo umount "$MOUNTPOINT"
  sudo rmdir "$MOUNTPOINT"
}

if [ -n "$2" ]; then
  IMAGE="$2"
else
  echo "Error: must specify an image path!"
  help
fi

if [[ $# -gt 0 ]] && [[ $1 == "mount" ]]; then
  iso_mount
elif [[ $# -gt 0 ]] && [[ $1 == "unmount" ]]; then
  iso_umount
else
  help
fi

exit 0
