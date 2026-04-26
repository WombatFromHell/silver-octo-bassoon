#!/usr/bin/env bash
# Loads OpenRGB "lightsout" profile asynchronously.

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
LOG_FILE="$RUNTIME_DIR/openrgb-lightsout.log"

# Resolve OpenRGB binary
find_openrgb() {
  if command -v openrgb &>/dev/null; then
    command -v openrgb
  elif [[ -e "$HOME/AppImages/openrgb.appimage" ]]; then
    echo "$HOME/AppImages/openrgb.appimage"
  elif command -v flatpak &>/dev/null; then
    echo "flatpak run org.openrgb.OpenRGB"
  else
    return 1
  fi
}

OPENRGB="$(find_openrgb)" || {
  echo "openrgb-load: OpenRGB not found, skipping" >&2
  exit 0
}

nohup bash -c "
  $OPENRGB --noautoconnect -p lightsout
" </dev/null >"$LOG_FILE" 2>&1 &
disown

exit 0
