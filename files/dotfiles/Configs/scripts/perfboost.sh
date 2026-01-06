#!/usr/bin/env bash

# Configuration Section - Customize these variables to control script behavior
# Set to "true" to enable a feature, "false" to disable it
ENABLE_SCX_SCHEDULER="true"
ENABLE_PERFORMANCE_MODE="false"
ENABLE_SCREEN_KEEP_AWAKE="true"
ENABLE_AUDIO_PRIORITY_BOOST="false"

# SCX Scheduler Configuration
SCX_SCHEDULER_NAME="scx_bpfland" # Default SCX scheduler to use

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
  local dbus_send_path
  dbus_send_path="$(check_cmd "dbus-send")"

  # Validate dependencies based on configuration
  [[ "$ENABLE_PERFORMANCE_MODE" = "true" && -z "$tuned_path" ]] &&
    error_exit "Performance mode requires 'tuned-adm', but it's not installed or not in PATH"

  [[ "$ENABLE_SCREEN_KEEP_AWAKE" = "true" && -z "$inhibit_path" ]] &&
    error_exit "Screen keep-awake requires 'systemd-inhibit', but it's not installed or not in PATH"

  # Always validate dbus-send since we use it for SCX scheduler management
  [[ -z "$dbus_send_path" ]] &&
    error_exit "SCX scheduler management requires 'dbus-send', but it's not installed or not in PATH"

  # Output paths: tuned_path, inhibit_path, dbus_send_path
  printf "%s\n" "$tuned_path" "$inhibit_path" "$dbus_send_path"
}

# SCX Scheduler Functions
scx_load() {
  local dbus_send_path="$1"

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
  "$dbus_send_path" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.SwitchScheduler string:"$scx" uint32:1
}

scx_unload() {
  local dbus_send_path="$1"

  [[ -z "$dbus_send_path" ]] && return

  log "Unloading SCX scheduler"
  "$dbus_send_path" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.StopScheduler
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
  local dbus_send_path="$2"

  log "Running cleanup..."
  performance_mode_disable "$tuned_path"
  scx_unload "$dbus_send_path"
}

# Main function
main() {
  # Get command paths and validate dependencies
  local command_paths
  readarray -t command_paths < <(get_command_paths)
  local tuned_path="${command_paths[0]}"
  local inhibit_path="${command_paths[1]}"
  local dbus_send_path="${command_paths[2]}"

  # Store paths in global variables for trap handler
  PERFBOOST_TUNED_PATH="$tuned_path"
  PERFBOOST_DBUS_SEND_PATH="$dbus_send_path"

  # Set trap for cleanup on exit
  trap 'cleanup "$PERFBOOST_TUNED_PATH" "$PERFBOOST_DBUS_SEND_PATH"' EXIT

  # Enable performance mode if configured
  performance_mode_enable "$tuned_path"

  # Enable SCX scheduler if configured
  scx_load "$dbus_send_path"

  # Enable audio priority boost if configured
  [[ "$ENABLE_AUDIO_PRIORITY_BOOST" = "true" ]] && audio_priority_boost_enable

  # Run the tool with screen keep-awake if configured
  if [[ "$ENABLE_SCREEN_KEEP_AWAKE" = "true" ]]; then
    screen_keep_awake_enable "$inhibit_path" "$@"
  else
    # No screen keep-awake, just run the command with any enabled environment
    exec "$@"
  fi
}

# Run main function with all arguments
main "$@"
