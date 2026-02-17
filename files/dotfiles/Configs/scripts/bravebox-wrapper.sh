#!/usr/bin/env bash

PKGNAME=""
if command -v brave-browser-beta &>/dev/null; then
  PKGNAME="brave-browser-beta"
elif command -v brave-browser &>/dev/null; then
  PKGNAME="brave-browser"
else
  echo "Error: 'brave-browser-beta' and 'brave-browser' not found in PATH!"
  exit 1
fi

if sudo dnf upgrade -y "${PKGNAME}"; then
  exec ~/.local/bin/scripts/chrome_with_flags.py "${PKGNAME}" "$@"
else
  echo "Error: something went wrong when upgrading '${PKGNAME}'!"
  exit 1
fi
