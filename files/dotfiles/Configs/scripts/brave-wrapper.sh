#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="bravebox"
readonly CHROMIUM_FLAGS_SCRIPT="${HOME}/.local/bin/scripts/chromium-flags.sh"
readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)
readonly FLATPAK_ID="com.brave.Browser"

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------
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
  command -v flatpak &>/dev/null && flatpak info "${FLATPAK_ID}" &>/dev/null
}

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  command -v notify-send &>/dev/null && notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# Browser Launch Functions
#------------------------------------------------------------------------------
launch_flatpak() {
  if ! command -v flatpak &>/dev/null; then
    echo "Error: flatpak command not found" >&2
    return 1
  fi

  # Use chromium-flags.sh to inject flags
  exec "$CHROMIUM_FLAGS_SCRIPT" flatpak run "${FLATPAK_ID}" "$@"
}

launch_distrobox() {
  local browser="$1"
  shift

  if ! command -v distrobox-enter &>/dev/null; then
    echo "Error: distrobox-enter command not found" >&2
    return 1
  fi

  # Use chromium-flags.sh to inject flags after '--'
  exec "$CHROMIUM_FLAGS_SCRIPT" distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@"
}

launch_direct() {
  local browser="$1"
  shift

  # Use chromium-flags.sh to inject flags
  exec "$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@"
}

#------------------------------------------------------------------------------
# Background Updater
#------------------------------------------------------------------------------
background_update() {
  local browser="$1"
  local out rc=0

  echo "Checking in the background for package updates for ${browser}..."
  out=$(sudo dnf upgrade -y "$browser" 2>&1) || rc=$?
  if grep -qE "^(Upgrading|Installing|Removing): " <<<"$out"; then
    notify "Update Available" "$browser was upgraded. Restart the browser to apply updates."
  elif [[ $rc -ne 0 ]]; then
    notify "Upgrade Failed" "Failed to upgrade $browser." "critical"
  else
    echo "No updates found for the ${browser} package..."
  fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
  # Prefer Flatpak Brave if installed
  if brave_flatpak_installed; then
    launch_flatpak "$@"
  fi

  # Fall back to distrobox container
  if ! in_container; then
    exec distrobox-enter -n "$CONTAINER_NAME" -- "$0" "$@"
  fi

  # Inside container: find browser
  local browser
  browser=$(find_browser) || {
    echo "Error: no brave browser found in PATH (tried: ${BROWSER_CANDIDATES[*]})" >&2
    exit 1
  }

  # Check for upgrades only if no browser processes are running
  if ! pgrep -x "$browser" &>/dev/null; then
    # Detach the background update so it survives the exec below
    background_update "$browser" </dev/null &
    disown
  fi

  # Launch browser (exec replaces this shell)
  launch_direct "$browser" "$@"
}

main "$@"
