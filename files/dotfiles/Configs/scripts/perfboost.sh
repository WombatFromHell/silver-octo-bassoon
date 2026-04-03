#!/usr/bin/env bash
#
# perfboost.sh — Performance toggle for gaming sessions
# Refactored: composability, simplicity, separation of concerns
#

set -euo pipefail

# ============================================================================
# Module: Configuration
# Responsibility: Load and expose configuration values
# ============================================================================

config_load() {
  # Feature toggles (env-overridable)
  readonly ENABLE_SCX="${ENABLE_SCX_SCHEDULER:=true}"
  readonly ENABLE_TUNED="${ENABLE_PERFORMANCE_MODE:=false}"
  readonly ENABLE_INHIBIT="${ENABLE_SCREEN_KEEP_AWAKE:=true}"
  readonly ENABLE_AUDIO="${ENABLE_AUDIO_PRIORITY_BOOST:=false}"
  readonly ENABLE_STEAM="${ENABLE_STEAM_ENV:=true}"

  # Feature parameters
  readonly SCX_NAME="${SCX_SCHEDULER_NAME:=scx_lavd}"
  readonly SCX_ARGS="${SCX_SCHEDULER_ARGS:=--performance --preempt-shift 6 --slice-min-us 500}"
  readonly PROFILE_GAME="${GAME_PROFILE:=throughput-performance-bazzite}"
  readonly PROFILE_DESKTOP="${DESKTOP_PROFILE:=balanced-bazzite}"
  readonly AUDIO_LATENCY="${PULSE_LATENCY_MSEC:=60}"
  readonly STEAM_SCRIPT="${STEAM_ENV_SCRIPT:=$HOME/.local/bin/scripts/steam-env-base.sh}"
  readonly OUTPUT_DEFAULT="${NIRI_OUTPUT_DEFAULT:=DP-1}"

  # Runtime state
  readonly STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/perfboost"
  readonly STATE_FILE="${STATE_DIR}/active.state"
}

# ============================================================================
# Module: Logging
# Responsibility: Structured log output
# ============================================================================

log_info() { echo "[perfboost] INFO: $*"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[perfboost] DEBUG: $*" || true; }
log_error() { echo "[perfboost] ERROR: $*" >&2; }

# ============================================================================
# Module: State Management
# Responsibility: Persist and query activation state
# ============================================================================

state_init() { mkdir -p "$STATE_DIR"; }
state_active() { [[ -f "$STATE_FILE" && "$(cat "$STATE_FILE" 2>/dev/null)" == "active" ]]; }
state_mark() { echo "active" >"$STATE_FILE"; }
state_clear() { rm -f "$STATE_FILE"; }

# ============================================================================
# Module: Dependency Resolution
# Responsibility: Locate commands, report missing deps
# ============================================================================

require_cmd() {
  local cmd="$1" feature="${2:-}"
  command -v "$cmd" &>/dev/null || {
    [[ -n "$feature" ]] && log_error "$feature requires '$cmd' (not found)"
    return 1
  }
}

# ============================================================================
# Module: Output Resolution
# Responsibility: Determine target niri output name
# ============================================================================

output_resolve() {
  local -r mode="$1" arg="${2:-}"

  # Priority: env var > positional arg (for on/off) > default
  if [[ -n "${NIRI_OUTPUT_NAME:-}" ]]; then
    echo "$NIRI_OUTPUT_NAME"
  elif [[ "$mode" =~ ^(on|off)$ && -n "$arg" ]]; then
    echo "$arg"
  else
    echo "$OUTPUT_DEFAULT"
  fi
}

# ============================================================================
# Module: VRR (niri)
# Responsibility: Toggle VRR on specified output
# ============================================================================

vrr_current() {
  local -r output="$1"
  local niri
  niri=$(command -v niri) || {
    log_error "VRR requires 'niri'"
    return 2
  }

  local vrr_enabled
  vrr_enabled=$("$niri" msg -j outputs 2>/dev/null | jq -r --arg o "$output" '.[$o].vrr_enabled' 2>/dev/null) || return 0

  if [[ "$vrr_enabled" == "true" ]]; then
    echo "on"
  elif [[ "$vrr_enabled" == "false" ]]; then
    echo "off"
  else
    echo ""
  fi
}

vrr_set() {
  local -r output="$1" state="$2"
  local niri
  niri=$(command -v niri) || {
    log_error "VRR requires 'niri'"
    return 1
  }
  "$niri" msg output "$output" vrr "$state"
}

vrr_ensure() {
  local -r output="$1" desired="$2"
  local current
  current=$(vrr_current "$output") || return 0

  [[ -z "$current" ]] && {
    log_debug "Output '$output' not found, skipping VRR"
    return 0
  }
  [[ "$current" == "$desired" ]] && {
    log_debug "VRR $desired on $output (no change)"
    return 0
  }

  log_info "VRR: $current → $desired on $output"
  vrr_set "$output" "$desired"
}

vrr_on() { vrr_ensure "$1" "on"; }
vrr_off() { vrr_ensure "$1" "off"; }

# ============================================================================
# Module: Power Profile (tuned-adm)
# Responsibility: Switch system power profiles
# ============================================================================

tuned_current() {
  require_cmd tuned-adm "Performance mode" || return 2
  tuned-adm active 2>/dev/null | grep -oP '(?<=Active profile: ).*' || echo ""
}

tuned_set() {
  local -r profile="$1"
  require_cmd tuned-adm "Performance mode" || return 1
  tuned-adm profile "$profile"
}

tuned_ensure() {
  local -r desired="$1"
  [[ "$ENABLE_TUNED" != "true" ]] && return 0

  local current
  current=$(tuned_current) || return 0

  [[ "$current" == "$desired" ]] && {
    log_debug "Profile $desired (no change)"
    return 0
  }
  log_info "Profile: $current → $desired"
  tuned_set "$desired"
}

tuned_game() { tuned_ensure "$PROFILE_GAME"; }
tuned_desktop() { tuned_ensure "$PROFILE_DESKTOP"; }

# ============================================================================
# Module: SCX Scheduler
# Responsibility: Manage scxctl scheduler lifecycle
# ============================================================================

scx_status() {
  require_cmd scxctl "SCX scheduler" || return 2
  scxctl get 2>/dev/null || echo ""
}

scx_ensure_loaded() {
  [[ "$ENABLE_SCX" != "true" ]] && return 0
  require_cmd scxctl "SCX scheduler" || return 0
  require_cmd "$SCX_NAME" "SCX scheduler" || return 0

  local status
  status=$(scx_status) || return 0

  if [[ -z "$status" || "$status" == *"no scx scheduler running"* ]]; then
    log_info "SCX: loading $SCX_NAME"
    scxctl start -s "$SCX_NAME" -a="$SCX_ARGS"
  elif [[ "$status" == *"$SCX_NAME"* ]]; then
    log_debug "SCX: $SCX_NAME already loaded"
  else
    log_info "SCX: switching $status → $SCX_NAME"
    scxctl switch -s "$SCX_NAME" -a="$SCX_ARGS"
  fi
}

scx_unload() {
  [[ "$ENABLE_SCX" != "true" ]] && return 0
  require_cmd scxctl "SCX scheduler" || return 0

  scx_status &>/dev/null || {
    log_debug "SCX: not loaded"
    return 0
  }
  log_info "SCX: unloading"
  scxctl stop
}

# ============================================================================
# Module: Audio Priority
# Responsibility: Set audio latency environment variable
# ============================================================================

audio_configure() {
  [[ "$ENABLE_AUDIO" != "true" ]] && return 0
  log_debug "Audio: PULSE_LATENCY_MSEC=$AUDIO_LATENCY"
  export PULSE_LATENCY_MSEC="$AUDIO_LATENCY"
}

# ============================================================================
# Module: Steam Environment
# Responsibility: Provide optional Steam wrapper script path
# ============================================================================

steam_wrapper_path() {
  [[ "$ENABLE_STEAM" != "true" ]] && return 1
  [[ -x "$STEAM_SCRIPT" ]] && echo "$STEAM_SCRIPT" && return 0
  return 1
}

# ============================================================================
# Module: Screen Inhibit
# Responsibility: Run command with idle/sleep inhibition
# ============================================================================

inhibit_is_kde() {
  [[ "${XDG_SESSION_DESKTOP:-}${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]
}

inhibit_run() {
  [[ "$ENABLE_INHIBIT" != "true" ]] && {
    exec "$@"
    return
  }

  local inhibit
  inhibit=$(command -v systemd-inhibit) || {
    exec "$@"
    return
  }

  local -a cmd=("$inhibit" --what=idle:sleep --mode=block --why="perfboost.sh" --)

  if inhibit_is_kde; then
    local kde_inhibit
    if kde_inhibit=$(command -v kde-inhibit); then
      log_debug "Using kde-inhibit for color correction"
      cmd+=("$kde_inhibit" --colorCorrect)
    else
      log_debug "kde-inhibit not available, skipping color correction"
    fi
  fi

  exec "${cmd[@]}" "$@"
}

# ============================================================================
# Module: Feature Orchestration
# Responsibility: Coordinate feature enable/disable operations
# ============================================================================

features_enable() {
  local -r output="$1"
  log_debug "Enabling features for output: $output"

  tuned_game
  vrr_on "$output"
  scx_ensure_loaded
  audio_configure
}

features_disable() {
  local -r output="$1"
  log_debug "Disabling features for output: $output"

  tuned_desktop
  vrr_off "$output"
  scx_unload
}

# ============================================================================
# Module: Actions
# Responsibility: Implement user-facing commands
# ============================================================================

action_on() {
  local -r output="$1"
  log_info "Activating (output: $output)"

  state_active && {
    log_info "Already active (idempotent)"
    return 0
  }

  state_init
  state_mark

  features_enable "$output" || {
    state_clear
    return 1
  }
  log_info "Activation complete"
}

action_off() {
  local -r output="$1"
  log_info "Deactivating (output: $output)"

  # Always cleanup to handle orphaned state
  features_disable "$output"
  state_clear
}

action_wrapper() {
  local -r output="$1"
  shift # Remove output; remaining args are the command to execute

  log_info "Wrapper mode (output: $output, command: $*)"

  # Setup cleanup trap
  trap 'features_disable "$output"' EXIT INT TERM

  # Enable features before exec
  features_enable "$output"

  # Build execution chain: [steam_wrapper] + user_command
  local -a exec_cmd=()
  steam_wrapper_path && exec_cmd+=("$(steam_wrapper_path)")
  exec_cmd+=("$@")

  # Execute with or without inhibition
  if [[ "$ENABLE_INHIBIT" == "true" ]]; then
    inhibit_run "${exec_cmd[@]}"
  else
    exec "${exec_cmd[@]}"
  fi
}

# ============================================================================
# Module: Validation
# Responsibility: Verify required dependencies for enabled features
# ============================================================================

validate_deps() {
  local missing=()

  [[ "$ENABLE_TUNED" == "true" ]] && ! command -v tuned-adm &>/dev/null && missing+=("tuned-adm")
  [[ "$ENABLE_INHIBIT" == "true" ]] && ! command -v systemd-inhibit &>/dev/null && missing+=("systemd-inhibit")
  [[ "$ENABLE_SCX" == "true" ]] && ! command -v scxctl &>/dev/null && missing+=("scxctl")

  ((${#missing[@]} == 0)) && return 0

  log_error "Missing dependencies: ${missing[*]}"
  return 1
}

# ============================================================================
# Module: CLI Parser
# Responsibility: Parse arguments and route to actions
# ============================================================================

cli_parse() {
  (($# == 0)) && {
    echo "Usage: perfboost.sh {on|off|<command>} [output] [args...]"
    return 1
  }

  local -r mode="$1"
  local -r output_arg="${2:-}"

  # Route based on mode
  case "$mode" in
  on)
    local output
    output=$(output_resolve "$mode" "$output_arg")
    action_on "$output"
    ;;
  off)
    local output
    output=$(output_resolve "$mode" "$output_arg")
    action_off "$output"
    ;;
  *)
    # Wrapper mode: mode is first arg of wrapped command
    local output
    output=$(output_resolve "wrapper" "$output_arg")
    action_wrapper "$output" "$mode" "$@"
    ;;
  esac
}

# ============================================================================
# Entry Point
# ============================================================================

main() {
  config_load
  validate_deps || exit 1
  cli_parse "$@"
}

main "$@"
