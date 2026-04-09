#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS="$HOME/.local/bin/scripts"
LOCK_FILE="${XDG_RUNTIME_DIR}/bazzite-steam-bpm.lock"

STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -gamepadui
  -steamos3
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.pyz"
GAMESCOPE_ARGS=(
  -p std
  -p vsr4k
  --expose-wayland
  --mangoapp
  -e
  --
)

LOCAL_STEAM_ENV_VARS=(
  "PROTON_ENABLE_WAYLAND=1"
)

HOOKS=(
  "$SCRIPTS/gamemode.py --"
)

# ── Shutdown Hook Interceptor ────────────────────────────────────────────────

check_shutdown_flag() {
  for arg in "$@"; do
    if [[ "$arg" == "-shutdown" ]]; then
      local hook
      hook="$(command -v steamos-session-select 2>/dev/null)" || true
      if [[ -n "$hook" ]]; then
        exec "$hook" "$@"
      fi
      shutdown_steam_if_running
      exit 0
    fi
  done
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local timeout=15
  local elapsed=0
  while pgrep -xc steam >/dev/null 2>&1; do
    if ((elapsed >= timeout)); then
      notify-send "Steam unresponsive" "Force-closing Steam after ${timeout}s timeout" 2>/dev/null || true
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    sleep 1
    ((elapsed++))
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
  window_id=$(
    niri msg -j windows 2>/dev/null | jq -r '
      .[]
      | select(.app_id == "gamescope" and .title == "Steam Big Picture Mode")
      | .id
    ' 2>/dev/null | head -n1
  ) || return 1

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
    # Fallback: kill the gamescope + its entire ancestor chain
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      while [[ "$pid" -gt 1 ]]; do
        kill -9 "$pid" 2>/dev/null || break
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null) || break
      done
    done < <(pgrep -f "gamescope.*${STEAM}" 2>/dev/null || true)
  fi

  # Sweep leaf processes that may have outlived the parent kill
  pkill --signal 9 -f "gamescope.*${STEAM}" 2>/dev/null || true
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

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  check_shutdown_flag "${@}"

  # Prevent concurrent executions (hold lock until session ends)
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
      # Lock held by unrelated process — wait for it
      flock 200
    fi
  fi

  shutdown_steam_if_running

  # Build the command chain inline
  local cmd=(env "${LOCAL_STEAM_ENV_VARS[@]}")
  for hook_str in "${HOOKS[@]}"; do
    read -ra hook <<<"$hook_str"
    if [[ -x "${hook[0]:-}" ]]; then
      cmd+=("${hook[@]}")
      echo "Hook: ${hook[0]}" >&2
    else
      echo "Skipping missing/unexecutable hook: ${hook[0]:-$hook_str}" >&2
    fi
  done
  cmd+=("${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}" "${STEAM}" "${STEAM_ARGS[@]}")

  # Launch Steam in background, then focus the BPM window once it appears
  "${cmd[@]}" &
  local steam_pid=$!

  local timeout=30
  local elapsed=0
  while ((elapsed < timeout)); do
    if focus_steam_bpm_window 2>/dev/null; then
      echo "Focused Steam BPM window" >&2
      break
    fi
    sleep 1
    ((elapsed++))
  done

  if ((elapsed >= timeout)); then
    echo "Timed out waiting for Steam BPM window — Steam may still be starting" >&2
  fi

  # Wait for the Steam/gamescope process to exit
  wait "$steam_pid"
}

main "${@}"
