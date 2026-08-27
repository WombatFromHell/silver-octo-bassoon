#!/usr/bin/env bash
set -euo pipefail

# Parse the optional FPS limit, defaulting to 60
fps=60
if [[ ${1:-} =~ ^[0-9]+$ ]]; then
  fps=$1
  shift
fi

# Strictly require the '--' delimiter to separate the fps argument from the command.
# This ensures predictable behavior and prevents ambiguity if the wrapped command
# has arguments that look like numbers.
if [[ ${1:-} != "--" ]]; then
  echo "Usage: $0 [<fps_limit>] -- <command> [args...]" >&2
  exit 1
fi
shift # Drop the '--'

cfg="fps_limit_method=early,fps_limit=$fps"
if [[ -n ${MANGOHUD_CONFIG:-} ]]; then
  cfg="${MANGOHUD_CONFIG},${cfg}"
else
  cfg="read_cfg,${cfg}"
fi

exec env MANGOHUD_CONFIG="$cfg" mangohud "$@"
