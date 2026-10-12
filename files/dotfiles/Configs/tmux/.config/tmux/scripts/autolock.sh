#!/usr/bin/env bash
# autolock.sh — auto-lock the C-s leader while a "locked" foreground proc
# (default: ssh, fzf) is running; auto-unlock when it exits. F12 is a manual
# override (toggle) that arms a directional override the poll honors.
#
# A small background daemon: `start` runs a poll loop at INTERVAL_MS; the
# pidfile makes it idempotent across config reloads / server restarts. A
# flock-based mutex serializes poll (daemon) and toggle (F12) so their
# read-modify-write of the lock state is atomic.
#
# Config (defaults live here; env vars override for testing / one-offs):
#   INTERVAL_MS   poll cadence in ms (default 1000 = 1 s)
#   LOCKED_PROCS  regex alternation of procs that trigger the lock
set -uo pipefail
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

INTERVAL_MS=${AUTOLOCK_INTERVAL_MS:-1000}
LOCKED_PROCS=${AUTOLOCK_PROCS:-'ssh|fzf'}

# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/autolock-lib.bash"

# --- tmux state accessors --------------------------------------------------
_is_locked() { # success (0) if the leader is currently locked (prefix None)
  [[ $(tmux show-options -gv prefix 2>/dev/null) == None ]]
}

_foreground() { # active pane's foreground procname (same source as the chip)
  tmux display -p '#{pane_current_command}' 2>/dev/null
}

_override() { # prints the manual override direction ("lock" | "unlock" | "")
  tmux show-options -gv @autolock_override 2>/dev/null
}

_arm_override() {
  local dir=$1
  tmux set -g @autolock_override "$dir"
}
_clear_override() { tmux set -gu @autolock_override; }

# with_lock CMD... -> run CMD... while holding the autolock mutex (flock),
# so F12 (toggle) and the daemon (poll) can't interleave their
# read-modify-write of the lock state.
with_lock() {
  local lockfile="${TMUX_TMPDIR:-/tmp}/tmux-autolock.lock"
  (
    flock -x 200
    "$@"
  ) 200>"$lockfile"
}

# --- the DRY lock state (single owner of the three settings) ---------------
# lock/unlock are the ONLY place the three settings are touched, so F12 and
# the poll can never drift out of sync with each other.
lock() {
  # Save the current (unlocked) prefix so unlock can restore it EXACTLY —
  # `set -gu` reverts to tmux's compiled-in default (C-b), not the conf's C-s.
  # Only save when we're not already locked.
  local cur
  cur=$(tmux show-options -gv prefix 2>/dev/null)
  [[ $cur == None || -z $cur ]] || tmux set -g @autolock_prefix "$cur"
  tmux set -g prefix None
  tmux set -g key-table off
  tmux refresh-client -S 2>/dev/null || true # best-effort; no-op when detached
}

unlock() {
  # Restore the saved prefix (the conf's C-s), not tmux's compiled-in default
  # (C-b).
  local saved
  saved=$(tmux show-options -gv @autolock_prefix 2>/dev/null)
  [[ -n $saved ]] && tmux set -g prefix "$saved"
  tmux set -gu @autolock_prefix
  tmux set -gu key-table
  tmux refresh-client -S 2>/dev/null || true # best-effort; no-op when detached
}

# --- the poll (the "brain") -------------------------------------------------
poll() {
  with_lock _poll_locked
}

_poll_locked() {
  local fg locked override action auto_desired
  fg=$(_foreground)
  locked=$(_is_locked && printf 1 || printf 0)
  override=$(_override)
  action=$(decide "$LOCKED_PROCS" "$fg" "$locked" "$override")
  case $action in
  lock) lock ;;
  unlock) unlock ;;
  esac
  # Clear the override once the auto-desired state matches it (auto and
  # manual agree), so a fresh matched proc re-asserts the auto behavior.
  if [[ -n $override ]]; then
    if matches_locked "$LOCKED_PROCS" "$fg"; then
      auto_desired=lock
    else
      auto_desired=unlock
    fi
    if [[ $auto_desired == "$override" ]]; then
      _clear_override
    fi
  fi
}

# --- the daemon loop --------------------------------------------------------
_start() {
  local pidfile="${TMUX_TMPDIR:-/tmp}/tmux-autolock.pid"
  if [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0 # already running
  fi
  printf '%s\n' "$$" >"$pidfile"
  trap 'rm -f "$pidfile"' EXIT
  local secs
  secs=$(awk -v ms="$INTERVAL_MS" 'BEGIN{printf "%g", ms/1000}')
  while :; do
    poll
    sleep "$secs"
  done
}

_stop() {
  local pidfile="${TMUX_TMPDIR:-/tmp}/tmux-autolock.pid"
  if [[ -f $pidfile ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null
    rm -f "$pidfile"
  fi
  return 0
}

toggle() { # manual override (F12): flip the lock state + arm the override
  with_lock _toggle_locked
}

_toggle_locked() {
  if _is_locked; then
    unlock
    _arm_override unlock
  else
    lock
    _arm_override lock
  fi
}

# --- dispatch ----------------------------------------------------------------
case ${1:-} in
start) _start ;;
stop) _stop ;;
poll) poll ;;
lock) lock ;;
unlock) unlock ;;
toggle) toggle ;;
*)
  printf 'usage: autolock.sh {start|stop|poll|lock|unlock|toggle}\n' >&2
  exit 2
  ;;
esac
