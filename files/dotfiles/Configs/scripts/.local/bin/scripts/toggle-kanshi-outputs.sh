#!/usr/bin/env bash

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

readonly PROFILES=(
  "tv"
  "notv"
)
readonly DEBOUNCE_SECONDS=3

# ─── Path Resolution ─────────────────────────────────────────────────────────

xdg_runtime_dir() { echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; }
xdg_state_dir() { echo "${XDG_STATE_HOME:-$HOME/.local/state}"; }

lock_file() { echo "$(xdg_runtime_dir)/kanshi-toggle.lock"; }
state_file() { echo "$(xdg_state_dir)/kanshi-toggle"; }
timestamp_file() { echo "$(xdg_runtime_dir)/kanshi-toggle.timestamp"; }

# ─── File Management ─────────────────────────────────────────────────────────

ensure_state_dir() {
  mkdir -p "$(dirname "$(state_file)")"
}

# ─── Locking ─────────────────────────────────────────────────────────────────

acquire_lock() {
  exec 200>"$(lock_file)"
  if ! flock -n 200; then
    echo "Another toggle operation is in progress"
    return 1
  fi
}

# ─── Debounce ────────────────────────────────────────────────────────────────

is_debounced() {
  local ts_file
  ts_file="$(timestamp_file)"
  [[ -f "$ts_file" ]] || return 1

  local last_run now elapsed
  last_run=$(cat "$ts_file")
  now=$(date +%s)
  elapsed=$((now - last_run))

  if [[ $elapsed -lt $DEBOUNCE_SECONDS ]]; then
    local remaining=$((DEBOUNCE_SECONDS - elapsed))
    echo "Debounce active. Wait ${remaining}s before toggling again."
    return 0
  fi
  return 1
}

record_toggle_time() {
  date +%s >"$(timestamp_file)"
}

# ─── State Management ────────────────────────────────────────────────────────

read_state() {
  local sf
  sf="$(state_file)"
  [[ -f "$sf" ]] && cat "$sf" && return 0
  return 1
}

write_state() {
  echo "$1" >"$(state_file)"
}

# ─── Kanshi Interaction ──────────────────────────────────────────────────────

wait_for_stable_profile() {
  local prev="" stable_count=0 target_stable=3
  local i current
  for i in {1..15}; do
    current=$(kanshictl status 2>/dev/null | grep "Current profile:" | awk '{print $3}')
    if [[ -n "$current" && "$current" == "$prev" ]]; then
      ((stable_count++))
      if [[ $stable_count -ge $target_stable ]]; then
        echo "$current"
        return 0
      fi
    else
      stable_count=0
      prev="$current"
    fi
    sleep 0.2
  done
  echo "$prev"
  return 1
}

get_current_profile() {
  local state
  if state=$(read_state); then
    echo "$state"
    return 0
  fi
  wait_for_stable_profile
}

switch_profile() {
  local target="$1"
  if ! kanshictl switch "$target"; then
    echo "Failed to switch to profile: $target"
    return 1
  fi
  write_state "$target"
  record_toggle_time
  echo "Switched to profile: $target"
}

# ─── Profile Cycling ─────────────────────────────────────────────────────────

find_profile_index() {
  local profile="$1" i
  for i in "${!PROFILES[@]}"; do
    if [[ "${PROFILES[$i]}" == "$profile" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

next_profile() {
  local current="$1"
  local current_index
  if ! current_index=$(find_profile_index "$current"); then
    echo "Unknown or no active profile: $current" >&2
    echo "Available profiles: ${PROFILES[*]}" >&2
    return 1
  fi

  local num_profiles=${#PROFILES[@]}
  local next_index=$(((current_index + 1) % num_profiles))
  echo "${PROFILES[$next_index]}"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  ensure_state_dir
  acquire_lock

  if is_debounced; then
    return 0
  fi

  local current_profile
  current_profile=$(get_current_profile)

  local target
  target=$(next_profile "$current_profile") || exit 1

  switch_profile "$target"
}

main "$@"
