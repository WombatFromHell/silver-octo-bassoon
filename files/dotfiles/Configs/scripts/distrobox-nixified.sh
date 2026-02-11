#!/usr/bin/env bash

DISTROBOX="$(command -v distrobox)"
if [ -n "$DISTROBOX" ]; then
  "${DISTROBOX}" create "$@" --volume /nix:/nix --volume /etc/nix:/etc/nix --volume /var/nix:/var/nix
else
  echo "Error: 'distrobox' is not installed"
  exit 1
fi
