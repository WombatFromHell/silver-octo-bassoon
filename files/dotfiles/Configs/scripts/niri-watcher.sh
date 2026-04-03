#!/usr/bin/env bash
#
# niri-watcher.sh — Auto-enable VRR for fullscreen applications in niri
#
set -euo pipefail

# ============================================================================
# Configuration (override via environment)
# ============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly POLL_INTERVAL="${NIRI_VRR_POLL_INTERVAL:-2}"
readonly LOG_FILE="${NIRI_VRR_LOG_FILE:-${XDG_RUNTIME_DIR:-/tmp}/niri-watcher.log}"
readonly STARTUP_DELAY="${NIRI_VRR_STARTUP_DELAY:-3}"
readonly DEBUG_MODE="${NIRI_VRR_DEBUG:-0}"
readonly RELAXED_MODE="${NIRI_VRR_RELAXED_MODE:-0}" # 1 = skip GPU/3D checks

# Hook commands
declare -a HOOK_ON=(
  "$HOME/.local/bin/scripts/perfboost.sh on"
)
declare -a HOOK_OFF=(
  "$HOME/.local/bin/scripts/perfboost.sh off"
)

declare -a EXCLUDED_APPS=(
  "brave-browser"
  "brave-browser-beta"
  "org.mozilla.firefox"
  "org.kde.haruna"
  "mpv" "io.mpv.Mpv"
  "com.spotify.Client"
  "vesktop"
  "com.discordapp.Discord"
)

# ============================================================================
# Global State
# ============================================================================
declare -A VRR_CURRENT_STATE=()
declare -A GPU_ACTIVE_PIDS=()
declare -a GPU_LEAF_PIDS=()
declare -A OUTPUT_CURRENT_APP=()

# ============================================================================
# Logging
# ============================================================================
log() { printf '%s [%s] %s: %s\n' "$(date '+%F %T')" "$1" "$SCRIPT_NAME" "${*:2}" >>"${LOG_FILE}"; }
log_info() { log "INFO" "$@"; }
log_debug() {
  if ((DEBUG_MODE == 1)); then
    log "DEBUG" "$@"
  fi
}
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ============================================================================
# Dependency Checking
# ============================================================================
check_dependencies() {
  local missing=()
  for cmd in jq niri; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  # nvtop only needed if not in relaxed mode
  if [[ "$RELAXED_MODE" != "1" ]]; then
    command -v nvtop &>/dev/null || missing+=("nvtop")
  fi
  if ((${#missing[@]} > 0)); then
    log_error "Missing required commands: ${missing[*]}"
    echo "Error: Missing: ${missing[*]}" >&2
    return 1
  fi
}

# ============================================================================
# Data Fetchers (Pure)
# ============================================================================
fetch_niri_outputs() { niri msg -j outputs 2>/dev/null || echo '{}'; }
fetch_niri_windows() { niri msg -j windows 2>/dev/null || echo '[]'; }
fetch_niri_workspaces() { niri msg -j workspaces 2>/dev/null || echo '[]'; }
fetch_gpu_pids() { nvtop -s 2>/dev/null | jq -r '.[].processes[]? | select(.kind == "graphic & compute") | .pid | select(. != null)' 2>/dev/null || true; }

# ============================================================================
# Data Parsers (Pure — transform JSON → TSV streams)
# ============================================================================

# Parse workspace → output mappings from workspaces JSON
# Input:  workspaces JSON array
# Output: TSV lines of "workspace_id\toutput_name"
parse_workspace_outputs() {
  jq -r '
    .[] | [
      (.id | tostring),
      (.output // "")
    ] | select(.[1] != "") | @tsv
  ' <<<"$1" 2>/dev/null || true
}

# Parse output names and dimensions from outputs JSON
# Input:  outputs JSON object (keyed by output name)
# Output: TSV lines of "output_name\twidth\theight"
parse_output_dimensions() {
  jq -r '
    to_entries[] | [
      .key,
      ((try .value.modes[.value.current_mode].width catch null) // .value.modes[0].width // ""),
      ((try .value.modes[.value.current_mode].height catch null) // .value.modes[0].height // "")
    ] | select(.[1] != "" and .[2] != "") | @tsv
  ' <<<"$1" 2>/dev/null || true
}

# Parse a single window object into TSV fields
# Input:  single window JSON object (via $1)
# Output: TSV line of "app_id\tpid\tworkspace_id\ttile_w\ttile_h\twin_w\twin_h\tis_focused"
parse_window_fields() {
  jq -r '
    [
      (.app_id // ""),
      (.pid // "" | tostring),
      (.workspace_id // "" | tostring),
      (.layout.tile_size[0] // ""),
      (.layout.tile_size[1] // ""),
      (.layout.window_size[0] // ""),
      (.layout.window_size[1] // ""),
      (.is_focused // false | tostring)
    ] | @tsv
  ' <<<"$1" 2>/dev/null || true
}

# Parse all windows into TSV (batch alternative to per-window parse_window_fields)
# Input:  windows JSON array
# Output: TSV lines (same fields as parse_window_fields)
parse_all_windows_tsv() {
  jq -r '
    .[] | [
      (.app_id // ""),
      (.pid // "" | tostring),
      (.workspace_id // "" | tostring),
      (.layout.tile_size[0] // ""),
      (.layout.tile_size[1] // ""),
      (.layout.window_size[0] // ""),
      (.layout.window_size[1] // ""),
      (.is_focused // false | tostring)
    ] | @tsv
  ' <<<"$1" 2>/dev/null || true
}

# ============================================================================
# Business Logic Evaluators
# ============================================================================
is_app_excluded() {
  local app_id="$1"
  for excluded in "${EXCLUDED_APPS[@]}"; do
    [[ "$app_id" == "$excluded" ]] && return 0
  done
  return 1
}

is_window_fullscreen() {
  local win_w="$1" win_h="$2" out_w="$3" out_h="$4"
  [[ -n "$win_w" && -n "$win_h" && "$win_w" == "$out_w" && "$win_h" == "$out_h" ]]
}

get_window_dimensions() {
  local tile_w="${1%%.*}" tile_h="${2%%.*}" win_w="${3%%.*}" win_h="${4%%.*}"
  if [[ -n "$tile_w" && -n "$tile_h" ]]; then
    echo "$tile_w $tile_h"
  elif [[ -n "$win_w" && -n "$win_h" ]]; then
    echo "$win_w $win_h"
  fi
}

is_pid_gpu_active() { [[ -n "${GPU_ACTIVE_PIDS[$1]:-}" ]]; }

has_any_gpu_activity() { ((${#GPU_LEAF_PIDS[@]} > 0)); }

# ============================================================================
# GPU PID Management
# ============================================================================
build_gpu_pid_ancestor_set() {
  GPU_ACTIVE_PIDS=()
  GPU_LEAF_PIDS=()
  local leaf_pid
  while IFS= read -r leaf_pid; do
    [[ -z "$leaf_pid" || "$leaf_pid" == "null" ]] && continue
    GPU_LEAF_PIDS+=("$leaf_pid")
    local current="$leaf_pid"
    while [[ -n "$current" && "$current" != "1" && "$current" != "0" ]]; do
      GPU_ACTIVE_PIDS["$current"]=1
      local ppid
      ppid=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d '[:space:]') || break
      [[ -z "$ppid" ]] && break
      current="$ppid"
    done
  done
  log_debug "GPU PID map: ${#GPU_ACTIVE_PIDS[@]} ancestors, ${#GPU_LEAF_PIDS[@]} leaves"
}

get_first_gpu_pid() {
  for pid in "${!GPU_ACTIVE_PIDS[@]}"; do
    echo "$pid"
    return 0
  done
  echo ""
}

# ============================================================================
# Window Evaluation
# ============================================================================
evaluate_window_for_vrr() {
  local app_id="$1" pid="$2" ws_id="$3" tile_w="$4" tile_h="$5" win_w="$6" win_h="$7" is_focused="$8"
  local -n ws_to_out_ref="$9"
  local -n out_dims_ref="${10}"

  [[ "$is_focused" != "true" ]] && return 1

  local output="${ws_to_out_ref[$ws_id]:-}"
  [[ -z "$output" ]] && return 1

  if [[ -n "$app_id" ]] && is_app_excluded "$app_id"; then
    log_debug "⊘ Excluded: $app_id"
    return 1
  fi

  local dims="${out_dims_ref[$output]:-}"
  [[ -z "$dims" ]] && return 1
  IFS='x' read -r out_w out_h <<<"$dims"

  local win_dims
  win_dims=$(get_window_dimensions "$tile_w" "$tile_h" "$win_w" "$win_h")
  [[ -z "$win_dims" ]] && return 1
  read -r check_w check_h <<<"$win_dims"

  if ! is_window_fullscreen "$check_w" "$check_h" "$out_w" "$out_h"; then
    return 1
  fi

  # GPU Activity Check
  if [[ "$RELAXED_MODE" != "1" ]]; then
    if [[ -z "$pid" || "$pid" == "null" ]]; then
      has_any_gpu_activity || return 1
      log_debug "✓ GPU activity (relaxed fallback): $app_id"
    elif ! is_pid_gpu_active "$pid"; then
      has_any_gpu_activity || return 1
      log_debug "✓ GPU activity (Steam/Proton fallback): $app_id"
    fi
  else
    log_debug "✓ Fullscreen (relaxed mode): $app_id"
  fi

  echo "$output"
  return 0
}

# ============================================================================
# State Application & Hooks
# ============================================================================
execute_hook() {
  local -r hook_spec="$1" output_name="$2" app_pid="${3:-}"
  [[ -z "$hook_spec" ]] && return 0
  read -r -a parts <<<"$hook_spec"
  local cmd="${parts[0]}"
  local -a args=("${parts[@]:1}")
  [[ -x "$cmd" ]] || {
    log_warn "Hook not executable: $cmd"
    return 1
  }
  log_info "Executing hook: $hook_spec"
  (
    export NIRI_OUTPUT_NAME="$output_name" NIRI_APP_PID="$app_pid"
    exec "$cmd" "${args[@]+"${args[@]}"}"
  ) &
}

apply_vrr_state() {
  local output="$1" desired="$2"
  local prev="${VRR_CURRENT_STATE[$output]:-off}"
  [[ "$desired" == "$prev" ]] && return 0

  if [[ "$desired" == "on" ]]; then
    log_info "Enabling VRR on $output"
    niri msg output "$output" vrr on 2>/dev/null || {
      log_warn "Failed to enable VRR on $output"
      return 1
    }
    execute_hook "${HOOK_ON[0]}" "$output" "$(get_first_gpu_pid)"
  else
    log_info "Disabling VRR on $output"
    niri msg output "$output" vrr off 2>/dev/null || {
      log_warn "Failed to disable VRR on $output"
      return 1
    }
    execute_hook "${HOOK_OFF[0]}" "$output"
    unset "OUTPUT_CURRENT_APP[$output]" 2>/dev/null || true
  fi
  VRR_CURRENT_STATE["$output"]="$desired"
}

# ============================================================================
# Main Orchestrator (Collect → Parse → Decide → Act)
# ============================================================================

# Module-level working arrays (populated by parse phase, consumed by decide phase)
declare -A _WS_TO_OUTPUT=()
declare -A _OUTPUT_DIMENSIONS=()
declare -a _WINDOWS_TSV=()

# Phase 1+2: Collect & Parse — gather JSON and transform into working arrays
# (Combined to avoid serialization issues with null bytes in command substitution)
collect_and_parse() {
  local outputs_json windows_json workspaces_json

  outputs_json="$(fetch_niri_outputs)"
  windows_json="$(fetch_niri_windows)"
  workspaces_json="$(fetch_niri_workspaces)"

  _WS_TO_OUTPUT=()
  _OUTPUT_DIMENSIONS=()
  _WINDOWS_TSV=()

  while IFS=$'\t' read -r ws_id output_name; do
    [[ -n "$ws_id" && -n "$output_name" && "$ws_id" != "null" ]] || continue
    _WS_TO_OUTPUT["$ws_id"]="$output_name"
  done < <(parse_workspace_outputs "$workspaces_json")

  while IFS=$'\t' read -r name width height; do
    [[ -n "$name" && -n "$width" && -n "$height" ]] || continue
    _OUTPUT_DIMENSIONS["$name"]="${width%%.*}x${height%%.*}"
  done < <(parse_output_dimensions "$outputs_json")

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _WINDOWS_TSV+=("$line")
  done < <(parse_all_windows_tsv "$windows_json")

  log_debug "Parsed: ${#_WS_TO_OUTPUT[@]} ws, ${#_OUTPUT_DIMENSIONS[@]} outs, ${#_WINDOWS_TSV[@]} wins"
}

# Phase 3: Decide — evaluate which outputs need VRR on
# Writes results into DESIRED_VRR (declared in evaluate_all_outputs scope)
decide_vrr_state() {
  local output
  for output in "${!_OUTPUT_DIMENSIONS[@]}"; do
    DESIRED_VRR["$output"]="off"
  done

  local tsv_line app_id pid ws_id tile_w tile_h win_w win_h is_focused target_output
  for tsv_line in "${_WINDOWS_TSV[@]+"${_WINDOWS_TSV[@]}"}"; do
    IFS=$'\t' read -r app_id pid ws_id tile_w tile_h win_w win_h is_focused <<<"$tsv_line"
    [[ -z "$app_id" && -z "$pid" ]] && continue

    if target_output=$(evaluate_window_for_vrr \
      "$app_id" "$pid" "$ws_id" \
      "$tile_w" "$tile_h" "$win_w" "$win_h" "$is_focused" \
      _WS_TO_OUTPUT _OUTPUT_DIMENSIONS); then

      DESIRED_VRR["$target_output"]="on"
      local app_key="$app_id:$pid"
      if [[ "${OUTPUT_CURRENT_APP[$target_output]:-}" != "$app_key" ]]; then
        log_info "🎮 Fullscreen: $app_id (PID $pid) on $target_output"
        OUTPUT_CURRENT_APP["$target_output"]="$app_key"
      fi
    fi
  done
}

# Phase 4: Act — apply VRR state changes to niri
# Reads results from DESIRED_VRR (declared in evaluate_all_outputs scope)
apply_vrr_decisions() {
  local output

  for output in "${!DESIRED_VRR[@]}"; do
    apply_vrr_state "$output" "${DESIRED_VRR[$output]}" || true
  done

  # Cleanup disconnected outputs
  for output in "${!VRR_CURRENT_STATE[@]}"; do
    if [[ -z "${DESIRED_VRR[$output]:-}" ]]; then
      log_info "Output $output disconnected, cleaning state"
      unset "VRR_CURRENT_STATE[$output]" "OUTPUT_CURRENT_APP[$output]" 2>/dev/null || true
    fi
  done
}

# Top-level orchestrator (delegates to phase functions)
evaluate_all_outputs() {
  collect_and_parse

  local -A DESIRED_VRR=()
  decide_vrr_state
  apply_vrr_decisions
}

# ============================================================================
# Adaptive Sleep & Main
# ============================================================================
adaptive_sleep() {
  local cycle_start_ms="$1"
  local target_ms=$((POLL_INTERVAL * 1000))
  local now_ms=$(($(date +%s%N) / 1000000))
  local sleep_ms=$((target_ms - (now_ms - cycle_start_ms)))
  if ((sleep_ms > 100)); then
    sleep "$(awk "BEGIN{printf \"%.3f\", $sleep_ms/1000}")" 2>/dev/null || sleep "$POLL_INTERVAL"
  else
    sleep "$POLL_INTERVAL"
  fi
}

cleanup() {
  log_info "Shutting down..."
  for output in "${!VRR_CURRENT_STATE[@]}"; do
    niri msg output "$output" vrr off 2>/dev/null || true
  done
  exit 0
}

main() {
  : >"${LOG_FILE}"
  log_info "Starting $SCRIPT_NAME (debug=$DEBUG_MODE, relaxed=$RELAXED_MODE)"
  check_dependencies || exit 1

  log_info "Waiting ${STARTUP_DELAY}s for niri..."
  sleep "$STARTUP_DELAY"
  trap cleanup SIGINT SIGTERM
  log_info "Monitoring active (interval: ${POLL_INTERVAL}s)"

  while true; do
    local cycle_start_ms
    cycle_start_ms=$(($(date +%s%N) / 1000000))

    if [[ "$RELAXED_MODE" != "1" ]]; then
      build_gpu_pid_ancestor_set < <(fetch_gpu_pids)
    fi

    evaluate_all_outputs
    adaptive_sleep "$cycle_start_ms"
  done
}

main "$@"
