#!/usr/bin/env bash

check_cmd() {
  if cmd_path=$(command -v "$1"); then
    echo "$cmd_path"
  else
    echo ""
  fi
}

dep_check() {
  TUNED="$(check_cmd "tuned-adm")"
  if [ -z "$TUNED" ]; then
    echo "Error: 'tuned-adm' is required, exiting!"
    exit 1
  fi

  INHIBIT="$(check_cmd "systemd-inhibit")"
  if [ -z "$INHIBIT" ]; then
    echo "Error: 'systemd-inhibit' is required, exiting!"
    exit 1
  fi

  DBUS_SEND="$(check_cmd "dbus-send")"
  if [ -z "$DBUS_SEND" ]; then
    echo "Error: 'dbus-send' is required, exiting!"
    exit 1
  fi
}
dep_check # do dependency check early for safety

scx_wrapper() {
  local scx="${2:-scx_bpfland}"
  SCXS="$(check_cmd "$scx")"
  if [ -z "$SCXS" ]; then
    echo "Error: '$scx' required for scx_wrapper(), skipping..."
    return
  fi

  if [ "$1" = "load" ]; then
    "$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.SwitchScheduler string:"$scx" uint32:1
  elif [ "$1" = "unload" ]; then
    "$DBUS_SEND" --system --print-reply --dest=org.scx.Loader /org/scx/Loader org.scx.Loader.RestoreDefault
  fi
}

cleanup() {
  if [ -n "$TUNED" ]; then
    "$TUNED" profile "$DESK_PROF"
  fi
  scx_wrapper unload
}

handle_tool() {
  local ENV_PREFIX=(env PULSE_LATENCY_MSEC=60)
  local KDE_INHIBIT
  KDE_INHIBIT=$(command -v kde-inhibit)

  # pre-commands
  scx_wrapper load

  GAME_PROF="throughput-performance-bazzite"
  DESK_PROF="balanced-bazzite"

  if "$TUNED" list 2>&1 | grep -q "$GAME_PROF"; then
    # we're in "game" mode
    "$TUNED" profile "$GAME_PROF"
    "${ENV_PREFIX[@]}" "$INHIBIT" --why "perfboost.sh is running" -- \
      "$KDE_INHIBIT" --colorCorrect "$@"
    "$TUNED" profile "$DESK_PROF"
  else
    # just disable Night Mode in KDE
    "${ENV_PREFIX[@]}" \
      "$KDE_INHIBIT" --colorCorrect "$@"
  fi

  # post-commands
  scx_wrapper unload
}

trap "cleanup" EXIT
handle_tool "$@"
