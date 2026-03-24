#!/usr/bin/env bash

# --- Strict Mode & Safety ---
set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
readonly POLL_INTERVAL=2
readonly LOG_FILE="${XDG_RUNTIME_DIR:-/tmp}/niri-vrr-watch.log"
readonly STARTUP_DELAY=3

# Hook Arrays
# Each element is "script arg1 arg2..." - args are optional
# Example: ON_FULLSCREEN_HOOKS=("$HOME/.config/hooks/disable-compositor.sh")
# shellcheck disable=SC2034
declare -a ON_FULLSCREEN_HOOKS=("$HOME/.local/bin/scripts/perfboost.sh on")
# shellcheck disable=SC2034
declare -a ON_EXIT_FULLSCREEN_HOOKS=("$HOME/.local/bin/scripts/perfboost.sh off")

# --- State ---
LAST_STATE="windowed" # Tracks 'fullscreen' or 'windowed'

# --- Helper Functions ---

log() {
  local timestamp
  timestamp=$(date '+%F %T')
  echo "${timestamp}: $1" >>"${LOG_FILE}"
}

# Executes an array of scripts/hooks in the background
# Each hook spec is "script arg1 arg2..." (args optional)
run_hooks() {
  local hook_array_name="$1"
  local -n hooks_ref="${hook_array_name}"

  if [[ ${#hooks_ref[@]} -eq 0 ]]; then
    return
  fi

  for hook_spec in "${hooks_ref[@]}"; do
    # Split into command and args
    read -r -a parts <<<"$hook_spec"
    local hook="${parts[0]}"
    local args=("${parts[@]:1}")

    if [[ -x "$hook" ]]; then
      log "Executing hook: $hook_spec"
      if [[ ${#args[@]} -gt 0 ]]; then
        ("$hook" "${args[@]}") &
      else
        ("$hook") &
      fi
    else
      log "Warning: Hook not found or not executable: $hook"
    fi
  done
}

# --- Core Logic ---

# Detects the current state by fetching window and output data
# Sets global variables: OUTPUT_NAME, CURRENT_STATE
detect_state() {
  local json_data
  # Fetch all necessary data in one go to minimize IPC calls
  json_data=$(niri msg -j outputs)

  # 1. Find the focused output (where the cursor/input is)
  OUTPUT_NAME=$(jq -r '.[] | select(.is_focused == true) | .name' <<<"$json_data")

  if [[ -z "$OUTPUT_NAME" ]]; then
    # Fallback: if no focused output found, try to find the one with the focused window?
    # For now, we skip cycle if we can't identify the active output.
    CURRENT_STATE="unknown"
    return
  fi

  # 2. Get Logical Resolution of the focused output
  local output_res
  output_res=$(jq -r --arg on "$OUTPUT_NAME" '.[] | select(.name == $on) | "\(.logical_width)x\(.logical_height)"' <<<"$json_data")

  # 3. Get Focused Window Dimensions
  # We fetch windows separately as they change rapidly
  local win_res
  win_res=$(niri msg -j windows | jq -r '.[] | select(.is_focused == true) | "\(.layout.window_size[0])x\(.layout.window_size[1])"')

  # 4. Determine State
  if [[ -z "$win_res" || -z "$output_res" ]]; then
    CURRENT_STATE="unknown"
  elif [[ "$output_res" == "$win_res" ]]; then
    CURRENT_STATE="fullscreen"
  else
    CURRENT_STATE="windowed"
  fi
}

apply_state() {
  local new_state="$1"

  if [[ "$new_state" == "$LAST_STATE" ]]; then
    return
  fi

  log "State change: $LAST_STATE -> $new_state (Output: ${OUTPUT_NAME:-N/A})"

  if [[ "$new_state" == "fullscreen" ]]; then
    log "Running on_fullscreen hooks..."
    # niri msg output "$OUTPUT_NAME" vrr on
    run_hooks ON_FULLSCREEN_HOOKS
  elif [[ "$new_state" == "windowed" ]]; then
    log "Running on_exit_fullscreen hooks..."
    # niri msg output "$OUTPUT_NAME" vrr off
    run_hooks ON_EXIT_FULLSCREEN_HOOKS
  fi

  LAST_STATE="$new_state"
}

# --- Main Entry Point ---

main() {
  # Check dependencies
  if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is required but not installed." >&2
    exit 1
  fi

  if ! command -v niri &>/dev/null; then
    echo "Error: 'niri' is required but not installed." >&2
    exit 1
  fi

  log "Starting Niri VRR Watcher..."

  # Wait for niri to be fully initialized
  log "Waiting ${STARTUP_DELAY}s for niri to initialize..."
  sleep "$STARTUP_DELAY"

  while true; do
    detect_state
    apply_state "$CURRENT_STATE"
    sleep "$POLL_INTERVAL"
  done
}

main "$@"
