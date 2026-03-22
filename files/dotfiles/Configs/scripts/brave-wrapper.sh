#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="bravebox"
readonly LAUNCHER_SCRIPT="${HOME}/.local/bin/scripts/chrome_with_flags.py"
readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)

in_container() {
  [[ -n "${CONTAINER_ID:-}" ]] ||
    [[ -f /run/.containerenv ]] ||
    [[ -f /.dockerenv ]] ||
    grep -q container /proc/1/cgroup 2>/dev/null
}

find_browser() {
  local b
  for b in "${BROWSER_CANDIDATES[@]}"; do
    command -v "$b" &>/dev/null && printf '%s' "$b" && return
  done
  return 1
}

brave_flatpak_installed() {
  flatpak info com.brave.Browser &>/dev/null
}

distrobox_exists() {
  command -v distrobox &>/dev/null && distrobox list 2>/dev/null | grep -q "$CONTAINER_NAME"
}

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

main() {
  # Prefer Flatpak Brave if installed — no need for distrobox
  if brave_flatpak_installed; then
    "$LAUNCHER_SCRIPT" flatpak run com.brave.Browser "$@"
    exit $?
  fi

  # Fall back to distrobox container
  in_container || exec distrobox-enter -n "$CONTAINER_NAME" -- "$0" "$@"

  local browser
  browser=$(find_browser) || {
    echo "Error: no brave browser found in PATH" >&2
    exit 1
  }
  "$LAUNCHER_SCRIPT" "$browser" "$@" &
  local browser_pid=$!

  # Upgrade in background while browser runs
  {
    local out rc=0
    out=$(sudo dnf upgrade -y "$browser" 2>&1) || rc=$?
    if grep -qE "^(Upgrading|Installing|Removing): " <<<"$out"; then
      notify "Update Available" "$browser was upgraded. Restart the browser to apply updates."
    elif [[ $rc -ne 0 ]]; then
      notify "Upgrade Failed" "Failed to upgrade $browser." "critical"
    fi
    # rc=2 (nothing to do) -> no notification
  } &

  # Wait for browser to exit
  wait "$browser_pid"
}

main "$@"
