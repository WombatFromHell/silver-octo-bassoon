#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

STEAM_SHUTDOWN_TIMEOUT="${STEAM_SHUTDOWN_TIMEOUT:-10}"

# ── Logging ──────────────────────────────────────────────────────────────────

log_info() { echo "[restart-steam] $*" >&2; }
log_error() { echo "[restart-steam] ERROR: $*" >&2; }

# ── Process Helpers ──────────────────────────────────────────────────────────

is_steam_running() {
  pgrep -x steam >/dev/null 2>&1
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local elapsed=0

  while pgrep -xc steam >/dev/null 2>&1; do
    if ((elapsed >= STEAM_SHUTDOWN_TIMEOUT)); then
      log_error "Steam unresponsive — force-closing after ${STEAM_SHUTDOWN_TIMEOUT}s"
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
    log_info "Shutting down Steam..."
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

shutdown_steam_if_running

if (($# > 0)); then
  exec "$@"
fi
