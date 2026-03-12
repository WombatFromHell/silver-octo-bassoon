#!/usr/bin/env bash

SCRIPTS_BIN="$(realpath "$HOME")/.local/bin/scripts"
WRAPPER="$SCRIPTS_BIN/chrome_with_flags.py"

FLATPAK="$(which flatpak)"
FLATPAK_TARGET="dev.vencord.Vesktop"

exec "$WRAPPER" "$FLATPAK" run "$FLATPAK_TARGET" "$@"
