#!/usr/bin/env bash
set -euo pipefail

case "${1:-start}" in
  start)
    systemctl --user set-environment \
      MANGOHUD=1 \
      "MANGOHUD_CONFIG=read_cfg,fps_limit=70,fps_limit_method=early,vsync=1"
    dbus-update-activation-environment --systemd MANGOHUD MANGOHUD_CONFIG
    ;;
  stop)
    systemctl --user unset-environment MANGOHUD MANGOHUD_CONFIG
    dbus-update-activation-environment --systemd MANGOHUD MANGOHUD_CONFIG
    ;;
esac
