#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPTS="$HOME/.local/bin/scripts"

STEAM="$SCRIPTS/bazzite-steam.sh"
STEAM_ARGS=(
  -steamos3
  -tenfoot
)
GAMESCOPE_WRAPPER="$SCRIPTS/nscb.pyz"
GAMESCOPE_ARGS=(
  -p std
  -p vsr4k
  --mangoapp
  -e
  --
)

LOCAL_STEAM_ENV_VARS=(
  "PROTON_ENABLE_WAYLAND=1"
)

# ── Helper Functions ──────────────────────────────────────────────────────────

add_if_exists() {
  local array_name="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    eval "$array_name+=(\"$file\")"
  fi
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local timeout=15
  local elapsed=0
  while pgrep -xc steam >/dev/null 2>&1; do
    if ((elapsed >= timeout)); then
      notify-send "Steam unresponsive" "Force-closing Steam after ${timeout}s timeout" 2>/dev/null || true
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
}

shutdown_steam_if_running() {
  if pgrep -x steam >/dev/null 2>&1; then
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ── Command Chain Builder ────────────────────────────────────────────────────

build_command() {
  local CMD=()

  # Environment variables
  CMD+=(
    env "${LOCAL_STEAM_ENV_VARS[@]}"
  )

  # Optional wrappers
  local OTHER_WRAPPERS=()
  add_if_exists "OTHER_WRAPPERS" "$SCRIPTS/gamemode.py --"

  CMD+=(
    "${OTHER_WRAPPERS[@]}"
    "${GAMESCOPE_WRAPPER}" "${GAMESCOPE_ARGS[@]}"
    "${STEAM}" "${STEAM_ARGS[@]}"
  )

  echo "${CMD[@]}"
}

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  shutdown_steam_if_running

  local CMD
  read -ra CMD <<<"$(build_command)"

  "${CMD[@]}" "${@}"
}

main "${@}"
