#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="bravebox"
readonly CHROMIUM_FLAGS_SCRIPT="${HOME}/.local/bin/scripts/chromium-flags.sh"
readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)
readonly FLATPAK_ID="com.brave.Browser"

_in_container_check() {
  [[ -n "${CONTAINER_ID:-}" ]] || [[ -f /run/.containerenv ]] || [[ -f /.dockerenv ]] || grep -q container /proc/1/cgroup 2>/dev/null
}

find_browser() {
  for b in "${BROWSER_CANDIDATES[@]}"; do
    command -v "$b" &>/dev/null && printf '%s' "$b" && return
  done
  if command -v flatpak &>/dev/null && flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}"; then
    printf '%s' "flatpak"
    return
  fi
  return 1
}

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  [[ -z "$title" || -z "$body" ]] && return 0
  command -v notify-send &>/dev/null && notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

run_or_fail() {
  local cmd="$1" msg="Error: $2 command not found"
  shift 2
  command -v "$cmd" &>/dev/null || {
    echo "$msg" >&2
    return 1
  }
  "$@"
}

flatpak_update_check() {
  command -v flatpak &>/dev/null || return 0
  flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}" || return 0
  local out rc=0
  echo "Checking for flatpak updates for ${FLATPAK_ID}..."
  out=$(flatpak update --no-deploy -y "${FLATPAK_ID}" 2>&1) || rc=$?
  if grep -q "Nothing to do." <<<"$out"; then
    echo "No flatpak updates for ${FLATPAK_ID}."
  else
    out=$(flatpak update -y "${FLATPAK_ID}" 2>&1) || rc=$?
    if grep -q "Updates complete." <<<"$out"; then
      notify "Brave Updated" "Restart the browser to finish updating."
    fi
  fi
}

background_update() {
  local method="$1" browser="$2"
  case "$method" in
  flatpak)
    flatpak_update_check
    ;;
  direct)
    command -v "$browser" &>/dev/null || return 0
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
    ;;
  distrobox)
    echo "Skipping dnf update check for distrobox (browser runs in container)"
    ;;
  esac
}

launcher() {
  local method="$1" browser="$2"
  shift 2
  case "$method" in
  flatpak)
    run_or_fail flatpak exec "$CHROMIUM_FLAGS_SCRIPT" flatpak run "${FLATPAK_ID}" "$@"
    ;;
  distrobox)
    run_or_fail distrobox-enter exec "$CHROMIUM_FLAGS_SCRIPT" distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@"
    ;;
  direct)
    exec "$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@"
    ;;
  esac
}

_launcher_for() {
  local flatpak_installed="$1"
  local in_container="$2"
  if [[ "$flatpak_installed" == "yes" ]]; then
    printf '%s\n' "flatpak"
  elif [[ "$in_container" == "no" ]]; then
    printf '%s\n' "distrobox"
  else
    printf '%s\n' "direct"
  fi
}

_dispatch() {
  local cmd="$1"
  shift
  case "$cmd" in
  in-container)
    _in_container_check
    ;;
  find-browser)
    find_browser
    ;;
  flatpak-installed)
    command -v flatpak &>/dev/null && flatpak info "${FLATPAK_ID}" &>/dev/null
    ;;
  notify)
    notify "${1:-}" "${2:-}" "${3:-}" "${4:-}"
    ;;
  launch-flatpak)
    launcher flatpak brave "$@"
    ;;
  launch-distrobox)
    local browser="${1:-brave}"
    launcher distrobox "$browser" "${@:2}"
    ;;
  launch-direct)
    launcher direct "${1:-brave}" "${@:2}"
    ;;
  bg-update)
    background_update "${1:-direct}" "${2:-brave}"
    ;;
  flatpak-update-check)
    flatpak_update_check
    ;;
  *)
    echo "Unknown helper: $cmd" >&2
    exit 1
    ;;
  esac
}

main() {
  local mode="${1:-}"
  if [[ "$mode" == --helper-* ]]; then
    _dispatch "${mode#--helper-}" "${@:2}"
    return
  fi

  local flatpak_installed in_container
  if command -v flatpak &>/dev/null && flatpak info "${FLATPAK_ID}" &>/dev/null; then
    flatpak_installed="yes"
  elif command -v flatpak &>/dev/null && flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}"; then
    flatpak_installed="yes"
  else
    flatpak_installed="no"
  fi

  if _in_container_check; then
    in_container="yes"
  else
    in_container="no"
  fi

  local browser
  browser=$(find_browser) || {
    echo "Error: no brave browser found in PATH or flatpak (tried: ${BROWSER_CANDIDATES[*]}, ${FLATPAK_ID})" >&2
    exit 1
  }

  if [[ "$browser" == "flatpak" ]]; then
    flatpak_installed="yes"
  fi

  local launch_method
  launch_method=$(_launcher_for "$flatpak_installed" "$in_container")

  if [[ "$launch_method" != "direct" ]]; then
    background_update "$launch_method" "$browser" </dev/null &
    disown
  fi

  launcher "$launch_method" "$browser" "$@"
}

main "$@"
