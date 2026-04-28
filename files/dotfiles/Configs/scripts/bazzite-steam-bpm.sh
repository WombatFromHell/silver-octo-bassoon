#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS="$HOME/.local/bin/scripts"
LOCK_FILE="${XDG_RUNTIME_DIR:-}/bazzite-steam-bpm.lock"

STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -gamepadui
  -steamos3
)
GAMESCOPE_WRAPPER="$(which nscb 2>/dev/null)" || true
GAMESCOPE_ARGS=(
  -p std
  --mangoapp
  -e
  --
)

LOCAL_STEAM_ENV_VARS=(
  "PROTON_ENABLE_WAYLAND=1"
  MANGOHUD_CONFIG="read_cfg"
  MANGOHUD_CONFIGFILE="$HOME/.config/MangoHud/MangoHud.conf"
)

HOOKS=(
  "gamemode --"
)

# ── Dependency Checks ────────────────────────────────────────────────────────

check_dependencies() {
  local missing=()

  [[ -z "${XDG_RUNTIME_DIR:-}" ]] && missing+=("XDG_RUNTIME_DIR (not set)")
  [[ -z "$GAMESCOPE_WRAPPER" ]] && missing+=("nscb")

  for dep in niri jq; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done

  # fuser is preferred but not fatal — we have a fallback
  command -v fuser &>/dev/null || echo "Warning: fuser not found; orphan cleanup will use fallback" >&2

  if ((${#missing[@]})); then
    echo "Error: Missing dependencies: ${missing[*]}" >&2
    exit 1
  fi
}

# ── Signal Handling ──────────────────────────────────────────────────────────

# Track the child PID so we can forward signals and clean up on interrupt.
STEAM_CHILD_PID=0

forward_signal() {
  local sig="$1"
  if ((STEAM_CHILD_PID > 0)); then
    kill -"$sig" "$STEAM_CHILD_PID" 2>/dev/null || true
  fi
  shutdown_steam_if_running
  exit 1
}

setup_signal_handlers() {
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
}

# ── Shutdown Hook Interceptor ────────────────────────────────────────────────

# Handles the `-shutdown` flag from steamos-session-switch.
# If steamos-session-select is available, execs into it.
# Otherwise shuts down Steam and falls through to relaunch (BPM restart cycle).
handle_shutdown_request() {
  for arg in "$@"; do
    if [[ "$arg" == "-shutdown" ]]; then
      local hook
      hook="$(command -v steamos-session-select 2>/dev/null)" || true
      if [[ -n "$hook" ]]; then
        # Pass only -shutdown to steamos-session-select, not unrelated args
        exec "$hook" -shutdown
      fi
      shutdown_steam_if_running
      exit 0
    fi
  done
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local timeout=10
  local elapsed=0
  local signaled=0

  while pgrep -xc steam >/dev/null 2>&1; do
    if ((elapsed >= timeout)); then
      notify-send "Steam unresponsive" "Force-closing Steam after ${timeout}s timeout" 2>/dev/null || true
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi

    # After 3s, send SIGINT for graceful shutdown before escalating to SIGKILL
    if ((elapsed >= 3 && signaled == 0)); then
      pkill --signal INT -x steam 2>/dev/null || true
      signaled=1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done
}

shutdown_steam_if_running() {
  if pgrep -x steam >/dev/null 2>&1; then
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ── Niri Window Focus ────────────────────────────────────────────────────────

focus_steam_bpm_window() {
  local window_id

  # Try exact title match first
  window_id=$(
    niri msg -j windows 2>/dev/null | jq -r '
      .[]
      | select(.app_id == "gamescope" and .title == "Steam Big Picture Mode")
      | .id
    ' 2>/dev/null | head -n1
  ) || true

  # Fallback: match on app_id alone (title may differ by locale/version)
  if [[ -z "$window_id" ]]; then
    window_id=$(
      niri msg -j windows 2>/dev/null | jq -r '
        .[]
        | select(.app_id == "gamescope")
        | .id
      ' 2>/dev/null | head -n1
    ) || true
  fi

  if [[ -n "$window_id" ]]; then
    niri msg action focus-window --id "$window_id" 2>/dev/null
    return $?
  fi

  return 1
}

# ── Session Cleanup ──────────────────────────────────────────────────────────

# Kill everything holding the orphaned session's lock
cleanup_orphaned_session() {
  echo "Orphaned Gamescope session detected (Steam not running). Cleaning up..." >&2

  # Prefer fuser — single syscall, no tree-walking needed
  if command -v fuser &>/dev/null; then
    fuser -k -9 "$LOCK_FILE" 2>/dev/null || true
  else
    # Fallback: kill only the specific gamescope processes wrapping our Steam
    # Use SIGINT first for graceful shutdown, then SIGKILL
    pkill --signal INT -f "gamescope.*${STEAM}" 2>/dev/null || true
    sleep 1
    pkill --signal 9 -f "gamescope.*${STEAM}" 2>/dev/null || true
  fi

  # Sweep leaf processes that may have outlived the parent kill
  pkill --signal 9 -x steam 2>/dev/null || true

  # Poll until lock is free
  for ((i = 0; i < 10; i++)); do
    exec 200>&-
    exec 200>"$LOCK_FILE"
    flock -n 200 && return 0
    sleep 1
  done

  echo "Failed to reclaim lock after 10s — run: fuser -k '$LOCK_FILE'" >&2
  return 1
}

# ── Command Building ─────────────────────────────────────────────────────────

# Populates STEAM_CMD array with the full command chain.
build_steam_command() {
  STEAM_CMD=(env "${LOCAL_STEAM_ENV_VARS[@]}")
  for hook_str in "${HOOKS[@]}"; do
    read -ra hook <<<"$hook_str"
    if [[ -x "${hook[0]:-}" ]]; then
      STEAM_CMD+=("${hook[@]}")
      echo "Hook: ${hook[0]}" >&2
    else
      echo "Skipping missing/unexecutable hook: ${hook[0]:-$hook_str}" >&2
    fi
  done
  STEAM_CMD+=("${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}" "${STEAM}" "${STEAM_ARGS[@]}")
}

# ── Session Launch ───────────────────────────────────────────────────────────

launch_steam_bpm() {
  local steam_cmd
  build_steam_command
  steam_cmd=("${STEAM_CMD[@]}")

  # Launch Steam in background, then focus the BPM window once it appears
  "${steam_cmd[@]}" &
  STEAM_CHILD_PID=$!

  local timeout=30
  local elapsed=0
  while ((elapsed < timeout)); do
    if focus_steam_bpm_window 2>/dev/null; then
      echo "Focused Steam BPM window" >&2
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if ((elapsed >= timeout)); then
    echo "Timed out waiting for Steam BPM window — Steam may still be starting" >&2
  fi

  # Wait for the Steam/gamescope process to exit
  wait "$STEAM_CHILD_PID"
  STEAM_CHILD_PID=0
}

# ── Lock Management ──────────────────────────────────────────────────────────

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    # Lock is held — check if this is a healthy session or orphaned
    if pgrep -a gamescope 2>/dev/null | grep -q "$STEAM" 2>/dev/null; then
      # Gamescope is running, but is Steam actually alive?
      if pgrep -x steam >/dev/null 2>&1; then
        echo "Gamescope Steam session already active — focusing window" >&2
        focus_steam_bpm_window || true
        exit 0
      else
        cleanup_orphaned_session || exit 1
      fi
    else
      # Lock held by unrelated process — wait up to 15s for it to release
      echo "Lock held by unrelated process — waiting (15s timeout)..." >&2
      if ! flock -w 15 200; then
        echo "Error: Could not acquire lock after 15s" >&2
        exit 1
      fi
    fi
  fi
}

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  check_dependencies
  setup_signal_handlers
  handle_shutdown_request "${@}"

  # Prevent concurrent executions (hold lock until session ends)
  acquire_lock

  shutdown_steam_if_running

  launch_steam_bpm
}

main "${@}"
