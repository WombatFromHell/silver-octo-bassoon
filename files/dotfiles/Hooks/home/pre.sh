#!/usr/bin/env bash

ROOT_DIR="$HOME/.ansible-root/files/dotfiles"
TARGET="$HOME/.config/dotfiles"

if ! [ -d "${ROOT_DIR}" ]; then
  echo "$ROOT_DIR doesn't seem to exist, skipping dotfiles symlink..."
  exit 0
fi

[ -L "$TARGET" ] && rm "$TARGET"
ln -sf "$ROOT_DIR" "$TARGET"
