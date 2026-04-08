#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS="$HOME/.local/bin/scripts"
LOCK_FILE="${XDG_RUNTIME_DIR}/bazzite-steam-bpm.lock"

STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -steamos3
  -tenfoot
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.pyz"
GAMESCOPE_ARGS=(
  -p std
  -p vsr4k
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

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  check_shutdown_flag "${@}"

  # Prevent concurrent executions (hold lock until session ends)
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    if pgrep -a gamescope 2>/dev/null | grep -q "$STEAM" 2>/dev/null; then
      echo "Gamescope Steam session already active" >&2
      exit 0
    fi
    flock 200
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

  exec "${cmd[@]}"
}

main "${@}"
