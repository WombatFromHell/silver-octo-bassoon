#!/usr/bin/env bash
# autolock-lib.bash — pure decision layer for autolock.sh. No tmux, no I/O:
# `decide` maps (locked-procs, foreground, locked, override) to an action.
# Sourced by autolock.sh (consumer) and by the bats unit tier, so the same
# logic is exercised live and unit-tested with fixtures.

# matches_locked LOCKED_PROCS FG -> success (0) if FG is exactly one of the
# locked procs (full-string match, so 'sshd' does NOT match 'ssh').
matches_locked() {
  local pattern
  pattern="^($1)$"
  [[ $2 =~ $pattern ]]
}

# decide LOCKED_PROCS FG LOCKED OVERRIDE -> "lock" | "unlock" | "noop"
#   LOCKED_PROCS  regex alternation of procs that should lock (e.g. 'ssh|fzf')
#   FG            current foreground procname
#   LOCKED        1 if the leader is currently locked, else 0
#   OVERRIDE      "lock" | "unlock" | "" (manual state set by F12; "" = none).
#
# The override (if set) takes priority over the auto-desired state. The
# auto-desired state is "lock" if FG is a matched proc, else "unlock".
decide() {
  local locked_procs=$1 fg=$2 locked=$3 override=$4
  local auto_desired desired
  if matches_locked "$locked_procs" "$fg"; then
    auto_desired=lock
  else
    auto_desired=unlock
  fi
  [[ -n $override ]] && desired=$override || desired=$auto_desired
  if [[ $desired == lock && $locked != 1 ]]; then
    printf 'lock'
  elif [[ $desired == unlock && $locked == 1 ]]; then
    printf 'unlock'
  else
    printf 'noop'
  fi
}
