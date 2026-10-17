#!/usr/bin/env bash
set -euo pipefail

# Steam launcher in three shapes: plain desktop client, tenfoot (Big Picture
# direct), nested (gamescope wrapping Big Picture).
# Resolve symlinked installs (install.sh's ~/.local/bin links) via realpath.
if command -v realpath &>/dev/null; then
  scripts_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
else
  scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
fi
# shellcheck source=./gpu-detect.sh disable=SC1091
source "$scripts_dir/gpu-detect.sh"
# shellcheck source=./steam-shutdown.sh disable=SC1091
source "$scripts_dir/steam-shutdown.sh"

# ── Configuration ────────────────────────────────────────────────────────────

# How long another session is given to tear itself down before this launcher
# gives up on the lock. Bump to 15s if unrelated-process handoff becomes common.
LOCK_WAIT_TIMEOUT=5

# How many seconds a dead session's lock is held against before giving up.
ORPHAN_RECLAIM_TRIES=10

# ── Logging ──────────────────────────────────────────────────────────────────

MODE_TAG=beryl-steam
HAS_NOTIFY=false
command -v notify-send &>/dev/null && HAS_NOTIFY=true

log_info() { echo "[$MODE_TAG] $*" >&2; }
notify() {
  echo "[$MODE_TAG] $2" >&2
  $HAS_NOTIFY && notify-send -u "$1" "$MODE_TAG" "$2" 2>/dev/null || true
}
log_warn() { notify low "WARN: $*"; }
log_error() { notify critical "ERROR: $*"; }

# ── Session State ────────────────────────────────────────────────────────────

# One lock name per mode: detection, creation, and cleanup all go through here.
# Tolerating an unset XDG_RUNTIME_DIR keeps plain mode runnable; check_dependencies
# rejects it for the locking modes.
lock_path() { echo "${XDG_RUNTIME_DIR:-}/beryl-steam-$1.lock"; }

# ponytail: replacement matrix — each mode replaces any OTHER active type,
# but never its own (plain = steam running with no lock files present):
#            | plain | nested | tenfoot |
#   plain    |   ✗   |   ✓    |   ✓     |
#   nested   |   ✓   |   ✗    |   ✓     |
#   tenfoot  |   ✓   |   ✓    |   ✗     |
shutdown_if_allowed() {
  local mode="$1"

  is_steam_running || return 0

  local active_type=plain
  [[ -f "$(lock_path nested)" ]] && active_type=nested
  [[ -f "$(lock_path tenfoot)" ]] && active_type=tenfoot

  [[ $active_type == "$mode" ]] && return 0

  shutdown_steam_if_running
  cleanup_locks
}

cleanup_locks() {
  local mode
  for mode in nested tenfoot; do
    rm -f "$(lock_path "$mode")"
  done
}

# ── Dependency Checks ────────────────────────────────────────────────────────

check_dependencies() {
  local missing=()

  [[ -z ${XDG_RUNTIME_DIR:-} ]] && missing+=("XDG_RUNTIME_DIR (not set)")

  for cmd in flock pgrep pkill fuser; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if ((${#missing[@]})); then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ── Lock Management ──────────────────────────────────────────────────────────

# ponytail: single call site for all lock-file cleanup — plain, tenfoot, nested,
# and signal traps all converge here instead of each hardcoding paths.
acquire_lock() {
  exec 200>"$LOCK_FILE"

  flock -n 200 && return 0

  # Lock is held. If Steam is dead, the holder is an orphaned session: kill the
  # other holders so the lock can be reclaimed. fuser -k would also signal THIS
  # process (it holds fd 200 on the lock), so kill the other holders only.
  if ! is_steam_running; then
    log_warn "Orphaned session detected (Steam not running). Cleaning up..."
    for pid in $(fuser "$LOCK_FILE" 2>/dev/null); do
      [[ $pid == "$$" ]] && continue
      kill -9 "$pid" 2>/dev/null || true
    done
    for ((i = 0; i < ORPHAN_RECLAIM_TRIES; i++)); do
      if flock -n 200; then
        log_info "Lock reclaimed successfully"
        return 0
      fi
      sleep 1
    done
    log_error "Failed to reclaim lock after ${ORPHAN_RECLAIM_TRIES}s — run: fuser -k '$LOCK_FILE'"
    return 1
  fi

  log_info "Lock held by another session — waiting (${LOCK_WAIT_TIMEOUT}s timeout)..."
  flock -w "$LOCK_WAIT_TIMEOUT" 200 && return 0

  log_error "Could not acquire lock after ${LOCK_WAIT_TIMEOUT}s"
  return 1
}

# ── Signal Handling ──────────────────────────────────────────────────────────

STEAM_CHILD_PID=0

forward_signal() {
  local sig="$1"
  if ((STEAM_CHILD_PID > 0)); then
    log_info "Received SIG${sig}, initiating graceful Steam shutdown..."
    shutdown_steam_if_running
    cleanup_locks
  fi
  exit "$((128 + $(kill -l "$sig")))"
}

setup_signal_handlers() {
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
}

# ── Monitor Detection ────────────────────────────────────────────────────────

# Prints one token for the lit external display: tv (the living-room LG TV),
# dp (a DisplayPort monitor, no TV), none (neither), no-niri (compositor query
# unavailable). The LG TV is identified by its EDID model string because both a
# DP monitor and the TV can be lit at once, so connector order alone lies.
detect_external_display() {
  for cmd in niri jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_warn "$cmd not found; skipping monitor detection"
      echo no-niri
      return
    fi
  done

  local outputs="" token=""
  for _ in 1 2 3; do
    outputs="$(niri msg -j outputs 2>/dev/null)"
    token="$(jq -r '
      to_entries
      | map(select(.value.current_mode != null))
      | if any(.value.model | test("SSCR2|C1|OLED"; "i")) then "tv"
        elif any(.key | startswith("DP-")) then "dp"
        else "none" end
    ' <<<"$outputs" 2>/dev/null)"
    [[ "$token" != none ]] && break
    sleep 0.5
  done

  if [[ $token == none ]]; then
    local active
    active="$(jq -r '
      to_entries
      | map(select(.value.current_mode != null))
      | map("\(.key) [\(.value.model)]")
      | join(", ")
    ' <<<"$outputs" 2>/dev/null)"
    log_warn "No known monitor (active: ${active:-none}); using default gamescope args"
  fi
  echo "${token:-none}"
}

# ponytail: hybrid detection now comes from gpu-detect.sh (sysfs-based,
# "both GPUs drive a connected output"). Replaces the old vulkaninfo check.

# ── Command Building ─────────────────────────────────────────────────────────

# Pre-launch wrappers are appended as argv, so a scripts_dir containing spaces
# survives; a missing wrapper is reported rather than silently dropped.
add_wrapper() {
  local bin="$1"
  shift
  if ! command -v "$bin" &>/dev/null; then
    log_info "Skipping wrapper: $bin"
    return 0
  fi
  PRELAUNCH+=("$bin" "$@")
  log_info "Wrapper: $bin $*"
}

assemble_gamescope_args() {
  case "$(detect_external_display)" in
  no-niri) GAMESCOPE_ARGS=(-p fallback -e) ;;
  tv)
    GAMESCOPE_ARGS=(-p "tenfoot,hdr")
    LG_C1_CONNECTED=1
    log_info "Detected LG TV: HDR profile"
    ;;
  dp)
    GAMESCOPE_ARGS=(-p "tenfoot,hdr")
    log_info "Detected DP monitor (no TV): SDR profile"
    ;;
  *) GAMESCOPE_ARGS=(-p "tenfoot,hdr") ;;
  esac

  GAMESCOPE_ARGS+=("$@")
  detect_hybrid_graphics &>/dev/null && GAMESCOPE_ARGS+=(-p prime)
  GAMESCOPE_ARGS+=(--)
}

build_steam_command() {
  STEAM_CMD=(env "${STEAM_ENV_VARS[@]}")
  STEAM_CMD+=("${PRELAUNCH[@]}")
  if [[ -n ${GAMESCOPE_PATH:-} ]]; then
    STEAM_CMD+=("$GAMESCOPE_PATH" "${GAMESCOPE_ARGS[@]}")
  fi
  STEAM_CMD+=("$STEAM" "${STEAM_ARGS[@]}")
}

# ── Session Launch ───────────────────────────────────────────────────────────

launch_steam() {
  build_steam_command

  "${STEAM_CMD[@]}" &
  # ponytail: PID race window is ~1 instruction; signal between & and $! is
  # theoretically possible but practically unreachable for interactive use
  STEAM_CHILD_PID=$!

  wait
}

# ── Session Orchestration ────────────────────────────────────────────────────

run_session() {
  local mode="$1"
  LOCK_FILE="$(lock_path "$mode")"

  check_dependencies
  setup_signal_handlers

  shutdown_if_allowed "$mode"
  acquire_lock
  launch_steam
  cleanup_locks
}

run_plain() {
  shutdown_if_allowed plain
  build_steam_command
  exec "${STEAM_CMD[@]}"
}

# ── Main Execution ───────────────────────────────────────────────────────────

usage() {
  echo "Usage: beryl-steam.sh [tenfoot|nested] [-- <args>]" >&2
  exit 1
}

main() {
  local args=("$@")
  local mode=""

  # An optional mode word, then an optional "--", then launcher passthrough:
  # steam arguments in plain/tenfoot, gamescope arguments in nested. A first
  # word that is neither a mode nor "--" is a caller mistake, not passthrough.
  case "${args[0]:-}" in
  "" | --) ;;
  tenfoot | nested)
    mode="${args[0]}"
    args=("${args[@]:1}")
    ;;
  *) usage ;;
  esac
  if [[ ${args[0]:-} == -- ]]; then
    args=("${args[@]:1}")
  fi

  MODE_TAG=beryl-steam
  STEAM_ARGS=()
  STEAM_ENV_VARS=()
  PRELAUNCH=()
  GAMESCOPE_PATH=""
  GAMESCOPE_ARGS=()
  LG_C1_CONNECTED=0

  STEAM="$(command -v bazzite-steam.sh || \
    command -v bazzite-steam || \
    command -v steam)" || {
    log_error "Couldn't find 'steam'!"
    exit 1
  }

  # ponytail: single case block sets all mode-specific state AND dispatches.
  # No separate config phase; no duplicated mode matching; no intermediate vars.
  case "$mode" in
  "")
    # ponytail: extra args after `--` go to the outermost launcher — steam here,
    # gamescope in nested mode (see assemble_gamescope_args).
    STEAM_ARGS=("${args[@]}")
    run_plain
    ;;
  tenfoot)
    MODE_TAG=beryl-steam-tenfoot
    STEAM_ARGS+=(-tenfoot -pipewire "${args[@]}")
    add_wrapper gamemode --
    run_session tenfoot
    ;;
  nested)
    MODE_TAG=beryl-steam-nested
    STEAM_ARGS+=(-tenfoot -steamos3)
    GAMESCOPE_PATH="$(command -v nscb 2>/dev/null)" || {
      log_error "Missing gamescope dependency!"
      exit 1
    }
    assemble_gamescope_args "${args[@]}"
    if ((LG_C1_CONNECTED)); then
      add_wrapper "$scripts_dir/lgc1-wold.py" --
      add_wrapper "$scripts_dir/pactl_gate_sentinel.sh"
    fi
    add_wrapper gamemode --
    STEAM_ENV_VARS=(
      PROTON_ENABLE_WAYLAND=1
      IDLE_TIMEOUT=60
      ENABLE_SLEEP_INHIBIT=0
    )
    # ponytail: skip idle hooks if on_idle.sh isn't installed; the scheduler
    # gets no IDLE/ACTIVE command rather than a dead path.
    if command -v "$scripts_dir/on_idle.sh" &>/dev/null; then
      STEAM_ENV_VARS+=(
        IDLE_CMD="$scripts_dir/on_idle.sh idle"
        ACTIVE_CMD="$scripts_dir/on_idle.sh active"
      )
    else
      log_info "Skipping idle hooks: on_idle.sh not installed"
    fi
    run_session nested
    ;;
  *) usage ;;
  esac
}

main "$@"
