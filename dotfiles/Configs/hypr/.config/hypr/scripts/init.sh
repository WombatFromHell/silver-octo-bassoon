#!/usr/bin/env bash
RUN="$HOME/.config/hypr/scripts/run.sh"
if ! [ -e "$RUN" ]; then
  echo "Error: $RUN not found!"
  exit 1
fi

dbus-update-activation-environment --systemd --all
# try to fix audio volume value reset issue
systemctl --user restart {pipewire,wireplumber}.service
# try to ensure mouse cursor theme is consistent
hyprctl setcursor Catppuccin-Mocha-Dark 32 &&
  gsettings set org.gnome.desktop.interface cursor-theme 'Catppuccin-Mocha-Dark'
