#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS="$HOME/.local/bin/scripts"
LOCK_FILE="${XDG_RUNTIME_DIR:-}/bazzite-steam-bpm.lock"

STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -bigpicture
)
NSCB_PATH="$(command -v nscb 2>/dev/null)" || true
GAMESCOPE_ARGS=(
  -p std
  -e
  --
)

LOCAL_STEAM_ENV_VARS=(
)

WRAPPERS=(
  "gamemode --"
)

# ── Logging ──────────────────────────────────────────────────────────────────

log_info() { echo "[bazzite-steam-bpm] $*" >&2; }
log_warn() { echo "[bazzite-steam-bpm] WARN: $*" >&2; }
log_error() { echo "[bazzite-steam-bpm] ERROR: $*" >&2; }

# ── Process Helpers ──────────────────────────────────────────────────────────

is_steam_running() {
  pgrep -x steam >/dev/null 2>&1
}

is_gamescope_steam_running() {
  # Check if gamescope is wrapping our Steam session
  pgrep -a gamescope 2>/dev/null | grep -qF "$STEAM"
}

# ── Dependency Checks ────────────────────────────────────────────────────────

check_dependencies() {
  local missing=()

  [[ -z ${XDG_RUNTIME_DIR:-} ]] && missing+=("XDG_RUNTIME_DIR (not set)")
  [[ -z $NSCB_PATH ]] && missing+=("nscb")

  for dep in niri jq; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done

  # fuser is preferred but not fatal — we have a fallback
  command -v fuser &>/dev/null || log_warn "fuser not found; orphan cleanup will use fallback"

  if ((${#missing[@]})); then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ── State ────────────────────────────────────────────────────────────────────

# Track the child PID so we can forward signals and clean up on interrupt.
STEAM_CHILD_PID=0

forward_signal() {
  local sig="$1"
  local exit_code=$((128 + sig))

  if ((STEAM_CHILD_PID > 0)); then
    kill -"$sig" "$STEAM_CHILD_PID" 2>/dev/null || true
  fi

  shutdown_steam_if_running
  exit "$exit_code"
}

setup_signal_handlers() {
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local timeout=10
  local elapsed=0

  while pgrep -xc steam >/dev/null 2>&1; do
    if ((elapsed >= timeout)); then
      notify-send "Steam unresponsive" "Force-closing Steam after ${timeout}s timeout" 2>/dev/null || true
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    # After 3s, nudge with SIGINT before escalating to SIGKILL
    ((elapsed >= 3)) && pkill --signal INT -x steam 2>/dev/null || true

    sleep 1
    elapsed=$((elapsed + 1))
  done
}

shutdown_steam_if_running() {
  if is_steam_running; then
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ── Niri Window Focus ────────────────────────────────────────────────────────

# Find a window ID by app_id, with optional title filter.
# Returns the first matching window ID or empty string.
find_window_id() {
  local app_id="$1"
  local title="${2:-}"

  local query='.[] | select(.app_id == "'"$app_id"'") | .id'
  [[ -n $title ]] && query='.[] | select(.app_id == "'"$app_id"'" and .title == "'"$title"'") | .id'

  niri msg -j windows 2>/dev/null | jq -r "$query" 2>/dev/null | head -n1
}

focus_steam_bpm_window() {
  local window_id

  # Try Gamescope-wrapped first, then bare Steam (both share the same title)
  window_id=$(find_window_id "gamescope" "Steam Big Picture Mode") || true
  [[ -z $window_id ]] && window_id=$(find_window_id "steam" "Steam Big Picture Mode") || true

  if [[ -n $window_id ]]; then
    niri msg action focus-window --id "$window_id" 2>/dev/null
    return 0
  fi

  return 1
}

# ── Session Cleanup ──────────────────────────────────────────────────────────

# Kill everything holding the orphaned session's lock
cleanup_orphaned_session() {
  log_warn "Orphaned Gamescope session detected (Steam not running). Cleaning up..."

  # Prefer fuser — single syscall, no tree-walking needed
  if command -v fuser &>/dev/null; then
    fuser -k -9 "$LOCK_FILE" 2>/dev/null || true
  else
    # Fallback: kill only the specific gamescope processes wrapping our Steam
    log_warn "Using pkill fallback (fuser not available)"
    local pattern
    pattern="gamescope.*$(basename "$STEAM")"
    pkill --signal 9 -f "$pattern" 2>/dev/null || true
  fi

  # Sweep leaf processes that may have outlived the parent kill
  if is_steam_running; then
    pkill --signal 9 -x steam 2>/dev/null || true
  fi

  # Poll until lock is free
  for ((i = 0; i < 10; i++)); do
    close_lock_fd
    open_lock_fd
    if try_lock; then
      log_info "Lock reclaimed successfully"
      return 0
    fi
    sleep 1
  done

  log_error "Failed to reclaim lock after 10s — run: fuser -k '$LOCK_FILE'"
  return 1
}

# ── Command Building ─────────────────────────────────────────────────────────

# Populates STEAM_CMD array with the full command chain.
# WRAPPERS is extensible — end-users can add pre-launch hooks here.
build_steam_command() {
  # Environment variables
  STEAM_CMD=(env "${LOCAL_STEAM_ENV_VARS[@]}")

  # Pre-launch wrappers (extensible extension point)
  for wrapper_str in "${WRAPPERS[@]}"; do
    read -ra wrapper <<<"$wrapper_str"
    local wrapper_bin="${wrapper[0]:-}"
    local wrapper_args=("${wrapper[@]:1}")

    command -v "$wrapper_bin" &>/dev/null || continue
    STEAM_CMD+=("$wrapper_bin" "${wrapper_args[@]}")
    log_info "Wrapper: $wrapper_bin ${wrapper_args[*]:-}"
  done

  # Gamescope/nscb wrapper (if configured)
  if [[ -n $NSCB_PATH ]]; then
    STEAM_CMD+=("$NSCB_PATH" "${GAMESCOPE_ARGS[@]}")
  fi

  # Steam binary + args
  STEAM_CMD+=("${STEAM}" "${STEAM_ARGS[@]}")
}

# ── Session Launch ───────────────────────────────────────────────────────────

launch_steam_bpm() {
  build_steam_command

  # Launch Steam in background, then focus the BPM window once it appears
  "${STEAM_CMD[@]}" &
  STEAM_CHILD_PID=$!

  local timeout=30
  local elapsed=0
  while ((elapsed < timeout)); do
    if focus_steam_bpm_window 2>/dev/null; then
      log_info "Focused Steam BPM window"
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if ((elapsed >= timeout)); then
    log_warn "Timed out waiting for Steam BPM window — Steam may still be starting"
  fi

  # Wait for the Steam/gamescope process to exit
  wait "$STEAM_CHILD_PID"
  STEAM_CHILD_PID=0
}

# ── Lock Management ──────────────────────────────────────────────────────────

open_lock_fd() { exec 200>"$LOCK_FILE"; }
close_lock_fd() { exec 200>&-; }
try_lock() { flock -n 200; }
wait_lock() {
  local timeout="$1"
  flock -w "$timeout" 200
}

acquire_lock() {
  open_lock_fd

  # Fast path: lock acquired immediately
  if try_lock; then
    return 0
  fi

  # Lock is held — diagnose the situation

  # Healthy session already active — focus and exit
  if is_gamescope_steam_running && is_steam_running; then
    log_info "Gamescope Steam session already active — focusing window"
    focus_steam_bpm_window || true
    exit 0
  fi

  # Steam dead — orphaned session, reclaim the lock
  if ! is_steam_running; then
    cleanup_orphaned_session || return 1
    try_lock && return 0
    log_error "Failed to acquire lock after cleanup"
    return 1
  fi

  # Lock held by unrelated process — wait with timeout
  log_info "Lock held by unrelated process — waiting (15s timeout)..."
  wait_lock 15 && return 0

  log_error "Could not acquire lock after 15s"
  return 1
}

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  check_dependencies
  setup_signal_handlers

  # If Steam is already running, shut it down before launching a new session
  shutdown_steam_if_running

  # Prevent concurrent executions (hold lock until session ends)
  acquire_lock

  launch_steam_bpm
}

main "${@}"
