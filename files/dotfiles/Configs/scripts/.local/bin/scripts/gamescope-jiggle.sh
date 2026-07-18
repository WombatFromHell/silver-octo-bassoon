#!/usr/bin/env bash
# gamescope-jiggle.sh -- jiggle mouse whenever gamescope regains focus.
#
# Usage:
#   gamescope-jiggle.sh -- gamescope -- <cmd>
#
# Everything after the first '--' is exec'd as the real command (e.g. gamescope
# itself); the watcher runs alongside it in the background and is cleaned up
# when that command exits. Also exits automatically once `steam` disappears.
#
# Requires: ydotool + ydotoold running, and either `niri` or `kdotool`
# (kdotool: kwin equivalent of xdotool, https://github.com/jinliu/kdotool).

set -euo pipefail
POLL=2
JIGGLE_PX=3
LOCKFILE="${XDG_RUNTIME_DIR:-/tmp}/gamescope-jiggle.lock"

if [[ "${1:-}" != "--" ]]; then
  echo "usage: gamescope-jiggle.sh -- <command...>" >&2
  exit 1
fi
shift
[[ $# -gt 0 ]] || {
  echo "gamescope-jiggle: no command given after --" >&2
  exit 1
}

# --- single instance guard ---
# Hold an flock on fd 9 for the life of this process (and its background
# watcher, which inherits the fd). The kernel releases it automatically on
# exit or crash, so there's no stale-lock cleanup to get wrong.
exec 9>"$LOCKFILE"
flock -n 9 || {
  echo "gamescope-jiggle: already running (lock held on $LOCKFILE)" >&2
  exit 1
}

# --- pick compositor backend ---
if command -v niri >/dev/null; then
  BACKEND=niri
elif command -v kdotool >/dev/null; then
  BACKEND=kwin
else
  echo "gamescope-jiggle: need 'niri' or 'kdotool' in PATH" >&2
  exit 1
fi

command -v ydotool >/dev/null || {
  echo "gamescope-jiggle: ydotool not found" >&2
  exit 1
}

screen_center() {
  # 1920x1080 fallback if we can't detect; ydotool has no getdisplaygeometry,
  # so ask the compositor if possible, else use xrandr/wlr-randr if present.
  local w=1920 h=1080
  if command -v wlr-randr >/dev/null; then
    read -r w h < <(wlr-randr 2>/dev/null | awk '/current/{print $1}' | head -1 | tr 'x' ' ') || true
    w=${w:-1920}
    h=${h:-1080}
  fi
  echo "$((w / 2)) $((h / 2))"
}

read -r CX CY < <(screen_center)

jiggle() {
  # a transient ydotoold hiccup shouldn't kill the whole watcher
  ydotool mousemove --absolute "$CX" "$CY" || true
  ydotool mousemove -- -"$JIGGLE_PX" 0 || true
  ydotool mousemove -- "$JIGGLE_PX" 0 || true
}

gamescope_focused() {
  case "$BACKEND" in
  niri)
    niri msg -j windows 2>/dev/null |
      grep -q '"app_id":"gamescope".*"is_focused":true'
    ;;
  kwin)
    # kdotool getactivewindow prints the window id; getwindowclassname resolves it
    local id
    id=$(kdotool getactivewindow 2>/dev/null) || return 1
    [[ -n "$id" ]] && kdotool getwindowclassname "$id" 2>/dev/null | grep -qi gamescope
    ;;
  esac
}

watch_loop() {
  local was_focused=0
  while pgrep -x steam >/dev/null; do
    if gamescope_focused; then
      if [[ "$was_focused" -eq 0 ]]; then
        jiggle
        was_focused=1
      fi
    else
      was_focused=0
    fi
    sleep "$POLL"
  done
}

watch_loop &
watcher_pid=$!
cleanup() { kill "$watcher_pid" 2>/dev/null || true; }
trap cleanup EXIT

# run the wrapped command (e.g. `gamescope -- <cmd>`) in the foreground;
# the EXIT trap cleans up the watcher and our exit code mirrors the child's.
"$@"
