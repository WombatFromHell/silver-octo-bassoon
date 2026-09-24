#!/usr/bin/env bash
set -euo pipefail

declare -A ENV_MAP=(
  [MANGOHUD]="0"
  [MANGOHUD_CONFIG]="read_cfg,fps_limit=70,fps_limit_method=early,vsync=1"
)

KEYS=("${!ENV_MAP[@]}")

case "${1:-}" in
start)
  ARGS=()
  for k in "${KEYS[@]}"; do
    ARGS+=("$k=${ENV_MAP[$k]}")
  done

  systemctl --user set-environment "${ARGS[@]}"
  dbus-update-activation-environment --systemd "${ARGS[@]}"
  ;;

stop)
  systemctl --user unset-environment "${KEYS[@]}"

  UNSET_ARGS=()
  for k in "${KEYS[@]}"; do
    UNSET_ARGS+=("-u" "$k")
  done

  env "${UNSET_ARGS[@]}" \
    dbus-update-activation-environment --systemd
  ;;

*)
  echo "usage: $0 {start|stop}" >&2
  exit 1
  ;;
esac
