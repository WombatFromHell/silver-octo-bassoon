#!/usr/bin/env bash
set -euo pipefail

case "$1" in
idle) niri msg output "DP-1" off ;;
active) niri msg output "DP-1" on ;;
*)
  echo "Usage: $0 {idle|active}" >&2
  exit 1
  ;;
esac
