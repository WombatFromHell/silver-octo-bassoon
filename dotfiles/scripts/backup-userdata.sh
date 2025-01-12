#!/usr/bin/env bash

DATE=$(date +%H%m%S_%m%d%y)
PDIR="userdata_backup_$DATE"
OUTDIR="$HOME/Downloads/$PDIR"

confirm() {
  read -r -p "$1 (Y/n) " response
  case "$response" in
  [nN])
    echo "Action aborted..."
    return 1
    ;;
  [yY] | "")
    return 0
    ;;
  *)
    echo "Action aborted!"
    return 1
    ;;
  esac
}

backup() {
  local dest="$1"
  local name="$2"
  shift 2
  local sources=("$@")
  local outfile="${name}-$DATE.tar.gz"

  echo "Processing archive: $outfile..."
  if tar czf "$dest/$outfile" "${sources[@]}"; then
    echo "Backup created at: $dest/$outfile"
    return 0
  fi
  return 1
}

mkdir -p "$OUTDIR" || exit 1

XDG_DATA="$HOME/.config"
if confirm "Backup directory: $XDG_DATA/BraveSoftware?"; then
  cd "$XDG_DATA" || exit 1
  backup "$OUTDIR" "BraveSoftware_backup" "./BraveSoftware"
fi

if confirm "Backup directory: $XDG_DATA/heroic?"; then
  cd "$XDG_DATA" || exit 1
  backup "$OUTDIR" "heroic_backup" "./heroic"
fi

if confirm "Backup directory: $XDG_DATA/Code?"; then
  cd "$XDG_DATA" || exit 1
  backup "$OUTDIR" "Code_backup" "./Code"
fi

STEAM_CONFIG_DIR="$HOME/.steam/steam/userdata/22932417/config"
if confirm "Backup directory: $STEAM_CONFIG_DIR?"; then
  cd "$STEAM_CONFIG_DIR" || exit 1
  backup "$OUTDIR" "steam_userdata_backup" \
    "./grid" "./librarycache" "./shortcuts.vdf"
fi

if confirm "Backup directory: $HOME/.mozilla?"; then
  cd "$HOME" || exit 1
  backup "$OUTDIR" "mozilla_backup" "./.mozilla"
fi
