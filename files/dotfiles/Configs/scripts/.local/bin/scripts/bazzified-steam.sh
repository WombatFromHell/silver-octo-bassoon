#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

STEAM_SHUTDOWN_TIMEOUT="${STEAM_SHUTDOWN_TIMEOUT:-10}"

# ── Logging ──────────────────────────────────────────────────────────────────

HAS_NOTIFY=false
command -v notify-send &>/dev/null && HAS_NOTIFY=true

log_info() { echo "[$MODE_TAG] $*" >&2; }
log_warn() {
  echo "[$MODE_TAG] WARN: $*" >&2
  $HAS_NOTIFY && notify-send -u low "$MODE_TAG" "$*" 2>/dev/null || true
}
log_error() {
  echo "[$MODE_TAG] ERROR: $*" >&2
  $HAS_NOTIFY && notify-send -u critical "$MODE_TAG" "$*" 2>/dev/null || true
}

# ── Helpers ───────────────────────────────────────────────────────────────────

is_steam_running() {
  pgrep -x steam >/dev/null 2>&1
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local elapsed=0
  local nudged=false
  while pgrep -x steam >/dev/null 2>&1; do
    if ((elapsed >= STEAM_SHUTDOWN_TIMEOUT)); then
      log_error "Steam unresponsive — force-closing after ${STEAM_SHUTDOWN_TIMEOUT}s"
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    # After 3s, nudge with SIGINT once before continuing to wait
    if ((elapsed >= 3)) && ! $nudged; then
      pkill --signal INT -x steam 2>/dev/null || true
      nudged=true
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

shutdown_steam_if_running() {
  if is_steam_running; then
    log_info "Shutting down Steam..."
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ponytail: replacement matrix — each mode replaces any OTHER active type,
# but never its own (plain = steam running with no lock files present):
#            | plain | nested | tenfoot |
#   plain    |   ✗   |   ✓    |   ✓     |
#   nested   |   ✓   |   ✗    |   ✓     |
#   tenfoot  |   ✓   |   ✓    |   ✗     |
shutdown_if_allowed() {
  local mode="$1"

  is_steam_running || return 0

  local active_type="plain"
  [[ -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-nested.lock" ]] && active_type="nested"
  [[ -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-tenfoot.lock" ]] && active_type="tenfoot"

  [[ "$active_type" == "$mode" ]] && return 0

  shutdown_steam_if_running
  cleanup_lock_files
}

# ── Dependency Checks ────────────────────────────────────────────────────────

check_dependencies() {
  local missing=()

  [[ -z ${XDG_RUNTIME_DIR:-} ]] && missing+=("XDG_RUNTIME_DIR (not set)")

  command -v flock &>/dev/null || missing+=("flock")
  command -v pgrep &>/dev/null || missing+=("pgrep")
  command -v pkill &>/dev/null || missing+=("pkill")

  # fuser is preferred but not fatal — we have a fallback
  command -v fuser &>/dev/null || log_warn "fuser not found; orphan cleanup will use fallback"

  if ((${#missing[@]})); then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ── State & Signal Handling ──────────────────────────────────────────────────

STEAM_CHILD_PID=0

forward_signal() {
  local sig="$1"
  if ((STEAM_CHILD_PID > 0)); then
    log_info "Received SIG${sig}, initiating graceful Steam shutdown..."
    steam -shutdown 2>/dev/null || true
    wait_for_steam_exit
    cleanup_lock_files
  fi
  exit "$((128 + $(kill -l "$sig" 2>/dev/null || echo 0)))"
}

setup_signal_handlers() {
  # ponytail: pass signal name as quoted argument to avoid unbound variable
  # under set -u; trap handler receives literal string, not expanded var.
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
}

# ── Monitor Detection ────────────────────────────────────────────────────────

detect_gamescope_profile_niri() {
  command -v niri &>/dev/null || return 1
  command -v jq &>/dev/null || {
    log_warn "jq not found; skipping monitor detection"
    return 1
  }

  local active_output=""
  local attempt=0

  # ponytail: niri msg -j outputs returns an object (not array) with no
  # .connected field — key presence = connected. Retry loop absorbs UTH handoff.
  while ((attempt < 3)); do
    active_output="$(niri msg -j outputs 2>/dev/null | jq -r '
      keys |
      if any(startswith("HDMI-A-")) then "HDMI-A-1"
      elif any(startswith("DP-")) then "DP-1"
      else empty
      end
    ' 2>/dev/null)" && [[ -n "$active_output" ]] && break

    ((attempt++))
    sleep 0.5
  done

  if [[ -z "$active_output" ]]; then
    local connected_names
    connected_names="$(niri msg -j outputs 2>/dev/null | jq -r 'keys | join(", ")' 2>/dev/null)"
    log_warn "No known monitor after ${attempt} attempts (connected: ${connected_names:-none}); using default gamescope args"
    return 1
  fi

  case "$active_output" in
  HDMI-A-1)
    GAMESCOPE_ARGS=(-p "std,vsr4k,hdr" -e)
    log_info "Detected HDMI-A-* → 4K HDR profile"
    ;;
  DP-1)
    GAMESCOPE_ARGS=(-p std -e)
    log_info "Detected DP-* → SDR profile"
    ;;
  esac
}

# ── Session Cleanup ──────────────────────────────────────────────────────────

cleanup_orphaned_session() {
  log_warn "Orphaned session detected (Steam not running). Cleaning up..."

  # Prefer fuser — single syscall, no tree-walking needed
  if command -v fuser &>/dev/null; then
    fuser -k -9 "$LOCK_FILE" 2>/dev/null || true
  fi

  # ponytail: fuser fallback used to try a gamescope-specific pkill pattern,
  # but that only ever matched in nested mode and this leaf-sweep already
  # catches the real target (steam itself) in every mode — one kill path
  # instead of two converging on the same outcome.
  if is_steam_running; then
    pkill --signal 9 -x steam 2>/dev/null || true
  fi

  # Poll until lock is free
  for ((i = 0; i < 10; i++)); do
    if try_lock; then
      log_info "Lock reclaimed successfully"
      return 0
    fi
    sleep 1
  done

  log_error "Failed to reclaim lock after 10s — run: fuser -k '$LOCK_FILE'"
  return 1
}

# ── Command Building ─────────────────────────────────────────────────────────

build_steam_command() {
  # Environment variables
  STEAM_CMD=(env "${STEAM_ENV_VARS[@]}")

  # Pre-launch wrappers (extensible extension point)
  # ponytail: elements are word-split on $IFS; arguments containing
  # spaces are not supported — use simple flag-style args only
  for wrapper_str in "${WRAPPERS[@]}"; do
    read -ra wrapper <<<"$wrapper_str"
    local wrapper_bin="${wrapper[0]:-}"
    local wrapper_args=("${wrapper[@]:1}")

    command -v "$wrapper_bin" &>/dev/null || continue
    STEAM_CMD+=("$wrapper_bin" "${wrapper_args[@]}")
    log_info "Wrapper: $wrapper_bin ${wrapper_args[*]:-}"
  done

  # Gamescope/nscb wrapper (if configured)
  if [[ -n ${GAMESCOPE_PATH:-} ]]; then
    STEAM_CMD+=("$GAMESCOPE_PATH" "${GAMESCOPE_ARGS[@]}")
  fi

  # Steam binary + args
  STEAM_CMD+=("${STEAM}" "${STEAM_ARGS[@]}")
}

# ── Session Launch ───────────────────────────────────────────────────────────

launch_steam() {
  build_steam_command

  "${STEAM_CMD[@]}" &
  # ponytail: PID race window is ~1 instruction; signal between & and $! is
  # theoretically possible but practically unreachable for interactive use
  STEAM_CHILD_PID=$!

  wait "$STEAM_CHILD_PID"
  STEAM_CHILD_PID=0
}

# ── Session Orchestration ────────────────────────────────────────────────────

run_session() {
  local mode="$1"
  LOCK_FILE="${XDG_RUNTIME_DIR:-}/bazzite-steam-${mode}.lock"

  check_dependencies
  setup_signal_handlers

  shutdown_if_allowed "$mode"
  acquire_lock true
  launch_steam
  cleanup_lock_files
}

# ── Lock Management ──────────────────────────────────────────────────────────

open_lock_fd() { exec 200>"$LOCK_FILE"; }
try_lock() { flock -n 200; }
wait_lock() {
  local timeout="$1"
  flock -w "$timeout" 200
}

# ponytail: single call site for all lock-file cleanup — plain, tenfoot, nested,
# and signal traps all converge here instead of each hardcoding paths.
cleanup_lock_files() {
  rm -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-tenfoot.lock" \
    "${XDG_RUNTIME_DIR:-}/bazzite-steam-nested.lock"
}

# ponytail: `quiet` suppresses the final error notification — used when
# contention is expected (e.g., we just killed Steam via the replacement
# matrix in shutdown_if_allowed and the peer's lock hasn't released yet).
acquire_lock() {
  local quiet="${1:-false}"
  open_lock_fd

  # Fast path: lock acquired immediately
  if try_lock; then
    return 0
  fi

  # Lock is held — diagnose the situation

  # If Steam is dead, this is an orphaned session — reclaim the lock
  if ! is_steam_running; then
    cleanup_orphaned_session || return 1
    return 0
  fi

  # ponytail: 5s favors the fast natural release after we kill Steam in main();
  # bump to 15s if unrelated-process handoff becomes common.
  log_info "Lock held by another session — waiting (5s timeout)..."
  wait_lock 5 && return 0

  if ! $quiet; then
    log_error "Could not acquire lock after 5s"
  fi
  return 1
}

# ── Plain Mode ───────────────────────────────────────────────────────────────

run_plain() {
  local steam_script
  steam_script="$(command -v bazzite-steam || command -v steam)" || {
    log_error "Couldn't find 'steam'!"
    exit 1
  }

  if [[ "${SKIP_RESTART:-}" == "1" ]] && is_steam_running; then
    log_info "Steam already running and SKIP_RESTART=1 — leaving existing session alone"
    return 0
  fi

  shutdown_if_allowed "plain"
  exec "$steam_script" "${STEAM_ARGS[@]}" "$@"
}

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  local args=("$@")
  local mode_args=() extra_args=() found_sep=false

  for arg in "${args[@]}"; do
    if [[ "$arg" == "--" ]]; then
      found_sep=true
      continue
    fi
    if "$found_sep"; then extra_args+=("$arg"); else mode_args+=("$arg"); fi
  done

  local cmd="${mode_args[0]:-}"
  MODE_TAG="bazzified-steam"
  STEAM_ARGS=()
  WRAPPERS=()
  GAMESCOPE_PATH=""
  GAMESCOPE_ARGS=()

  STEAM="$(command -v bazzite-steam || command -v steam)" || {
    log_error "Couldn't find 'steam'!"
    exit 1
  }

  # ponytail: single case block sets all mode-specific state AND dispatches.
  # No separate config phase; no duplicated mode matching; no intermediate vars.
  case "$cmd" in
  "")
    [[ ${STEAM_ENV_VARS+_} ]] || STEAM_ENV_VARS=()
    run_plain "${extra_args[@]}"
    ;;
  tenfoot)
    MODE_TAG="bazzified-steam-tenfoot"
    STEAM_ARGS+=(-gamepadui -pipewire "${extra_args[@]}")
    WRAPPERS=("gamemode --")
    [[ ${STEAM_ENV_VARS+_} ]] || STEAM_ENV_VARS=()
    run_session "tenfoot"
    ;;
  nested)
    MODE_TAG="bazzified-steam-nested"
    STEAM_ARGS+=(-gamepadui -pipewire -steamos3 "${extra_args[@]}")
    GAMESCOPE_PATH="$(command -v nscb 2>/dev/null)" || {
      log_error "Missing gamescope dependency!"
      exit 1
    }
    # ponytail: detect first (sets base profile), then append user args + terminator.
    # Detection failure leaves GAMESCOPE_ARGS empty → fallback below handles it.
    detect_gamescope_profile_niri || true
    GAMESCOPE_ARGS+=("${extra_args[@]}" --)
    [[ ${#GAMESCOPE_ARGS[@]} -eq 0 ]] && GAMESCOPE_ARGS=(--)
    WRAPPERS=(
      "$HOME/.local/bin/scripts/lgc1-wol.py --"
      "gamemode --"
      "$HOME/.local/bin/scripts/pactl_gate_sentinel.sh"
    )
    [[ ${STEAM_ENV_VARS+_} ]] || STEAM_ENV_VARS=(
      PROTON_ENABLE_WAYLAND=1
      IDLE_CMD="$HOME/.local/bin/scripts/on_idle.sh idle"
      ACTIVE_CMD="$HOME/.local/bin/scripts/on_idle.sh active"
      IDLE_TIMEOUT=300 # DPMS off after 5 mins
    )
    run_session "nested"
    ;;
  *)
    echo "Usage: bazzified-steam.sh [tenfoot|nested] [-- <args>]" >&2
    exit 1
    ;;
  esac
}

main "$@"
