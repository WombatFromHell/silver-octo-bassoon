#!/usr/bin/env bash
# statusbar.sh — tmux-server consumer: refreshes GPU/CPU/RAM into global env
# vars for the status bar. All parsing/computation lives in statusbar-lib.sh
# (unit-tested in isolation); this file only owns the flock, liveness, loop,
# /proc reads, and the tmux set-environment writes.
# Started from tmux.conf via `run -b`; flock-guarded so config reloads
# don't spawn duplicate loops.
#
# STATUSBAR_REFRESH — seconds between updates (default 3), tunable via
# env, e.g. `run -b 'STATUSBAR_REFRESH=5 bash ~/.config/tmux/statusbar.sh'`.
# CPU% is the average over that window (delta between iterations).
source "${BASH_SOURCE[0]%/*}/statusbar-lib.sh"

refresh_interval "${STATUSBAR_REFRESH:-3}"

# Per-socket lock file: each scratch server (and each real socket) gets its
# own lock, so concurrent consumers on different servers don't block each
# other. The global /tmp file would make the 2nd+ consumer exit.
exec 9>"${TMUX:-/tmp/tx}-statusbar.lock"
flock -n 9 || exit 0
# Seed placeholders immediately (cold start) so the status bar shows 0%|0%
# during the first fetch instead of hiding the GPU/CPU blocks.
tmux set-environment -g CPU 0
tmux set-environment -g RAM 0
tmux set-environment -g GPU_UTIL 0
tmux set-environment -g VRAM 0

prev_total=0
prev_idle=0
while :; do
  # Liveness: exit (releasing the flock) when our server is gone, e.g. after
  # a server restart, so the new server can spawn a fresh loop.
  tmux show-options -g >/dev/null 2>&1 || exit 0

  gpu_read

  # CPU% over the refresh window: delta from the previous iteration.
  read -r _ u n s i w _ </proc/stat
  total=$((u + n + s + i + w))
  idle=$((i + w))
  cpu_delta "$prev_total" "$prev_idle" "$total" "$idle"
  prev_total=$total
  prev_idle=$idle

  # RAM%: one pass over /proc/meminfo.
  read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  ram_pct "$mt" "$ma"

  # Batch the tmux env writes into ONE tmux invocation. set-environment takes
  # a single `NAME VALUE` pair (NAME=VALUE is rejected), so chain with \;
  args=(set-environment -g CPU "$cpu" \; set-environment -g RAM "$ram")
  if [[ $gpu =~ ^[0-9]+$ ]]; then
    args+=(\; set-environment -g GPU_UTIL "$gpu")
    if [[ $vram =~ ^[0-9]+$ ]]; then
      args+=(\; set-environment -g VRAM "$vram")
    else
      args+=(\; set-environment -gu VRAM)
    fi
  else
    args+=(\; set-environment -gu GPU_UTIL \; set-environment -gu VRAM)
  fi
  tmux "${args[@]}"

  sleep "$refresh"
done
