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
# The output name is exported as NIRI_OUTPUT_NAME env var for hooks to use
# Example: ON_FULLSCREEN_HOOKS=("$HOME/.config/hooks/disable-compositor.sh")
# Hook scripts can access the output name via $NIRI_OUTPUT_NAME
# shellcheck disable=SC2034
declare -a ON_FULLSCREEN_HOOKS=("$HOME/.local/bin/scripts/perfboost.sh on")
# shellcheck disable=SC2034
declare -a ON_EXIT_FULLSCREEN_HOOKS=("$HOME/.local/bin/scripts/perfboost.sh off")

# Exclusion List - Apps that should never trigger VRR (even when fullscreen)
# Add app_id values from 'niri msg -j windows' to exclude specific applications
# Example: "brave-browser", "firefox", "vlc", "mpv"
# shellcheck disable=SC2034
declare -a EXCLUDE_APP_IDS=("brave-browser")

# --- State ---
# Maps output_name -> "fullscreen"|"windowed"
declare -A OUTPUT_STATES

# --- Helper Functions ---

log() {
  local timestamp
  timestamp=$(date '+%F %T')
  echo "${timestamp}: $1" >>"${LOG_FILE}"
}

# Check if an app_id is in the exclusion list
is_excluded_app() {
  local app_id="$1"
  local excluded
  for excluded in "${EXCLUDE_APP_IDS[@]}"; do
    if [[ "$app_id" == "$excluded" ]]; then
      return 0 # true - is excluded
    fi
  done
  return 1 # false - not excluded
}

# Executes an array of scripts/hooks in the background
# Each hook spec is "script arg1 arg2..." (args optional)
# If output_name is provided, it's exported as NIRI_OUTPUT_NAME env var
run_hooks() {
  local hook_array_name="$1"
  local output_name="${2:-}" # Optional output name
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
      if [[ -n "$output_name" ]]; then
        log "Executing hook: $hook_spec (NIRI_OUTPUT_NAME=$output_name)"
        (
          export NIRI_OUTPUT_NAME="$output_name"
          "$hook" "${args[@]}"
        ) &
      else
        log "Executing hook: $hook_spec"
        if [[ ${#args[@]} -gt 0 ]]; then
          ("$hook" "${args[@]}") &
        else
          ("$hook") &
        fi
      fi
    else
      log "Warning: Hook not found or not executable: $hook"
    fi
  done
}

# --- Core Logic ---

# Helper: Determine if a window is fullscreen on a given output
# Returns "fullscreen" or "windowed"
determine_window_state() {
  local output_name="$1"
  local win_json="$2"
  local outputs_json="$3"

  # Get output resolution
  local output_width output_height
  output_width=$(jq -r --arg on "$output_name" '.[$on].logical.width' <<<"$outputs_json")
  output_height=$(jq -r --arg on "$output_name" '.[$on].logical.height' <<<"$outputs_json")

  # Get window dimensions
  local win_width win_height
  win_width=$(jq -r '.layout.window_size[0]' <<<"$win_json")
  win_height=$(jq -r '.layout.window_size[1]' <<<"$win_json")

  # Validate dimensions
  if [[ -z "$win_width" || -z "$win_height" || -z "$output_width" || -z "$output_height" ]]; then
    echo "unknown"
    return
  fi

  # Compare dimensions (handle float vs int)
  local w_diff h_diff
  w_diff=$(echo "$output_width - $win_width" | bc -l | cut -d'.' -f1)
  h_diff=$(echo "$output_height - $win_height" | bc -l | cut -d'.' -f1)

  if [[ "${w_diff:-0}" -eq 0 && "${h_diff:-0}" -eq 0 ]]; then
    echo "fullscreen"
  else
    echo "windowed"
  fi
}

# Detects state for all outputs
# Populates OUTPUT_STATES associative array
detect_all_outputs() {
  local outputs_json windows_json workspaces_json
  # Fetch all necessary data in one go to minimize IPC calls
  outputs_json=$(niri msg -j outputs)
  windows_json=$(niri msg -j windows)
  workspaces_json=$(niri msg -j workspaces)

  # Build workspace_id -> output mapping from workspaces JSON
  declare -A workspace_to_output
  while IFS= read -r line; do
    local ws_id ws_output
    ws_id=$(echo "$line" | jq -r '.id')
    ws_output=$(echo "$line" | jq -r '.output // empty')
    if [[ -n "$ws_id" && "$ws_id" != "null" && -n "$ws_output" ]]; then
      workspace_to_output["$ws_id"]="$ws_output"
    fi
  done < <(jq -c '.[]' <<<"$workspaces_json")

  # Get the globally focused window (for determining which output is "active")
  local focused_win
  focused_win=$(jq -c '.[] | select(.is_focused == true)' <<<"$windows_json" | head -1)
  local focused_workspace=""
  if [[ -n "$focused_win" && "$focused_win" != "null" ]]; then
    focused_workspace=$(echo "$focused_win" | jq -r '.workspace_id')
  fi

  # Iterate through all outputs and determine state
  while IFS= read -r output_name; do
    local state="windowed" # Default to windowed if no window found

    # Find all workspace IDs on this output
    local output_workspaces=()
    for ws_id in "${!workspace_to_output[@]}"; do
      if [[ "${workspace_to_output[$ws_id]}" == "$output_name" ]]; then
        output_workspaces+=("$ws_id")
      fi
    done

    if [[ ${#output_workspaces[@]} -gt 0 ]]; then
      # Find the focused window if it's on this output
      local win_on_output=""
      if [[ -n "$focused_workspace" ]]; then
        for ws_id in "${output_workspaces[@]}"; do
          if [[ "$focused_workspace" == "$ws_id" ]]; then
            win_on_output="$focused_win"
            break
          fi
        done
      fi

      # If no focused window on this output, find any window on its workspaces
      if [[ -z "$win_on_output" ]]; then
        for ws_id in "${output_workspaces[@]}"; do
          win_on_output=$(jq -c --argjson ws "$ws_id" '.[] | select(.workspace_id == $ws)' <<<"$windows_json" | head -1)
          if [[ -n "$win_on_output" && "$win_on_output" != "null" ]]; then
            break
          fi
        done
      fi

      if [[ -n "$win_on_output" && "$win_on_output" != "null" ]]; then
        state=$(determine_window_state "$output_name" "$win_on_output" "$outputs_json")

        # Check if app is excluded - if so, force windowed state (no VRR, no hooks)
        local app_id
        app_id=$(echo "$win_on_output" | jq -r '.app_id // empty')
        if [[ -n "$app_id" ]] && is_excluded_app "$app_id"; then
          state="windowed"
        fi
      fi
    fi

    OUTPUT_STATES["$output_name"]="$state"
  done < <(jq -r 'keys[]' <<<"$outputs_json")
}

apply_all_states() {
  # Track previous states (static to persist between calls)
  declare -gA PREV_STATES

  # Iterate through all current outputs
  for output_name in "${!OUTPUT_STATES[@]}"; do
    local new_state="${OUTPUT_STATES[$output_name]}"
    local prev_state="${PREV_STATES[$output_name]:-windowed}"

    # Skip if state hasn't changed
    if [[ "$new_state" == "$prev_state" ]]; then
      continue
    fi

    log "State change: $prev_state -> $new_state (Output: $output_name)"

    if [[ "$new_state" == "fullscreen" ]]; then
      log "Enabling VRR on $output_name"
      niri msg output "$output_name" vrr on
      log "Running on_fullscreen hooks for $output_name..."
      run_hooks ON_FULLSCREEN_HOOKS "$output_name"
    elif [[ "$new_state" == "windowed" ]]; then
      log "Disabling VRR on $output_name"
      niri msg output "$output_name" vrr off
      log "Running on_exit_fullscreen hooks for $output_name..."
      run_hooks ON_EXIT_FULLSCREEN_HOOKS "$output_name"
    fi

    PREV_STATES["$output_name"]="$new_state"
  done

  # Handle outputs that were removed (no longer in OUTPUT_STATES)
  for output_name in "${!PREV_STATES[@]}"; do
    if [[ -z "${OUTPUT_STATES[$output_name]:-}" ]]; then
      log "Output $output_name removed, cleaning up state"
      unset "PREV_STATES[$output_name]"
    fi
  done
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

  # Initialize log file (overwrite previous run's log)
  : >"${LOG_FILE}"

  log "Starting Niri VRR Watcher..."

  # Wait for niri to be fully initialized
  log "Waiting ${STARTUP_DELAY}s for niri to initialize..."
  sleep "$STARTUP_DELAY"

  while true; do
    detect_all_outputs
    apply_all_states
    sleep "$POLL_INTERVAL"
  done
}

main "$@"
