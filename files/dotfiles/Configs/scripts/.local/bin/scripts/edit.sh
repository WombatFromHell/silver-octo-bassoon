#!/usr/bin/env bash

set -euo pipefail

# User-configurable preferences
PREFERRED="${PREFERRED:-hx}"
FALLBACK="${FALLBACK:-nvim}"

main() {
  local editor=""
  local preferred_list=("$PREFERRED")
  local fallback_list=("$FALLBACK" "vi" "nano")

  # Check for preferred editors
  for editor_cmd in "${preferred_list[@]}"; do
    if editor=$(command -v "$editor_cmd" 2>/dev/null); then
      export EDITOR="$editor"
      exec "$editor" "$@"
    fi
  done

  # Try fallbacks
  for editor_cmd in "${fallback_list[@]}"; do
    if editor=$(command -v "$editor_cmd" 2>/dev/null); then
      export EDITOR="$editor"
      exec "$editor" "$@"
    fi
  done

  echo "Error: No editor found (tried $PREFERRED $FALLBACK vi nano)" >&2
  exit 1
}

main "$@"
