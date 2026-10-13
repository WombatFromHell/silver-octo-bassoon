#!/usr/bin/env bats
# autolock-e2e-test.bats — integration tier: lock/unlock/toggle/poll against
# a scratch server. Drives the real script via `tmux run-shell` (server
# context, so the script's own tmux calls hit the scratch server).
#
# Override is a direction: "lock" | "unlock" | "" (empty = none). It takes
# priority over the auto-desired state and is cleared when the two agree.

# shellcheck disable=SC1091
source "$(dirname "$BATS_TEST_FILENAME")/test_helper.bash"

setup() {
  start_scratch_server
  mkdir -p "$HOME/.config/tmux/scripts"
  cp "$BATS_TEST_DIRNAME/../scripts/autolock.sh" "$HOME/.config/tmux/scripts/"
  cp "$BATS_TEST_DIRNAME/../scripts/autolock-lib.bash" "$HOME/.config/tmux/scripts/"
  cp "$BATS_TEST_DIRNAME/../scripts/lockchip.sh" "$HOME/.config/tmux/scripts/"
  chmod +x "$HOME/.config/tmux/scripts/autolock.sh" "$HOME/.config/tmux/scripts/lockchip.sh"
}
teardown() { stop_scratch_server; }

_ov() { tmux show-options -gv @autolock_override 2>/dev/null; }

@test "lock() sets prefix/key-table to the locked state" {
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh lock"
  [[ $(tmux show-options -gv prefix) == None ]]
  [[ $(tmux show-options -gv key-table) == off ]]
}

@test "unlock() clears the locked state back to defaults" {
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh lock"
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh unlock"
  [[ $(tmux show-options -gv prefix) != None ]]
  [[ $(tmux show-options -gv key-table) != off ]]
}

@test "toggle() flips the lock state and arms the directional override" {
  # Engage (not locked -> lock, override=lock)
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(tmux show-options -gv prefix) == None ]]
  [[ $(_ov) == lock ]]
  # Disengage (locked -> unlock, override=unlock)
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(tmux show-options -gv prefix) != None ]]
  [[ $(_ov) == unlock ]]
}

@test "poll() locks when the foreground is a locked proc, unlocks when it exits" {
  tmux send-keys -t base 'sleep 60' Enter
  sleep 1
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  [[ $(tmux show-options -gv prefix) == None ]]
  tmux send-keys -t base C-c
  sleep 1
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  [[ $(tmux show-options -gv prefix) != None ]]
}

@test "poll() noops when override=lock and no matched proc (honor engage — bug fix)" {
  # No matched proc in foreground. F12 engage.
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(tmux show-options -gv prefix) == None ]]
  [[ $(_ov) == lock ]]
  # Poll: fg not matched, locked=1, override=lock -> noop (stays locked).
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  sleep 0.5
  [[ $(tmux show-options -gv prefix) == None ]]
  [[ $(_ov) == lock ]]
}

@test "poll() noops when override=unlock and matched proc (honor disengage)" {
  # Matched proc in foreground. F12 disengage.
  tmux send-keys -t base 'sleep 60' Enter
  sleep 1
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(tmux show-options -gv prefix) == None ]]
  [[ $(_ov) == lock ]]
  # Disengage via F12
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(tmux show-options -gv prefix) != None ]]
  [[ $(_ov) == unlock ]]
  # Poll: fg matched, not locked, override=unlock -> noop (stays disengaged).
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  sleep 0.5
  [[ $(tmux show-options -gv prefix) != None ]]
  [[ $(_ov) == unlock ]]
}

@test "poll() clears override when auto_desired matches override (engage)" {
  # Matched proc in foreground. F12 engage. auto_desired=lock == override=lock -> clear.
  tmux send-keys -t base 'sleep 60' Enter
  sleep 1
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(_ov) == lock ]]
  # Poll: clears the override (auto and manual agree on lock).
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  sleep 0.5
  [[ $(_ov) == "" ]]
  # Still locked (auto_desired=lock, no override -> lock, already locked -> noop).
  [[ $(tmux show-options -gv prefix) == None ]]
}

@test "poll() clears override when auto_desired matches override (disengage)" {
  # No matched proc. F12 engage then disengage. override=unlock, auto_desired=unlock -> clear.
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(_ov) == lock ]]
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh toggle"
  [[ $(_ov) == unlock ]]
  # Poll: clears the override (auto and manual agree on unlock).
  tmux run-shell "AUTOLOCK_PROCS=sleep $HOME/.config/tmux/scripts/autolock.sh poll"
  sleep 0.5
  [[ $(_ov) == "" ]]
  [[ $(tmux show-options -gv prefix) != None ]]
}

# --- lockchip.sh (the #() lock-glyph helper for the session chip) ---------

# _lc -> run lockchip.sh against the scratch server. The script's bare
# `tmux` needs the scratch socket, so set TMUX to it (as tmux's #() children
# get from the server environment).
_lc() { TMUX="$SOCK" bash "$HOME/.config/tmux/scripts/lockchip.sh"; }

@test "lockchip.sh emits the styled lock glyph when the leader is locked" {
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh lock"
  local out
  out=$(_lc)
  # Leading space + styled glyph + trailing space (the 1-col separators).
  # Expected: leading space + styled glyph + trailing space (1-col separators).
  # The glyph is the nf-cod-lock U+EA75 (bytes ee a9 b5).
  local want
  # lockchip.sh colours the glyph with @c_lock (a dark red). This unconf test
  # server has no @c_lock, so it falls back to #d20f39 (the script's own
  # default). Pin the real emitted bytes: leading space + styled glyph +
  # trailing space.
  want=$(printf ' #[fg=#d20f39]\uea75 ')
  [[ $out == "$want" ]]
}

@test "lockchip.sh emits nothing when the leader is unlocked" {
  tmux run-shell "$HOME/.config/tmux/scripts/autolock.sh unlock"
  local out
  out=$(_lc)
  [[ -z $out ]]
}

@test "session chip format: fg re-asserted right after the #() lock job (no color bleed)" {
  load_conf
  # The composed format must re-assert the chip fg immediately after the
  # job: lockchip.sh's #[fg=...] would otherwise style the session name.
  local fmt
  fmt="$(tmux show-options -gv @sl_session)"
  # grep -F: a glob's [ ] would misparse the style tokens.
  grep -qF '#(bash ~/.config/tmux/scripts/lockchip.sh)#[fg=#{@c_base}]' <<<"$fmt"
}
