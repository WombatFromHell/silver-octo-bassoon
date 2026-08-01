#!/usr/bin/env bash
set -euo pipefail

# Strictly require the '--' delimiter to separate the fps argument from the command.
# This ensures predictable behavior and prevents ambiguity if the wrapped command
# has arguments that look like numbers.
if [[ "${1:-}" != "--" ]]; then
  echo "Usage: $0 [<fps_limit>] -- <command> [args...]" >&2
  exit 1
fi
shift # Drop the '--'

# Parse the optional FPS limit, defaulting to 60.
# If the first argument is empty or contains anything other than digits, fall back to 60.
fps="${1:-60}"
if [[ "$fps" != *[!0-9]* ]]; then
  shift
else
  fps=60
fi

exec env MANGOHUD=1 MANGOHUD_CONFIG="read_cfg,fps_limit=$fps,no_display" "$@"
