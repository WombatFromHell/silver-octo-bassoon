#!/usr/bin/env bash
# Shared Steam teardown. Sourced by beryl-steam.sh, restart-steam.sh and
# steamos-session-select.sh so all three stop a running client the same way.
# Callers must define log_info and log_error before calling these functions.
# STEAM_SHUTDOWN_TIMEOUT is overridable: it is how long a hung client is given
# to exit on its own before being killed.
STEAM_SHUTDOWN_TIMEOUT="${STEAM_SHUTDOWN_TIMEOUT:-10}"

is_steam_running() {
  pgrep -x steam >/dev/null 2>&1
}

# Wait for a running client to exit. Nudge it once with SIGINT after 3s (Steam
# often ignores the first teardown request), then escalate to SIGKILL past the
# timeout. Returns 0 in every case: the caller's intent is "Steam is gone",
# which holds whether it exited, was signalled, or was killed.
wait_for_steam_exit() {
  local elapsed=0
  local nudged=0
  while is_steam_running; do
    if ((elapsed >= STEAM_SHUTDOWN_TIMEOUT)); then
      log_error "Steam unresponsive — force-closing after ${STEAM_SHUTDOWN_TIMEOUT}s"
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    if ((elapsed >= 3 && !nudged)); then
      pkill --signal INT -x steam 2>/dev/null || true
      nudged=1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

shutdown_steam_if_running() {
  is_steam_running || return 0
  log_info "Shutting down Steam..."
  steam -shutdown || true
  wait_for_steam_exit
}
