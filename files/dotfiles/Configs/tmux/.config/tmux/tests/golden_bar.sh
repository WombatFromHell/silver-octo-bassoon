#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/statusbar-lib.bash

OUT="tests/golden_bar.txt"
CONF="${TMUX_CONF:-$HOME/.config/tmux/tmux.conf}"

# Private socket in a private dir: can't collide with the default socket
# (/tmp/tmux-UID/default) or any other -L name.
SOCKDIR=$(mktemp -d)
SOCK="$SOCKDIR/golden.sock"

# env -u TMUX: if you run this from inside your real tmux, $TMUX points at
# your real server. -S already overrides it, but unsetting means no stray
# `tmux` call without -S can ever fall back to it.
# TMUX_TMPDIR: points any socket-less lookup at the temp dir too.
T() { env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux -S "$SOCK" "$@"; }

cleanup() {
  # Only ever kill our own server, and only if the socket exists.
  if [[ -S $SOCK ]]; then T kill-server 2>/dev/null || true; fi
  rm -rf "$SOCKDIR"
}
trap cleanup EXIT

T -f "$CONF" new-session -d -s golden -x 200 -y 20 'bash --norc --noprofile'

# Safety check: confirm we're talking to the throwaway server.
[[ $(T display -p '#{socket_path}') == "$SOCK" ]] || { echo "wrong server" >&2; exit 1; }

# tabs ACTIVE_IDX "title:bell" ...  -> rebuild windows 1..N with titles/bells
tabs() {
  local active=$1 i=1 spec
  shift
  T kill-window -a -t golden:1 2>/dev/null || true
  for spec in "$@"; do
    if ((i > 1)); then T new-window -d -t "golden:$i" 'bash --norc --noprofile'; fi
    T select-pane -t "golden:$i" -T "${spec%%:*}"
    T set -w -t "golden:$i" -u @bell
    if [[ ${spec##*:} == 1 ]]; then T set -w -t "golden:$i" @bell 1; fi
    i=$((i + 1))
  done
  T select-window -t "golden:$active"
}

# status-left exactly as tmux expands it (styles kept as #[...] tokens)
left() { T display-message -p -t golden '#{T:status-left}'; }
# status-right: fixed-value blocks from the library (no live metrics)
right() {
  compose_metrics
  _sb_time 1
}

{
  gpu= vram= cpu=15 ram=80 batt= batt_icon=
  date_str=07.06 clock=07:19
  printf '# State 1 — initial startup: single active tab; CPU + calendar/clock (no GPU, no battery)\n'
  tabs 1 "zsh:0"
  printf '%s%s\n' "$(left)" "$(right)"

  gpu=42 vram=67 cpu=15 ram=80 batt=85 batt_icon=$(_icon batt_8)
  printf '# State 2 — multi-tab: tab title visible; GPU + battery clusters added\n'
  tabs 2 "-:0" "code:0" "-:0"
  printf '%s%s\n' "$(left)" "$(right)"

  printf '# State 3 — terminal bell: notification dots on the inactive tabs\n'
  tabs 2 "-:1" "code:0" "-:1"
  printf '%s%s\n' "$(left)" "$(right)"
} >"$OUT"

echo "wrote $OUT"
