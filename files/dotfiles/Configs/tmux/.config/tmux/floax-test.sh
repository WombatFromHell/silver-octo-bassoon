#!/usr/bin/env bash
# floax-test.sh — red/green test for the floax pseudo-floating popup.
#
# Verifies the tab-bar logic that floax.conf installs via hooks:
#   1. floax session created with 1 window  -> status off  (no tab bar)
#   2. 2nd window added (window-linked)      -> status on   (tab bar)
#   3. window removed, back to 1 (unlinked)  -> status off  (no tab bar)
#   4. switching the active window works and is reflected
#
# Uses a throwaway server socket so it never touches your real sessions.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKDIR="$(mktemp -d /tmp/tmux-floax-test-XXXXXX)"   # dedicated socket dir
export TMUX_TMPDIR="$SOCKDIR"

tmux() { command tmux "$@"; }   # socket lives in $TMUX_TMPDIR

# Sourcing tmux.conf also runs its `run -b statusbar.sh`, which takes the
# global /tmp/tmux-statusbar.lock; remember pre-existing loops so cleanup
# only kills the one THIS test spawned.
OLD_LOOPS=" $({ pgrep -f 'statusbar\.sh' || true; } | tr '\n' ' ')"

cleanup() {
  for p in $({ pgrep -f 'statusbar\.sh' || true; }); do
    [[ "$OLD_LOOPS" == *" $p "* ]] || kill "$p" 2>/dev/null
  done
  tmux kill-server 2>/dev/null || true; rm -rf "$SOCKDIR";
}
trap cleanup EXIT

pass=0 fail=0
check() { # desc  actual  expected
  if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (got "%s", want "%s")\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
check_contains() { # desc  needle  haystack
  if [[ "$3" == *"$2"* ]]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (missing "%s" in "%s")\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
status_on() { tmux show-option -wqv -t floax status; }   # "on" / "off"

# Install the floax hooks + bindings (inlined in tmux.conf) on a fresh server.
tmux new-session -d -s base
tmux source-file "$DIR/tmux.conf"

# 1) floax created with a single window -> no tab bar.
tmux new-session -d -s floax
check "tab bar hidden at 1 window"  "$(status_on)" "off"

# 2) add a 2nd window -> window-linked fires -> tab bar shows.
tmux new-window -d -t floax
check "tab bar shown at 2 windows"  "$(status_on)" "on"

# 2a) the tab bar must actually EXPAND to both tab names. tmux 3.8 aborts
#     format expansion on an unbalanced #{...}, so a missing '}' in the
#     status-left renders as a blank tab bar (regression caught here).
tmux set -t floax automatic-rename off
tmux rename-window -t floax:1 tabone
tmux rename-window -t floax:2 tabtwo
tabs="$(tmux display -p -t floax:1 -F "#{T;=/100:status-left}")"
check_contains "tab bar expands with active tab name" "tabone" "$tabs"
check_contains "tab bar expands with inactive tab index" " 2 " "$tabs"

# 2b) end-to-end: a nested client attached to a pane must render the tab
#     bar in its top row (the real floax popup path).
tmux send-keys -t base:1 'env -u TMUX tmux attach-session -t floax' Enter
sleep 2
row="$(tmux capture-pane -t base:1 -p | sed -n 1p)"
check_contains "nested client renders tab bar" " 1 tabone  2" "$row"

# 3) switch the active window to window 2 and confirm it took.
tmux select-window -t floax:2
check "active window is 2 after switch" "$(tmux display -p -t floax '#{window_index}')" "2"

# 4) kill a window back to 1 -> window-unlinked fires -> tab bar hides.
tmux kill-window -t floax:2
check "tab bar hidden back at 1 window" "$(status_on)" "off"

# 5) tmux 3.8 moved popup/pane border defaults to 'theme' colours; the conf
#    must pin them to the catppuccin palette (floax popup chrome).
check "popup-border-style pinned" "$(tmux show-options -gqv popup-border-style)" "fg=#{@c_teal}"
check "pane-border-style pinned" "$(tmux show-options -gqv pane-border-style)" "fg=#{@c_m}"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
exit $(( fail > 0 ))
