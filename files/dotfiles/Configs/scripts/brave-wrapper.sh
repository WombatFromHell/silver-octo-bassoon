#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# ZONE 1: CONFIGURATION
# ==============================================================================
readonly CONTAINER_NAME="bravebox"
readonly CHROMIUM_FLAGS_SCRIPT="${HOME}/.local/bin/scripts/chromium-flags.sh"
readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)
readonly FLATPAK_ID="com.brave.Browser"

# Dependency Injection for Testing
CONTAINER_ENV_FILE="${CONTAINER_ENV_FILE:-/run/.containerenv}"
DOCKER_ENV_FILE="${DOCKER_ENV_FILE:-/.dockerenv}"
PROC_CGROUP_PATH="${PROC_CGROUP_PATH:-/proc/1/cgroup}"

# ==============================================================================
# ZONE 2: LOGIC (Pure Decision Making)
# ==============================================================================

is_in_container() {
  [[ -n "${CONTAINER_ID:-}" ]] ||
    [[ -f "$CONTAINER_ENV_FILE" ]] ||
    [[ -f "$DOCKER_ENV_FILE" ]] ||
    grep -q container "$PROC_CGROUP_PATH" 2>/dev/null ||
    return 1
}

find_browser() {
  # Priority 1: Flatpak
  if command -v flatpak &>/dev/null &&
    flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}"; then
    echo "flatpak"
    return 0
  fi

  # Priority 2: Binaries in PATH
  for b in "${BROWSER_CANDIDATES[@]}"; do
    if command -v "$b" &>/dev/null; then
      echo "$b"
      return 0
    fi
  done

  return 1
}

detect_package_manager() {
  if command -v flatpak &>/dev/null && is_flatpak_installed; then
    printf 'flatpak'
  elif command -v dnf &>/dev/null; then
    printf 'dnf'
  else
    printf 'unknown'
  fi
}

is_flatpak_installed() {
  command -v flatpak &>/dev/null &&
    (flatpak info "${FLATPAK_ID}" &>/dev/null || flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}")
}

determine_launch_method() {
  local flatpak_installed="${1:-false}"
  local in_container="${2:-false}"

  if [[ "$flatpak_installed" == "true" ]]; then
    printf 'flatpak'
  elif [[ "$in_container" == "false" ]]; then
    printf 'distrobox'
  else
    printf 'direct'
  fi
}

# ==============================================================================
# ZONE 3: ACTIONS (Strategy Pattern & Execution)
# ==============================================================================

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  [[ -z "$title" || -z "$body" ]] && return 0
  if command -v notify-send &>/dev/null; then
    notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
  fi
}

run_command_or_fail() {
  local cmd="$1" msg="Error: $2 command not found"
  shift 2
  if ! command -v "$cmd" &>/dev/null; then
    echo "$msg" >&2
    return 1
  fi
  "$@"
}

# --- Update Strategy: Flatpak ---
_update_strategy_flatpak() {
  local target="$1"
  echo "Checking for flatpak updates for ${target}..."

  local probe_out
  probe_out=$(flatpak update --no-deploy -y "${target}" 2>&1) || true

  if [[ "$probe_out" == *"Nothing to do"* ]]; then
    echo "No flatpak updates found."
    return 0
  fi

  echo "Updates found! Applying..."
  local out rc=0
  out=$(flatpak update -y "${target}" 2>&1) || rc=$?

  if [[ $rc -eq 0 ]] && [[ "$out" == *"Updates complete"* ]]; then
    echo "$out" # <--- ADDED: This allows BATS/users to see the success message
    notify "Brave Updated" "Restart the browser to finish updating."
    return 0
  fi
  echo "Flatpak update failed." >&2
  return "$rc"
}

# --- Update Strategy: DNF (Direct) ---
_update_strategy_dnf() {
  local target="$1"
  echo "Checking for ${target} updates via dnf..."

  local rc=0
  # We use &>/dev/null because we are relying purely on the exit code 100
  sudo dnf check-update "$target" &>/dev/null || rc=$?

  # DNF exit code 100 means updates are available
  if [[ $rc -eq 0 ]]; then
    echo "No updates found."
    return 0
  elif [[ $rc -ne 100 ]]; then
    notify "Upgrade Failed" "Failed to check for ${target} updates." "critical"
    return "$rc"
  fi

  echo "Updates found! Upgrading..."
  local out actual_rc=0
  out=$(sudo dnf upgrade -y "$target" 2>&1) || actual_rc=$?

  if [[ $actual_rc -eq 0 ]]; then
    notify "Update Available" "${target} was upgraded. Restart the browser to apply updates."
    return 0
  fi
  notify "Upgrade Failed" "Failed to upgrade ${target}." "critical"
  return "$actual_rc"
}

# --- Unified Update Interface (The Context) ---
perform_browser_update() {
  local strategy="${1}" # 'flatpak' or 'dnf'
  local target="${2}"   # The ID or Binary name

  case "$strategy" in
  flatpak) _update_strategy_flatpak "$target" ;;
  dnf | direct) _update_strategy_dnf "$target" ;;
  *)
    echo "Unknown update strategy: $strategy" >&2
    return 1
    ;;
  esac
}

execute_launch() {
  local method="$1" browser="$2"
  shift 2
  case "$method" in
  flatpak)
    run_command_or_fail flatpak exec "$CHROMIUM_FLAGS_SCRIPT" flatpak run "${FLATPAK_ID}" "$@"
    ;;
  distrobox)
    run_command_or_fail distrobox-enter exec "$CHROMIUM_FLAGS_SCRIPT" \
      distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@"
    ;;
  direct)
    exec "$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@"
    ;;
  esac
}

# ==============================================================================
# ZONE 4: ORCHESTRATION (CLI & Main)
# ==============================================================================

_dispatch() {
  local cmd="$1"
  shift
  case "$cmd" in
  in-container) is_in_container ;;
  find-browser) find_browser ;;
  flatpak-installed) is_flatpak_installed && return 0 || return 1 ;;
  notify) notify "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  launch-flatpak) execute_launch "flatpak" "brave" "$@" ;;
  launch-distrobox) execute_launch "distrobox" "${1:-brave}" "${@:2}" ;;
  launch-direct) execute_launch "direct" "${1:-brave}" "${@:2}" ;;
  bg-update) perform_browser_update "${1:-direct}" "${2:-brave}" ;;
  flatpak-update-check) perform_browser_update "flatpak" "$FLATPAK_ID" ;;
  *)
    echo "Unknown helper: $cmd" >&2
    exit 1
    ;;
  esac
}

main() {
  # 1. Detection
  local flatpak_status="false"
  is_flatpak_installed && flatpak_status="true"
  local container_status="false"
  is_in_container && container_status="true"
  local pkg_method
  pkg_method=$(detect_package_manager)

  local browser
  browser=$(find_browser) || {
    echo "Error: no brave found." >&2
    exit 1
  }

  # 2. Decision logic for updates
  local update_target="$browser"
  [[ "$pkg_method" == "flatpak" ]] && update_target="$FLATPAK_ID"

  local launch_method
  launch_method=$(determine_launch_method "$flatpak_status" "$container_status")

  # 3. Execution (Background Update if not running 'direct')
  if [[ "$launch_method" != "direct" ]]; then
    perform_browser_update "$pkg_method" "$update_target" </dev/null &
    disown || true
  fi

  execute_launch "$launch_method" "$browser" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == --helper-* ]]; then
    _dispatch "${1#--helper-}" "${@:2}"
  else
    main "$@"
  fi
fi
