#!/usr/bin/env bash

# Configuration Section - Customize these variables to control script behavior
# Set to "true" to enable a feature, "false" to disable it
ENABLE_SCX_SCHEDULER="true"
ENABLE_PERFORMANCE_MODE="false"
ENABLE_SCREEN_KEEP_AWAKE="true"
ENABLE_AUDIO_PRIORITY_BOOST="false"
ENABLE_STEAM_ENV="true"

# SCX Scheduler Configuration
# SCX_SCHEDULER_NAME="scx_bpfland" # Default SCX scheduler to use
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

# Global State (minimal - only what's truly needed across functions)
# Most variables are now localized to their functions

# Logging function for better debugging
log() {
  echo "[perfboost.sh] $1"
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

  # Validate scxctl for SCX scheduler management
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
    return
  }

  local scx="${SCX_SCHEDULER_NAME}"
  local SCXS
  SCXS="$(check_cmd "$scx")"

  [[ -z "$SCXS" ]] && {
    log "Error: '$scx' not found, skipping SCX scheduler..."
    return
  }

  log "Loading SCX scheduler: $scx"
  "$scxctl_path" start -s "$SCX_SCHEDULER_NAME" -a="${SCX_SCHEDULER_ARGS[*]}"
}

scx_unload() {
  local scxctl_path="$1"

  [[ "$ENABLE_SCX_SCHEDULER" != "true" ]] && return
  [[ -z "$scxctl_path" ]] && return

  log "Unloading SCX scheduler"
  "$scxctl_path" stop
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

  log "Enabling performance mode: $GAME_PROFILE"
  "$tuned_path" profile "$GAME_PROFILE"
}

performance_mode_disable() {
  local tuned_path="$1"

  [[ "$ENABLE_PERFORMANCE_MODE" != "true" ]] && return
  [[ -z "$tuned_path" ]] && return

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

  local kde_inhibit
  kde_inhibit="$(check_cmd "kde-inhibit")"

  [[ -z "$kde_inhibit" ]] &&
    log "kde-inhibit not available, skipping KDE color correction"

  log "Enabling screen keep-awake and disabling KDE color correction"
  # Audio priority boost is handled via exported environment variable
  "$inhibit_path" --why "perfboost.sh is running" -- \
    "$kde_inhibit" --colorCorrect "$@"
}

# Cleanup function
cleanup() {
  local tuned_path="$1"
  local scxctl_path="$2"

  log "Running cleanup..."
  performance_mode_disable "$tuned_path"
  scx_unload "$scxctl_path"
}

# Main function
main() {
  # Get command paths and validate dependencies
  local command_paths
  readarray -t command_paths < <(get_command_paths)
  local tuned_path="${command_paths[0]}"
  local inhibit_path="${command_paths[1]}"
  local scxctl_path="${command_paths[2]}"

  # Store paths in global variables for trap handler
  PERFBOOST_TUNED_PATH="$tuned_path"
  PERFBOOST_SCXCTL_PATH="$scxctl_path"

  # Set trap for cleanup on exit
  trap 'cleanup "$PERFBOOST_TUNED_PATH" "$PERFBOOST_SCXCTL_PATH"' EXIT

  # Enable performance mode if configured
  performance_mode_enable "$tuned_path"

  # Enable SCX scheduler if configured
  scx_load "$scxctl_path"

  # Enable audio priority boost if configured
  [[ "$ENABLE_AUDIO_PRIORITY_BOOST" = "true" ]] && audio_priority_boost_enable

  # Get Steam environment wrapper if configured
  local steam_wrapper=""
  steam_wrapper=$(get_steam_env_wrapper)

  # Run the tool with screen keep-awake if configured
  if [[ "$ENABLE_SCREEN_KEEP_AWAKE" = "true" ]]; then
    if [[ -n "$steam_wrapper" ]]; then
      screen_keep_awake_enable "$inhibit_path" "$steam_wrapper" "$@"
    else
      screen_keep_awake_enable "$inhibit_path" "$@"
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

# Run main function with all arguments
main "$@"
