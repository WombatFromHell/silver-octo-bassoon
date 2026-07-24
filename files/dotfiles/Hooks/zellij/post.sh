#!/usr/bin/env bash
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "We're not on macOS, skipping..." >&2
  exit 0
fi

MACOS_ZELLIJ_PERM_DIR="$HOME/Library/Caches/org.Zellij-Contributors.Zellij"
SRC_DIR="$HOME/.config/dotfiles/Configs/zellij/.cache/zellij"
mkdir -p "$MACOS_ZELLIJ_PERM_DIR"
ln -sf "$SRC_DIR"/permissions.kdl "$MACOS_ZELLIJ_PERM_DIR"/permissions.kdl
