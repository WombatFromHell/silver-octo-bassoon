#!/usr/bin/env bash
set -euo pipefail

# Stop a running Steam client when the session selector runs. The teardown
# itself lives in steam-shutdown.sh, shared with the Steam launchers.
if command -v realpath &>/dev/null; then
  scripts_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
else
  scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
fi
# shellcheck source=./steam-shutdown.sh disable=SC1091
source "$scripts_dir/steam-shutdown.sh"

log_info() { echo "[steamos-session-select] $*" >&2; }
log_error() { echo "[steamos-session-select] ERROR: $*" >&2; }

shutdown_steam_if_running
