#!/usr/bin/env bats
# autolock-unit-test.bats — unit tier: the pure decision (no tmux).
# Sources autolock-lib.bash and asserts the decide/matches_locked truth table.
#
# Override is a direction: "lock" | "unlock" | "" (empty = no override).
# It takes priority over the auto-desired state.

setup() {
  # shellcheck disable=SC1091
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/autolock-lib.bash"
}

# --- Auto (no override) ---

@test "decide: matched proc, unlocked, no override -> lock" {
  run decide 'ssh|fzf' ssh 0 ""
  [[ $output == lock ]]
}

@test "decide: matched proc, already locked, no override -> noop" {
  run decide 'ssh|fzf' ssh 1 ""
  [[ $output == noop ]]
}

@test "decide: non-matched proc, locked, no override -> unlock" {
  run decide 'ssh|fzf' bash 1 ""
  [[ $output == unlock ]]
}

@test "decide: non-matched proc, unlocked, no override -> noop" {
  run decide 'ssh|fzf' bash 0 ""
  [[ $output == noop ]]
}

@test "decide: fzf is a matched proc -> lock" {
  run decide 'ssh|fzf' fzf 0 ""
  [[ $output == lock ]]
}

# --- Override: manual disengage ("unlock") ---

@test "decide: matched proc, unlocked, override=unlock -> noop (honor disengage)" {
  run decide 'ssh|fzf' ssh 0 "unlock"
  [[ $output == noop ]]
}

@test "decide: matched proc, locked, override=unlock -> unlock (disengage wins)" {
  run decide 'ssh|fzf' ssh 1 "unlock"
  [[ $output == unlock ]]
}

@test "decide: non-matched proc, locked, override=unlock -> unlock (agree)" {
  run decide 'ssh|fzf' bash 1 "unlock"
  [[ $output == unlock ]]
}

@test "decide: non-matched proc, unlocked, override=unlock -> noop (agree)" {
  run decide 'ssh|fzf' bash 0 "unlock"
  [[ $output == noop ]]
}

# --- Override: manual engage ("lock") ---

@test "decide: non-matched proc, locked, override=lock -> noop (honor engage — bug fix)" {
  run decide 'ssh|fzf' bash 1 "lock"
  [[ $output == noop ]]
}

@test "decide: non-matched proc, unlocked, override=lock -> lock (engage wins)" {
  run decide 'ssh|fzf' bash 0 "lock"
  [[ $output == lock ]]
}

@test "decide: matched proc, locked, override=lock -> noop (agree, already locked)" {
  run decide 'ssh|fzf' ssh 1 "lock"
  [[ $output == noop ]]
}

@test "decide: matched proc, unlocked, override=lock -> lock (agree)" {
  run decide 'ssh|fzf' ssh 0 "lock"
  [[ $output == lock ]]
}

# --- matches_locked ---

@test "matches_locked: ssh and fzf match, others do not" {
  run matches_locked 'ssh|fzf' ssh
  [[ $status == 0 ]]
  run matches_locked 'ssh|fzf' fzf
  [[ $status == 0 ]]
  run matches_locked 'ssh|fzf' bash
  [[ $status != 0 ]]
}

@test "matches_locked: full-string match (no substring false-positives)" {
  run matches_locked 'ssh' sshd
  [[ $status != 0 ]]
  run matches_locked 'ssh' ssh
  [[ $status == 0 ]]
}
