#!/usr/bin/env bash
set -euo pipefail

# disable-vrr.sh - Temporarily disable VRR for a command's duration
# Usage: disable-vrr.sh <command> [args...]

[[ $# -eq 0 ]] && {
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
}

# Get primary output (enabled, connected, at position 0,0)
get_primary_output() {
  kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
    /^Output:/ {
      if (num && enabled && connected && geo00) { print num; found=1; exit }
      num=$2; enabled=0; connected=0; geo00=0
    }
    /enabled/ {enabled=1}
    /connected/ {connected=1}
    /Geometry:/ {geo00=($2=="0,0"?1:0)}
    END {if (!found && num && enabled && connected && geo00) print num}'
}

output_num="$(get_primary_output)"
[[ -z "$output_num" ]] && {
  echo "Error: No output found at 0,0" >&2
  exit 1
}

echo "Detected primary output: ${output_num}" >&2

set_vrr() {
  kscreen-doctor "output.${output_num}.vrrpolicy.$1"
}

echo "Disabling VRR" >&2
set_vrr "never" || exit 1

# Restore VRR on exit (handles signals like Ctrl+C)
trap 'set_vrr "automatic" 2>/dev/null' EXIT

echo "Executing: $*" >&2
"$@"

# Explicitly restore VRR after successful command completion
set_vrr "automatic"
