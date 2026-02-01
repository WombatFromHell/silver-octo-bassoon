#!/usr/bin/env bash

if [ -z "$1" ] || [ "$1" == "--help" ]; then
  echo "Usage: install-brave.sh [stable|beta]"
  exit 0
fi

if [ "$1" == "stable" ]; then
  sudo dnf install dnf-plugins-core &&
    sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
    sudo dnf install -y brave-browser &&
    distrobox-export -a brave
elif [ "$1" == "beta" ]; then
  sudo dnf install dnf-plugins-core &&
    sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo &&
    sudo dnf install -y brave-browser-beta &&
    distrobox-export -a brave-browser-beta
fi
