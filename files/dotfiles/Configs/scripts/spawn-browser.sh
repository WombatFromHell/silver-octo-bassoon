#!/usr/bin/env bash
# new-browser-window — open a new browser window using the system default

set -euo pipefail

URL="${1:-}"

# Get the .desktop file name for the default browser
DESKTOP_FILE="$(xdg-settings get default-web-browser 2>/dev/null)" || {
  echo "Error: could not determine default browser" >&2
  exit 1
}

# Search standard locations for the .desktop file
DESKTOP_PATH="$(find \
  "$HOME/.local/share/applications" \
  /usr/local/share/applications \
  /usr/share/applications \
  -name "$DESKTOP_FILE" 2>/dev/null | head -n1)"

[[ -z "$DESKTOP_PATH" ]] && {
  echo "Error: .desktop file not found for '$DESKTOP_FILE'" >&2
  exit 1
}

# Extract the Exec= line, strip field codes (%u %U %f %F etc.) and quotes
EXEC_LINE="$(grep -m1 '^Exec=' "$DESKTOP_PATH" |
  sed 's/^Exec=//; s/%[a-zA-Z]//g; s/^ *//; s/ *$//')"

# Pull just the binary (first token)
BROWSER_BIN="${EXEC_LINE%% *}"

# Resolve to full path if needed
BROWSER_BIN="$(command -v "$BROWSER_BIN" 2>/dev/null || echo "$BROWSER_BIN")"

[[ -z "$BROWSER_BIN" ]] && {
  echo "Error: could not resolve browser binary" >&2
  exit 1
}

# Spawn a new window — flags differ by browser family
case "$(basename "$BROWSER_BIN")" in
firefox* | librewolf* | waterfox*)
  exec "$BROWSER_BIN" --new-window ${URL:+"$URL"}
  ;;
google-chrome* | chromium* | brave* | microsoft-edge* | vivaldi*)
  exec "$BROWSER_BIN" --new-window ${URL:+"$URL"}
  ;;
epiphany* | gnome-web*)
  exec "$BROWSER_BIN" --new-window ${URL:+"$URL"}
  ;;
*)
  # Best-effort fallback — just open it
  echo "Warning: unknown browser '$(basename "$BROWSER_BIN")', trying without --new-window" >&2
  exec "$BROWSER_BIN" ${URL:+"$URL"}
  ;;
esac
