#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2001,SC2030,SC2031
# statusbar-tablist-test.bats — integration tier: status-left tab list
# (@sl_windows_fmt) rendered against a throwaway tmux server with the stub
# statusbar script. No real data pulls, no sleeps.

bats_require_minimum_version 1.5.0
load test_helper

teardown() {
  stop_scratch_server
}

# --- helpers -------------------------------------------------------------------

# Render the tab list (@sl_windows_fmt) from the scratch server, style tokens stripped.
tab_list() { tmux display -p -t base:0 '#{E:@sl_windows_fmt}' | sed 's/#\[[^]]*\]//g'; }

@test "tab list: active window shows index + title at every active position" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  # Pin each pane title: auto-rename races hostname-vs-CWD (the old exact-title
  # assertions flaked on that). Short titles stay un-truncated, so the active
  # slot " #I  <title>" is stable and the assertion targets it (not the gaps).
  local w
  for w in 0 1 2; do
    tmux set-window -t base:$w automatic-rename off
    tmux select-pane -t base:$w -T "title$w"
  done
  for w in 0 1 2; do
    tmux select-window -t base:$w
    [[ "$(tab_list)" == *" $w  title$w"* ]]
  done
}

@test "tab list: per-window bell dot renders inline next to the window index" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  local w
  for w in 0 1 2; do
    tmux set-window -t base:$w automatic-rename off
    tmux select-pane -t base:$w -T "title$w"
  done
  # Bell on the inactive win1: the red dot renders inline right after its index.
  tmux set-window -t base:1 @bell 1
  [[ "$(tab_list)" == *" 1 ● "* ]]
}

@test "tab list: composable @sl_tab_bell unit holds the red dot" {
  start_server
  load_conf
  local bell_unit
  bell_unit="$(tmux show-options -gv @sl_tab_bell 2>/dev/null)"
  [[ $bell_unit == *'●'* ]]
  [[ $bell_unit == *'@c_red'* ]]
}

@test "tab list: fish-middle-truncated title (already has …) never double-ellipsizes" {
  start_server
  load_conf
  # fish middle-truncates a long CWD to head + '…' + tail (fish
  # helpers/shell/truncate.fish) before tmux ever sees it as pane_title.
  tmux set-window -t base:0 automatic-rename off
  tmux select-pane -t base:0 -T '/v/m/d/u/j/s/overlay/0a7ad04db0…b00fa771d8bba20362e1cee7c2742bd'
  # sanity: the explicit title must actually stick (the auto-renamed one
  # fluctuates with the pane shell, which is why the sibling tests are flaky).
  [[ "$(tmux display -p -t base:0 '#{pane_title}')" == '/v/m/d/u/j/s/overlay/0a7ad04db0…b00fa771d8bba20362e1cee7c2742bd' ]]
  local out
  out="$(tmux display -p -t base:0 '#{E:@sl_windows_fmt}' | sed 's/#\[[^]]*\]//g')"
  [[ $out != *'……'* ]]                                # never two adjacent ellipses
  [[ $out == *'/v/m/d/u/j/s/overlay/0a7ad04db0… '* ]] # single ellipsis + margin
}
