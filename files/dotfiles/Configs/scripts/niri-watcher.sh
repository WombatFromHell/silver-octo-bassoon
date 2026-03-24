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
    # Split into command and args (need to reset IFS temporarily since we set it to $'\n\t' globally)
    IFS=' ' read -r -a parts <<<"$hook_spec"
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
  local outputs_json windows_json
  # Fetch all necessary data in one go to minimize IPC calls
  outputs_json=$(niri msg -j outputs)
  windows_json=$(niri msg -j windows)

  # 1. Get the focused window
  local focused_win
  focused_win=$(jq -r '.[] | select(.is_focused == true)' <<<"$windows_json")

  if [[ -z "$focused_win" || "$focused_win" == "null" ]]; then
    CURRENT_STATE="unknown"
    return
  fi

  # 2. Get focused window's workspace_id to find which output it's on
  local workspace_id
  workspace_id=$(jq -r '.workspace_id' <<<"$focused_win")

  # 3. Find the output that contains this workspace (use first output for now)
  # Since niri's output JSON doesn't have workspace mapping, use the first output
  OUTPUT_NAME=$(jq -r 'keys[0]' <<<"$outputs_json")

  if [[ -z "$OUTPUT_NAME" || "$OUTPUT_NAME" == "null" ]]; then
    CURRENT_STATE="unknown"
    return
  fi

  # 4. Get Logical Resolution of the output
  local output_width output_height
  output_width=$(jq -r --arg on "$OUTPUT_NAME" '.[$on].logical.width' <<<"$outputs_json")
  output_height=$(jq -r --arg on "$OUTPUT_NAME" '.[$on].logical.height' <<<"$outputs_json")

  # 5. Get Focused Window Dimensions
  local win_width win_height
  win_width=$(jq -r '.layout.window_size[0]' <<<"$focused_win")
  win_height=$(jq -r '.layout.window_size[1]' <<<"$focused_win")

  # 6. Determine State - compare dimensions (handle float vs int)
  if [[ -z "$win_width" || -z "$win_height" || -z "$output_width" || -z "$output_height" ]]; then
    CURRENT_STATE="unknown"
  else
    # Use arithmetic comparison to handle float/int differences
    local w_diff h_diff
    w_diff=$(echo "$output_width - $win_width" | bc -l | cut -d'.' -f1)
    h_diff=$(echo "$output_height - $win_height" | bc -l | cut -d'.' -f1)
    
    if [[ "${w_diff:-0}" -eq 0 && "${h_diff:-0}" -eq 0 ]]; then
      CURRENT_STATE="fullscreen"
    else
      CURRENT_STATE="windowed"
    fi
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

  if ! command -v bc &>/dev/null; then
    echo "Error: 'bc' is required but not installed." >&2
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
