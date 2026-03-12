#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="bravebox"
readonly LAUNCHER_SCRIPT="${HOME}/.local/bin/scripts/chrome_with_flags.py"
readonly NOTIFY_APP="bravebox-wrapper"
readonly BROWSER_PROCESS="brave"
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

notify() {
  local title="$1" body="$2"
  if command -v notify-send &>/dev/null; then
    notify-send -a "$NOTIFY_APP" "$title" "$body" 2>/dev/null
  else
    gdbus call --session \
      --dest org.freedesktop.Notifications \
      --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.Notify \
      "$NOTIFY_APP" uint32:0 string:"" string:"$title" string:"$body" \
      array:{} array:{} int32:-1 &>/dev/null || true
  fi
}

upgrade() {
  local pkg="$1" out rc=0
  out=$(sudo dnf upgrade -y "$pkg" 2>&1) || rc=$?
  echo "$out"
  if grep -qE "^(Upgrading|Installing|Removing): " <<<"$out"; then
    return 0 # upgraded
  elif [[ $rc -ne 0 ]]; then
    return 1 # error
  fi
  return 2 # nothing to do
}

main() {
  in_container || exec distrobox-enter -n "$CONTAINER_NAME" -- "$0" "$@"

  local browser
  browser=$(find_browser) || {
    echo "Error: no brave browser found in PATH" >&2
    exit 1
  }

  if pgrep -x "$BROWSER_PROCESS" &>/dev/null; then
    echo "Browser still running, skipping upgrade."
  else
    local rc=0
    upgrade "$browser" || rc=$?
    case $rc in
    0) notify "Upgrade Complete" "$browser upgraded successfully." ;;
    2) ;; # nothing to do
    *)
      notify "Upgrade Failed" "Failed to upgrade $browser."
      echo "Error: upgrade of '$browser' failed" >&2
      exit 1
      ;;
    esac
  fi

  exec "$LAUNCHER_SCRIPT" "$browser" "$@"
}

main "$@"
