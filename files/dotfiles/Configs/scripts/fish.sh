#!/usr/bin/env bash

if which "$HOME"/.nix-profile/bin/fish &>/dev/null; then
  # prioritize nix fish over system fish
  exec "$HOME"/.nix-profile/bin/fish "$@"
elif which /home/linuxbrew/.linuxbrew/bin/fish &>/dev/null; then
  # use linuxbrew fish if it exists
  exec /home/linuxbrew/.linuxbrew/bin/fish "$@"
else
  # default to whatever else is in the environment
  FISH="$(/usr/bin/env fish)"
  if [ -e "$FISH" ]; then
    exec "$FISH" "$@"
  fi
fi
