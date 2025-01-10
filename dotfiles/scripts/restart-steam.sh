#!/usr/bin/env bash

STEAM="steam"
STEAM_BIN=$(which steam)

function is_running {
  local process_name=$1
  pgrep -x "$process_name"
}

STEAM_PID=$(is_running "$STEAM")

if [ -n "$STEAM_PID" ]; then
  kill "$STEAM_PID"

  while is_running "$STEAM"; do
    sleep 1
  done
fi

$STEAM_BIN
