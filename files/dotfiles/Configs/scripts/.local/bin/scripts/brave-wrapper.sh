#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# ZONE 1: CONFIGURATION
# ==============================================================================
readonly CONTAINER_NAME="bravebox"
if [ -f "$HOME/.local/bin/scripts/chromium-flags.sh" ]; then
  CHROMIUM_FLAGS_SCRIPT="$HOME/.local/bin/scripts/chromium-flags.sh"
else
  CHROMIUM_FLAGS_SCRIPT="$(command -v chromium-flags.sh)"
fi
readonly CHROMIUM_FLAGS_SCRIPT
# Fail fast at startup instead of every launch branch guessing why exec broke.
[[ -x "$CHROMIUM_FLAGS_SCRIPT" ]] || {
  echo "Error: chromium-flags.sh not found" >&2
  exit 1
}

readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)
readonly FLATPAK_ID="com.brave.Browser"

# Deferred-update tuning: gap between "update found" and actually applying it,
# so the mutating dnf/flatpak upgrade doesn't race the browser's own startup.
# ponytail: fixed grace period, not PID/readiness polling — dnf's own
# resolve+download time dwarfs browser startup, so a flat sleep is enough.
# If browser startup ever regularly exceeds this, poll `kill -0 $browser_pid`
# instead of guessing a bigger number.
readonly UPDATE_DEFER_SECONDS="${UPDATE_DEFER_SECONDS:-10}"

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

  # Priority 3: Inside the distrobox container
  # ponytail: only checks brave-browser — the only pkg install-brave.sh installs
  if command -v distrobox-enter &>/dev/null &&
    distrobox-enter -n "$CONTAINER_NAME" -- bash -c 'command -v brave-browser' &>/dev/null; then
    echo "brave-browser"
    return 0
  fi

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
  local cmd="$1"
  shift
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd command not found" >&2
    return 1
  fi
  "$@"
}

# --- Phase 1: Check (read-only, no sudo — safe to run immediately) ---

_check_update_flatpak() {
  local target="$1" probe_out
  probe_out=$(flatpak update --no-deploy -y "${target}" 2>&1) || true
  [[ "$probe_out" != *"Nothing to do"* ]]
}

_check_update_dnf() {
  dnf check-update "$1" &>/dev/null
  [[ $? -eq 100 ]] # 100 = updates available; 0 = none; anything else = error
}

_check_update_distrobox() {
  distrobox-enter -n "$CONTAINER_NAME" -- dnf check-update "$1" &>/dev/null
  [[ $? -eq 100 ]]
}

_check_for_update() {
  case "$1" in
  flatpak) _check_update_flatpak "$2" ;;
  dnf | direct) _check_update_dnf "$2" ;;
  distrobox) _check_update_distrobox "$2" ;;
  *)
    echo "Unknown update strategy: $1" >&2
    return 2
    ;;
  esac
}

# --- Phase 2: Apply (mutating — only runs after the defer window) ---

_apply_update_flatpak() {
  local target="$1" out rc=0
  out=$(flatpak update -y "${target}" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]] && [[ "$out" == *"Updates complete"* ]]; then
    echo "$out"
    notify "Brave Updated" "Restart the browser to finish updating."
    return 0
  fi
  echo "Flatpak update failed." >&2
  notify "Update Failed" "Failed to update Brave." "critical"
  return "$rc"
}

_apply_update_dnf() {
  local target="$1" out rc=0
  if ! sudo -n true &>/dev/null; then
    echo "Skipping update: passwordless sudo not configured." >&2
    return 0
  fi
  out=$(sudo dnf upgrade -y "$target" 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    notify "Update Available" "${target} was upgraded. Restart the browser to apply updates."
    return 0
  fi
  echo "$out" >&2
  notify "Upgrade Failed" "Failed to upgrade ${target}." "critical"
  return "$rc"
}

_apply_update_distrobox() {
  local target="$1" out rc=0
  # ponytail: applying here can still race a browser instance launched from
  # the same container; safe only because dnf/rpm renames into place and a
  # running inode stays valid. If brave's package ever isn't atomic-swap-safe,
  # this needs to wait on the launched browser's pid instead.
  if ! distrobox-enter -n "$CONTAINER_NAME" -- sudo -n true &>/dev/null; then
    echo "Skipping update: passwordless sudo not configured in ${CONTAINER_NAME}." >&2
    return 0
  fi
  out=$(distrobox-enter -n "$CONTAINER_NAME" -- sudo dnf upgrade -y "$target" </dev/null 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    notify "Update Available" "${target} was upgraded. Restart the browser to apply updates."
    return 0
  fi
  echo "$out" >&2
  notify "Upgrade Failed" "Failed to upgrade ${target}." "critical"
  return "$rc"
}

_apply_update() {
  case "$1" in
  flatpak) _apply_update_flatpak "$2" ;;
  dnf | direct) _apply_update_dnf "$2" ;;
  distrobox) _apply_update_distrobox "$2" ;;
  *)
    echo "Unknown update strategy: $1" >&2
    return 2
    ;;
  esac
}

# --- Unified Update Interface (The Context) ---
perform_browser_update() {
  local strategy="${1}" # 'flatpak', 'dnf'/'direct', or 'distrobox'
  local target="${2}"   # The ID or Binary name

  echo "Checking for ${target} updates (${strategy})..."
  if ! _check_for_update "$strategy" "$target"; then
    echo "No updates found."
    return 0
  fi

  echo "Update available — deferring install until the browser is up."
  sleep "$UPDATE_DEFER_SECONDS"
  _apply_update "$strategy" "$target"
}

execute_launch() {
  local method="$1" browser="$2"
  shift 2
  case "$method" in
  flatpak)
    run_command_or_fail flatpak "$CHROMIUM_FLAGS_SCRIPT" flatpak run "${FLATPAK_ID}" "$@"
    ;;
  distrobox)
    run_command_or_fail distrobox-enter "$CHROMIUM_FLAGS_SCRIPT" \
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
  # Container install: route background updates into the container, not host dnf
  [[ "$launch_method" == "distrobox" ]] && pkg_method="distrobox"

  # 3. Execution — fork the (now check-then-deferred-apply) updater, then
  # launch the browser immediately. The updater's own sleep does the waiting,
  # so this fork/exec ordering no longer needs to race anything.
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
