#!/usr/bin/env bash
# statusbar.sh — tmux-server consumer: refreshes GPU/CPU/RAM into global env
# vars for the status bar. All parsing/computation lives in statusbar-lib.sh
# (unit-tested in isolation); this file only owns the lock, liveness, loop,
# the platform's raw reads (/proc on Linux, top/vm_stat on macOS), and the
# tmux set-environment writes.
# Started from tmux.conf via `run -b`; lock-guarded so config reloads
# don't spawn duplicate loops.
#
# STATUSBAR_REFRESH — seconds between updates (default 3), tunable via
# env, e.g. `run -b 'STATUSBAR_REFRESH=5 bash ~/.config/tmux/statusbar.sh'`.
# Linux: CPU% is the average over that window (delta between iterations).
# macOS: CPU% is a 1s top(1) sample, taken every refresh+1 seconds.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
source "${BASH_SOURCE[0]%/*}/statusbar-lib.bash"

refresh_interval "${STATUSBAR_REFRESH:-3}"

# Per-socket lock: each scratch server (and each real socket) gets its own.
# Prefer flock(1) (kernel-released); macOS has none, so fall back to a pidfile.
# The path embeds the tmux server pid ($TMUX = socket,pid,idx), so a recycled
# pid can't collide with a lock from a previous server.
lock="${TMUX:-/tmp/tx}-statusbar.lock"
if command -v flock >/dev/null; then
  exec 9>"$lock"
  flock -n 9 || exit 0
else
  claim() { (
    set -o noclobber
    echo $$ >"$lock"
  ) 2>/dev/null; }
  if ! claim; then
    kill -0 "$(<"$lock")" 2>/dev/null && exit 0 # live owner -> we are a duplicate
    rm -f "$lock"                               # stale: owner died
    claim || exit 0                             # lost the takeover race
  fi
  trap 'rm -f "$lock"' EXIT
fi

# Platform probe: one uname call, reused by the branch below.
platform=$(uname -s)

# sample -> sets cpu/ram. The only platform-specific code in the loop.
if [[ $platform == Darwin ]]; then
  sample() {
    cpu_darwin "$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null)"
    ram_darwin "$(vm_stat 2>/dev/null)" "$(sysctl -n hw.memsize 2>/dev/null)"
  }
else
  prev_total=0
  prev_idle=0
  sample() {
    local u n s i w total idle mt ma
    read -r _ u n s i w _ </proc/stat
    total=$((u + n + s + i + w))
    idle=$((i + w))
    cpu_delta "$prev_total" "$prev_idle" "$total" "$idle"
    prev_total=$total
    prev_idle=$idle
    read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
    ram_pct "$mt" "$ma"
  }
fi

while :; do
  # Liveness: exit (releasing the lock) when our server is gone, e.g. after
  # a server restart, so the new server can spawn a fresh loop.
  tmux show-options -g >/dev/null 2>&1 || exit 0

  gpu_read
  sample

  # One tmux invocation. set-environment takes a single `NAME VALUE` pair
  # (NAME=VALUE is rejected), so chain with \;
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
