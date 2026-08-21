  #!/usr/bin/env bash

set -euo pipefail

# User-configurable preferences
PREFERRED="${PREFERRED:-hx}"
FALLBACK="${FALLBACK:-nvim}"

main() {
  local editor=""
  local editors=("$PREFERRED" "$FALLBACK" "vi" "nano")

  for editor_cmd in "${editors[@]}"; do
    if editor=$(command -v "$editor_cmd" 2>/dev/null); then
      export EDITOR="$editor"
      if [ -n "${TMUX:-}" ]; then
        # ponytail: tmux >=3.2 takes multiple args and handles quoting itself
        exec tmux new-window "$editor" "$@"
      elif [ -n "${ZELLIJ:-}" ]; then
        exec zellij action new-tab --close-on-exit -- "$editor" "$@"
      fi
      exec "$editor" "$@"
    fi
  done

  echo "Error: No editor found (tried $PREFERRED $FALLBACK vi nano)" >&2
  exit 1
}

main "$@"
