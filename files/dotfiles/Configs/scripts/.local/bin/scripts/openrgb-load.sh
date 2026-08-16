#!/usr/bin/env bash
set -euo pipefail

# Resolve OpenRGB to an executable (binary, AppImage, or flatpak)
cmd=()
if command -v openrgb &>/dev/null; then
  cmd=(openrgb)
elif [[ -e "$HOME/AppImages/openrgb.appimage" ]]; then
  cmd=("$HOME/AppImages/openrgb.appimage")
elif command -v flatpak &>/dev/null; then
  cmd=(flatpak run org.openrgb.OpenRGB)
else
  echo "openrgb-load: OpenRGB not found, skipping" >&2
  exit 0
fi

exec "${cmd[@]}" --noautoconnect -p lightsout
