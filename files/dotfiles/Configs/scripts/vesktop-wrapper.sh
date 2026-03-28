#!/usr/bin/env bash

WRAPPER="$(command -v chromium-flags.sh 2>/dev/null || echo "")"
FLATPAK="$(command -v flatpak 2>/dev/null || echo "")"
FLATPAK_TARGET="dev.vencord.Vesktop"

exec "$WRAPPER" "$FLATPAK" run "$FLATPAK_TARGET" "$@"
