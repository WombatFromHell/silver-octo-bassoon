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

@test "tab list: uniform 2sp gaps with no bell (every active position)" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  local w title want
  for w in 0 1 2; do
    tmux select-window -t base:$w
    title="$(tmux display -p -t base:$w '#{pane_title}')"
    case $w in
    0) want=" 0  $title  1  2 " ;;
    1) want=" 0  1  $title  2 " ;;
    2) want=" 0  1  2  $title " ;;
    esac
    [[ "$(tab_list)" == "$want" ]]
  done
}

@test "tab list: per-window bell dot renders inline with uniform spacing" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  tmux set-window -t base:1 @bell 1
  local title
  title="$(tmux display -p -t base:0 '#{pane_title}')"
  [[ "$(tab_list)" == " 0  $title  1 ●  2 " ]]
}

@test "tab list: composable @sl_tab_bell unit holds the red dot" {
  start_server
  load_conf
  local bell_unit
  bell_unit="$(tmux show-options -gv @sl_tab_bell 2>/dev/null)"
  [[ $bell_unit == *'●'* ]]
  [[ $bell_unit == *'@c_red'* ]]
}
