#!/usr/bin/env bash

# Check Nix profile (User level or System level)
if [ -x "$HOME/.nix-profile/bin/fish" ]; then
  exec "$HOME/.nix-profile/bin/fish" "$@"
elif [ -x "/run/current-system/sw/bin/fish" ]; then
  exec "/run/current-system/sw/bin/fish" "$@"

# Check Homebrew (macOS Intel vs macOS Apple Silicon vs Linux)
elif [ -x "/usr/local/bin/fish" ]; then
  exec "/usr/local/bin/fish" "$@"
elif [ -x "/opt/homebrew/bin/fish" ]; then
  exec "/opt/homebrew/bin/fish" "$@"
elif [ -x "/home/linuxbrew/.linuxbrew/bin/fish" ]; then
  exec "/home/linuxbrew/.linuxbrew/bin/fish" "$@"

# Fallback to PATH lookup without spawning subshells
else
  TARGET_FISH="$(command -v fish 2>/dev/null)"
  if [ -n "$TARGET_FISH" ] && [ "$TARGET_FISH" != "$0" ]; then
    exec "$TARGET_FISH" "$@"
  fi
fi

# Fallback default
exec /bin/sh "$@"
