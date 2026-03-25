#!/usr/bin/env bash

set -euo pipefail

# Configuration Section - Customize these variables to control script behavior
# Set to "true" to enable a feature, "false" to disable it
ENABLE_SCX_SCHEDULER="true"
ENABLE_PERFORMANCE_MODE="false"
ENABLE_SCREEN_KEEP_AWAKE="true"
ENABLE_AUDIO_PRIORITY_BOOST="false"
ENABLE_STEAM_ENV="true"
#
# Default output name (can be overridden via command-line argument or NIRI_OUTPUT_NAME env var)
NIRI_OUTPUT_DEFAULT="DP-1"
NIRI_OUTPUT="" # Set by main() from env var, args, or default

# State tracking (for idempotency)
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/perfboost"
STATE_FILE="${STATE_DIR}/active.state"

# SCX Scheduler Configuration
SCX_SCHEDULER_NAME="scx_lavd"
SCX_SCHEDULER_ARGS=(
  --performance
  --preempt-shift 6
  --slice-min-us 500
)

# Performance Mode Configuration (for tuned-adm)
GAME_PROFILE="throughput-performance-bazzite"
DESKTOP_PROFILE="balanced-bazzite"

# Audio Priority Boost Configuration
PULSE_LATENCY_MSEC=60 # PulseAudio latency setting for audio priority

# Logging function for better debugging
log() {
  echo "[perfboost.sh] $1"
}

# State tracking functions for idempotency
is_active() {
  [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "active" ]]
}

set_state_active() {
  mkdir -p "$STATE_DIR"
  echo "active" >"$STATE_FILE"
}

set_state_inactive() {
  rm -f "$STATE_FILE"
}

# Error handling function
error_exit() {
  echo "[perfboost.sh] ERROR: $1" >&2
  exit 1
}

check_cmd() {
  if cmd_path=$(command -v "$1"); then
    echo "$cmd_path"
  else
    echo ""
  fi
}

# Usage info
usage() {
  cat <<EOF
Usage: $(basename "$0") [COMMAND] [OUTPUT] [ARGS...]

Commands:
  on [OUTPUT]     Enable performance settings (SCX, VRR, Power Profile).
                  OUTPUT is optional - specifies the niri output name (e.g., DP-1, HDMI-A-1).
                  Does not support process-based features (Inhibit, Audio Env).
  off [OUTPUT]    Disable performance settings and restore defaults.
                  OUTPUT is optional - specifies the niri output name.
  <command>       Run the specified command with all features enabled (Wrapper Mode).
                  Supports full feature set including Inhibit and Audio Env.

If no command is provided, runs in Wrapper Mode with the provided arguments.

Output Resolution (priority order):
  1. NIRI_OUTPUT_NAME env var (set by niri-watcher.sh for hooks)
  2. OUTPUT command-line argument
  3. NIRI_OUTPUT_DEFAULT (DP-1, or custom in script config)

Examples:
  $(basename "$0") on DP-1          # Enable with VRR on DP-1
  $(basename "$0") off HDMI-A-1     # Disable VRR on HDMI-A-1
  $(basename "$0") steam            # Run steam with all features (wrapper mode)
  NIRI_OUTPUT_NAME=HDMI-A-1 $(basename "$0") on  # Via env var
EOF
  exit 0
}

# Get command paths and validate dependencies
get_command_paths() {
  local tuned_path
  tuned_path="$(check_cmd "tuned-adm")"
  local inhibit_path
  inhibit_path="$(check_cmd "systemd-inhibit")"
  local scxctl_path
  scxctl_path="$(check_cmd "scxctl")"

  # Validate dependencies based on configuration
  [[ "$ENABLE_PERFORMANCE_MODE" = "true" && -z "$tuned_path" ]] &&
    error_exit "Performance mode requires 'tuned-adm', but it's not installed or not in PATH"

  [[ "$ENABLE_SCREEN_KEEP_AWAKE" = "true" && -z "$inhibit_path" ]] &&
    error_exit "Screen keep-awake requires 'systemd-inhibit', but it's not installed or not in PATH"

  [[ "$ENABLE_SCX_SCHEDULER" = "true" && -z "$scxctl_path" ]] &&
    error_exit "SCX scheduler management requires 'scxctl', but it's not installed or not in PATH"

  # Output paths: tuned_path, inhibit_path, scxctl_path
  printf "%s\n" "$tuned_path" "$inhibit_path" "$scxctl_path"
}

# SCX Scheduler Functions
scx_load() {
  local scxctl_path="$1"

  [[ "$ENABLE_SCX_SCHEDULER" != "true" ]] && {
    log "SCX scheduler disabled by configuration"
    return 0
  }

  local scx="${SCX_SCHEDULER_NAME}"
  local SCXS
  SCXS="$(check_cmd "$scx")"

  [[ -z "$SCXS" ]] && {
    log "Error: '$scx' not found, skipping SCX scheduler..."
    return 0
  }

  # Check current scheduler status (idempotency)
  local current_sched
  current_sched=$("$scxctl_path" status 2>/dev/null | head -1) || true

  if [[ -n "$current_sched" ]]; then
    # A scheduler is already loaded
    if [[ "$current_sched" == *"$scx"* ]]; then
      log "SCX scheduler already loaded: $scx"
      return 0
    else
      # Different scheduler loaded, need to switch
      log "Switching SCX scheduler to: $scx (from: $current_sched)"
      "$scxctl_path" switch -s "$SCX_SCHEDULER_NAME" -a="${SCX_SCHEDULER_ARGS[*]}"
      return $?
    fi
  fi

  # No scheduler loaded, use start
  log "Loading SCX scheduler: $scx"
  "$scxctl_path" start -s "$SCX_SCHEDULER_NAME" -a="${SCX_SCHEDULER_ARGS[*]}"
}

scx_unload() {
  local scxctl_path="$1"

  [[ "$ENABLE_SCX_SCHEDULER" != "true" ]] && return
  [[ -z "$scxctl_path" ]] && return

  # Check if scheduler is loaded (idempotency)
  if ! "$scxctl_path" status &>/dev/null; then
    log "SCX scheduler not loaded, skipping unload"
    return 0
  fi

  log "Unloading SCX scheduler"
  "$scxctl_path" stop
}

niri_vrr_enable() {
  local output="${1:-DP-1}"
  local niri_cmd
  niri_cmd="$(check_cmd "niri")"

  [[ -z "$niri_cmd" ]] && {
    log "niri not found, skipping VRR enablement..."
    return 0
  }

  # Check if VRR is already enabled (idempotency)
  local vrr_status
  vrr_status=$("$niri_cmd" msg -j outputs 2>/dev/null | jq -r --arg on "$output" '.[] | select(.name == $on) | .vrr' 2>/dev/null) || true

  if [[ "$vrr_status" == "true" ]]; then
    log "VRR already enabled on $output"
    return 0
  elif [[ -z "$vrr_status" ]]; then
    # Output not found or niri not responding - skip silently
    log "Output '$output' not found or niri not responding, skipping VRR enable"
    return 0
  fi

  log "Enabling VRR on $output"
  "$niri_cmd" msg output "$output" vrr on
  return 0
}
niri_vrr_disable() {
  local output="${1:-DP-1}"
  local niri_cmd
  niri_cmd="$(check_cmd "niri")"

  [[ -z "$niri_cmd" ]] && {
    log "niri not found, skipping VRR disable"
    return 0
  }

  # Check if VRR is already disabled (idempotency)
  local vrr_status
  vrr_status=$("$niri_cmd" msg -j outputs 2>/dev/null | jq -r --arg on "$output" '.[] | select(.name == $on) | .vrr' 2>/dev/null) || true

  if [[ "$vrr_status" == "false" ]]; then
    log "VRR already disabled on $output"
    return 0
  elif [[ -z "$vrr_status" ]]; then
    # Output not found or niri not responding - skip silently
    log "Output '$output' not found or niri not responding, skipping VRR disable"
    return 0
  fi

  log "Disabling VRR on $output"
  "$niri_cmd" msg output "$output" vrr off
  return 0
}

# Performance Mode Functions
performance_mode_enable() {
  local tuned_path="$1"

  [[ "$ENABLE_PERFORMANCE_MODE" != "true" ]] && {
    log "Performance mode disabled by configuration"
    return
  }

  [[ -z "$tuned_path" ]] && {
    log "tuned-adm not available, skipping performance mode"
    return
  }

  # Check current profile (idempotency)
  local current_profile
  current_profile=$("$tuned_path" active 2>/dev/null | grep -oP '(?<=Active profile: ).*')
  if [[ "$current_profile" == "$GAME_PROFILE" ]]; then
    log "Performance mode already active: $GAME_PROFILE"
    return 0
  fi

  log "Enabling performance mode: $GAME_PROFILE"
  "$tuned_path" profile "$GAME_PROFILE"
}

performance_mode_disable() {
  local tuned_path="$1"

  [[ "$ENABLE_PERFORMANCE_MODE" != "true" ]] && return
  [[ -z "$tuned_path" ]] && return

  # Check current profile (idempotency)
  local current_profile
  current_profile=$("$tuned_path" active 2>/dev/null | grep -oP '(?<=Active profile: ).*')
  if [[ "$current_profile" == "$DESKTOP_PROFILE" ]]; then
    log "Performance mode already set to: $DESKTOP_PROFILE"
    return 0
  fi

  log "Disabling performance mode: $DESKTOP_PROFILE"
  "$tuned_path" profile "$DESKTOP_PROFILE"
}

# Audio Priority Boost Function
audio_priority_boost_enable() {
  [[ "$ENABLE_AUDIO_PRIORITY_BOOST" != "true" ]] && {
    log "Audio priority boost disabled by configuration"
    return 1
  }

  log "Enabling audio priority boost with PULSE_LATENCY_MSEC=$PULSE_LATENCY_MSEC"
  export PULSE_LATENCY_MSEC
  return 0
}

# Steam Environment Function
get_steam_env_wrapper() {
  local steam_env_script="$HOME/.local/bin/scripts/steam-env-base.sh"
  if [[ -f "$steam_env_script" && "$ENABLE_STEAM_ENV" == "true" ]]; then
    echo "$steam_env_script"
    return 0
  else
    echo ""
    return 1
  fi
}

# Screen Keep-Awake Functions
screen_keep_awake_enable() {
  local inhibit_path="$1"
  shift # Remove the first argument to get the original command arguments

  [[ "$ENABLE_SCREEN_KEEP_AWAKE" != "true" ]] && {
    log "Screen keep-awake disabled by configuration"
    return
  }

  [[ -z "$inhibit_path" ]] && {
    log "systemd-inhibit not available, skipping screen keep-awake"
    return
  }

  local kde_inhibit=""
  # Only use kde-inhibit if running under KDE
  if [[ "${XDG_SESSION_DESKTOP:-}" == "KDE" || "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]]; then
    kde_inhibit="$(check_cmd "kde-inhibit")"
    [[ -z "$kde_inhibit" ]] &&
      log "kde-inhibit not available, skipping KDE color correction"
  fi

  log "Enabling screen keep-awake"
  # Inhibits idle (screen off) AND sleep (suspend), using 'block' mode to force refusal
  if [[ -n "$kde_inhibit" ]]; then
    log "Disabling KDE color correction"
    "$inhibit_path" --what=idle:sleep --mode=block --why "perfboost.sh is running" -- \
      "$kde_inhibit" --colorCorrect "$@"
  else
    "$inhibit_path" --what=idle:sleep --mode=block --why "perfboost.sh is running" -- "$@"
  fi
}

# Cleanup function
cleanup() {
  local tuned_path="$1"
  local scxctl_path="$2"
  local niri_output="$3"

  log "Running cleanup..."
  performance_mode_disable "$tuned_path"
  scx_unload "$scxctl_path"
  niri_vrr_disable "$niri_output"
}

# --- Action Targets --

# Action: Turn everything on (State-based)
action_on() {
  log "Activating performance mode (Toggle ON)..."

  # Note: Audio Priority Boost and Screen Keep-Awake only work in wrapper mode
  # as they require the process to run within the inhibited context

  if is_active; then
    log "Already active, skipping (idempotent)"
    return 0
  fi

  # Set state active first to mark intent, then perform operations
  # If any operation fails, we clean up the state to maintain consistency
  set_state_active

  if ! performance_mode_enable "$TUNED_PATH"; then
    log "Failed to enable performance mode, cleaning up state"
    set_state_inactive
    return 1
  fi

  if ! niri_vrr_enable "$NIRI_OUTPUT"; then
    log "Failed to enable VRR, cleaning up state"
    set_state_inactive
    return 1
  fi

  if ! scx_load "$SCXCTL_PATH"; then
    log "Failed to load SCX scheduler, cleaning up state"
    set_state_inactive
    return 1
  fi
}

# Action: Turn everything off (State-based)
action_off() {
  log "Deactivating performance mode (Toggle OFF)..."

  if ! is_active; then
    log "Not active (no state file), but running cleanup anyway to ensure consistent state..."
    # Run cleanup anyway to handle cases where state file was lost but features are still enabled
    cleanup "$TUNED_PATH" "$SCXCTL_PATH" "$NIRI_OUTPUT"
    set_state_inactive
    return 0
  fi

  # Cleanup handles disabling everything
  cleanup "$TUNED_PATH" "$SCXCTL_PATH" "$NIRI_OUTPUT"
  set_state_inactive
}

# Action: Wrap a process
action_wrapper() {
  log "Running in Wrapper Mode..."

  # Set trap for cleanup on exit
  # We use global vars here so the trap handler can see them
  trap 'cleanup "$TUNED_PATH" "$SCXCTL_PATH" "$NIRI_OUTPUT"' EXIT

  # Enable performance mode if configured
  performance_mode_enable "$TUNED_PATH"

  # Enable VRR in Niri (if available)
  niri_vrr_enable "$NIRI_OUTPUT"

  # Enable SCX scheduler if configured
  scx_load "$SCXCTL_PATH"

  # Enable audio priority boost if configured
  [[ "$ENABLE_AUDIO_PRIORITY_BOOST" = "true" ]] && audio_priority_boost_enable

  # Get Steam environment wrapper if configured
  local steam_wrapper=""
  steam_wrapper=$(get_steam_env_wrapper)

  # Run the tool with screen keep-awake if configured
  if [[ "$ENABLE_SCREEN_KEEP_AWAKE" = "true" ]]; then
    if [[ -n "$steam_wrapper" ]]; then
      screen_keep_awake_enable "$INHIBIT_PATH" "$steam_wrapper" "$@"
    else
      screen_keep_awake_enable "$INHIBIT_PATH" "$@"
    fi
  else
    # No screen keep-awake, run with Steam wrapper if configured
    if [[ -n "$steam_wrapper" ]]; then
      exec "$steam_wrapper" "$@"
    else
      exec "$@"
    fi
  fi
}

# --- Main Execution ---

# Global paths needed for cleanup trap and actions
declare TUNED_PATH="" INHIBIT_PATH="" SCXCTL_PATH=""

main() {
  # Parse arguments
  if [[ $# -eq 0 ]]; then
    usage
  fi

  local mode="$1"
  local output_arg="${2:-}" # Optional output name (e.g., DP-1, HDMI-A-1)

  # Set NIRI_OUTPUT from env var, argument, or default (in priority order)
  if [[ -n "${NIRI_OUTPUT_NAME:-}" ]]; then
    NIRI_OUTPUT="$NIRI_OUTPUT_NAME" # Env var from niri-watcher.sh
  elif [[ -n "$output_arg" && "$mode" =~ ^(on|off)$ ]]; then
    NIRI_OUTPUT="$output_arg" # Command-line argument
  else
    NIRI_OUTPUT="$NIRI_OUTPUT_DEFAULT" # Default fallback
  fi

  # Get command paths and validate dependencies
  local command_paths
  readarray -t command_paths < <(get_command_paths)
  TUNED_PATH="${command_paths[0]}"
  INHIBIT_PATH="${command_paths[1]}"
  SCXCTL_PATH="${command_paths[2]}"

  case "$mode" in
  on)
    action_on
    ;;
  off)
    action_off
    ;;
  -h | --help)
    usage
    ;;
  *)
    # Not a keyword, assume it's a command to wrap
    action_wrapper "$@"
    ;;
  esac
}

main "$@"
