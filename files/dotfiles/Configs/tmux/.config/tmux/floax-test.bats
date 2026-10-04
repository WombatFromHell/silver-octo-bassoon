#!/usr/bin/env bats
# floax-test.bats — tab-bar logic of the floax pseudo-floating popup
# (section 5 of tmux.conf), on a throwaway server (see test_helper.bash).
#
# Each test starts from a fresh server + the real conf and builds its own
# floax session. State is awaited with wait_until, never slept for.

load test_helper

setup() {
  start_scratch_server
  load_conf
}
teardown() { stop_scratch_server; }

# new_floax N -> floax session with windows tab1..tabN (tab1 selected).
# -n pins the names (and disables automatic-rename) so assertions are stable.
new_floax() {
  local i
  tmux new-session -d -s floax -n tab1
  for ((i = 2; i <= $1; i++)); do tmux new-window -d -t floax -n "tab$i"; done
}

status_is() { [[ "$(tmux show-options -qv -t floax status)" == "$1" ]]; }
wait_status() { wait_until 5 status_is "$1"; }
bar_has() { [[ "$(tmux display -p -t floax:1 -F '#{T;=/100:status-left}')" == *"$1"* ]]; }
wait_bar() { wait_until 5 bar_has "$1"; }
top_row_has() { [[ "$(tmux capture-pane -p -t outer | sed -n 1p)" == *"$1"* ]]; }

@test "one window: tab bar hidden" {
  new_floax 1
  wait_status off
}

@test "adding a window shows the tab bar" {
  new_floax 2
  wait_status on
}

@test "closing back to one window hides the tab bar" {
  new_floax 2
  wait_status on
  tmux kill-window -t floax:2
  wait_status off
}

# Sentinel: force the bar off first, so only the window-closed hook can turn
# it back on (a malformed #{...} in the hook leaves it off -> red).
@test "closing a window with several left keeps the tab bar" {
  new_floax 3
  wait_status on
  tmux set -t floax status off
  tmux kill-window -t floax:3
  wait_status on
}

# tmux aborts format expansion on an unbalanced #{...}; that renders as a
# blank tab bar, so assert the expansion itself, not just the option.
@test "tab bar expands to the active tab name and inactive index" {
  new_floax 2
  wait_bar " 1 tab1"
  wait_bar " 2 "
}

@test "tab bar follows the active window" {
  new_floax 2
  tmux select-window -t floax:2
  wait_bar " 2 tab2"
}

# The real popup path: a nested client attached from inside a pane. Run as the
# pane's own command (no send-keys: no typing race, no shell startup).
@test "a nested client renders the tab bar in its top row" {
  new_floax 2
  tmux new-session -d -s outer 'env -u TMUX tmux attach-session -t floax'
  wait_until 5 top_row_has " 1 tab1  2"
}

# tmux 3.8 moved these defaults to 'theme' colours; the conf must pin them.
@test "popup and pane borders are pinned to the palette" {
  [[ "$(tmux show-options -gqv popup-border-style)" == "fg=#{@c_teal}" ]]
  [[ "$(tmux show-options -gqv pane-border-style)" == "fg=#{@c_m}" ]]
}
