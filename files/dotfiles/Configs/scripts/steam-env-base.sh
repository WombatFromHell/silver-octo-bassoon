#!/usr/bin/env bash

# steam-env-base.sh - Base Steam gaming environment wrapper
# Executes commands with standardized Steam environment variables

# Base Steam environment variables (no exports, just for env command)
STEAM_BASE_ENV_VARS=(
  "WINEALSA_CHANNELS=2"
  "WINEALSA_SPATIAL=1"
  "WINEDLLOVERRIDES=winepulse.drv=d"
  "PROTON_USE_NTSYNC=1"
)

# Execute the provided command with Steam environment
if [[ $# -gt 0 ]]; then
  echo "Injecting Steam related environment variables: ${STEAM_BASE_ENV_VARS[*]}"
  exec env "${STEAM_BASE_ENV_VARS[@]}" "$@"
else
  # If no command provided, show usage
  echo "Usage: $0 <command> [args...]"
  echo "Executes command with Steam base environment variables:"
  for var in "${STEAM_BASE_ENV_VARS[@]}"; do
    echo "  $var"
  done
  exit 1
fi

