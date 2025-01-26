#!/usr/bin/env bash

LOCAL="."
REMOTE="/mnt/home/GDrive/Backups/linux-config/backups/dotfiles/"

CMD=(rsync -avzL --checksum --partial --update --info=progress2)
EXCLUDES=(
  --exclude=__pycache__/
  --exclude=pipewire/
  --exclude='*.wants/'
)

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
  ADD=(--stats --delete "${EXCLUDES[@]}" --dry-run)
  ECMD=("${CMD[@]}" "${ADD[@]}" "$1" "$2")
  local result
  result=$("${ECMD[@]}" | grep "Number of regular files transferred" | awk -F ": " '{print $2}')

  if [[ $result -gt 0 ]]; then
    return 1
  else
    return 0
  fi
}

do_sync() {
  echo "==== PERFORMING A DRY RUN ===="
  echo "Syncing $1 => $2"
  "${CMD[@]}" "$1" "$2"
  if confirm "Please confirm sync of: $1 => $2"; then
    unset 'CMD[${#CMD[@]}-1]'
    # "${CMD[@]}" "$2" "$1"
    echo "Would normally do: ${CMD[*]} $1 $2"
  fi
}

sync() {
  CMD+=("--delete" "${EXCLUDES[@]}" "--dry-run")
  [ "$swap" == true ] && TARGETS=("$2" "$1") || TARGETS=("$1" "$2")
  if equality "${TARGETS[@]}"; then
    echo "No changes detected!"
    return
  fi
  do_sync "${TARGETS[@]}"
}

if [ "$1" == "--help" ]; then
  help
elif [ "$1" == "--swap" ]; then
  swap=true
fi

sync "$LOCAL" "$REMOTE"
