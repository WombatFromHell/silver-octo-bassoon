#!/usr/bin/env bash

LOCAL="."
REMOTE="/mnt/home/GDrive/Backups/linux-config/backups/dotfiles/"

_CMD=(rsync -avzL --checksum --partial --update --info=progress2)
EXCLUDES=(
  --exclude=__pycache__/
  --exclude=pipewire/
  --exclude='*.wants/'
  --exclude='hrir.wav'
  --exclude='nix/'
  --exclude='hardware-configuration.nix'
)
DOWN_CMD=("${_CMD[@]}" "${EXCLUDES[@]}")
UP_CMD=("${DOWN_CMD[@]}" "--delete")
EQ_CMD=("${DOWN_CMD[@]}" "--stats" "--dry-run")

script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the same directory as the dotfiles!"
  exit 1
fi

if ! [ -r "$LOCAL" ]; then
  echo "Error: $LOCAL does not exist or is not readable!"
  exit 1
fi
if ! [ -r "$REMOTE" ]; then
  echo "Error: $REMOTE does not exist or is not readable!"
  exit 1
fi

help() {
  echo "Usage: $0 [--swap]"
  exit 1
}

confirm() {
  read -r -p "$1 (y/N) " response
  if [[ "$response" == "y" || "$response" == "Y" ]]; then
    return 0
  else
    echo "Aborting..."
    return 1
  fi
}

equality() {
  local result
  result=$(
    "${EQ_CMD[@]}" "$@" |
      grep "Number of regular files transferred" |
      awk -F ": " '{print $2}'
  )

  if [ "$result" -eq 0 ]; then
    echo "No changes detected!"
    return 0
  else
    return 1
  fi
}

do_sync() {
  echo "==== PERFORMING A DRY RUN ===="
  "${UP_CMD[@]}" "--dry-run" "${@}"
  if echo && confirm "Confirm syncing: $1 => $2"; then
    "${UP_CMD[@]}" "$@"
    # echo "Would normally do: ${UP_CMD[*]} $*"
  fi
}

sync() {
  [ "$swap" == true ] && TARGETS=("$2" "$1") || TARGETS=("$1" "$2")
  if ! equality "${TARGETS[@]}"; then
    do_sync "${TARGETS[@]}"
  fi
}

if [ "$1" == "--help" ]; then
  help
elif [ "$1" == "--swap" ]; then
  swap=true
fi

sync "$LOCAL" "$REMOTE"
