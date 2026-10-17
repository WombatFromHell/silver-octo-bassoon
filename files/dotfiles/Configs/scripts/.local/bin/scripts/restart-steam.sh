#!/usr/bin/env bash
set -euo pipefail

# Stop a running Steam client, then run the given command (or nothing).
# Resolve symlinked installs (install.sh's ~/.local/bin links) via realpath.
if command -v realpath &>/dev/null; then
  scripts_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
else
  scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
fi
# shellcheck source=./steam-shutdown.sh disable=SC1091
source "$scripts_dir/steam-shutdown.sh"

log_info() { echo "[restart-steam] $*" >&2; }
log_error() { echo "[restart-steam] ERROR: $*" >&2; }

shutdown_steam_if_running

if (($# > 0)); then
  exec "$@"
fi
