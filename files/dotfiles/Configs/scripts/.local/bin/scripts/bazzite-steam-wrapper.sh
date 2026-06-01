#!/usr/bin/env bash

# Universal wrapper for bazzite-steam
# Works on host or inside distrobox container

STEAM_CMD="/usr/bin/bazzite-steam"

# Detect if running inside a container
in_container() {
  [[ -n "${CONTAINER_ID:-}" ]] && return 0
  [[ -f /run/.containerenv ]] && return 0
  [[ -f /.dockerenv ]] && return 0
  grep -q container /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

if in_container && command -v distrobox-host-exec >/dev/null 2>&1; then
  # Forward to host via distrobox
  exec /usr/bin/distrobox-host-exec "$STEAM_CMD" "$@"
else
  # Run directly on host
  exec "$STEAM_CMD" "$@"
fi
