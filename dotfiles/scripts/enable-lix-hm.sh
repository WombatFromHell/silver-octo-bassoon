#!/usr/bin/env bash

if command -v nix &>/dev/null; then
  nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
  nix-channel --update
  nix-shell '<home-manager>' -A install
  exit 0
fi
exit 1
