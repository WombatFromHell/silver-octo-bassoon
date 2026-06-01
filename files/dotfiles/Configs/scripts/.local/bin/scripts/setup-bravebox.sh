#!/usr/bin/env bash
set -euo pipefail

DISTROBOX="$(command -v distrobox)"
SCRIPT_DIR="$HOME/.local/bin/scripts"

check_bravebox() {
  "$DISTROBOX" list | grep -qw "bravebox"
}
remove_bravebox() {
  "$DISTROBOX" rm -f bravebox
}

create_bravebox() {
  echo "Creating bravebox..."
  if "$SCRIPT_DIR"/distrobox-nixified.sh -i fedora:43 -n bravebox --volume /var/mnt; then
    echo "Bravebox created successfully."
    return 0
  else
    echo "Failed to create bravebox!"
    return 1
  fi
}

install_brave_in_box() {
  # We use 'bash -s' so bash reads the script from stdin.
  # We use <<EOF (no quotes) to allow $SCRIPT_DIR to be expanded by the HOST
  # to the correct absolute path before execution inside the container.
  "$DISTROBOX" enter bravebox -- bash -s <<EOF
if ! command -v brave-browser 2>&1 >/dev/null ||
  ! command -v brave-browser-beta 2>&1 >/dev/null; then
  echo "Installing Brave in 'bravebox' container..."
  "$SCRIPT_DIR"/fedora43-media-components.sh
  "$SCRIPT_DIR"/install-brave.sh beta
else
  echo "Brave already installed in 'bravebox' container, skipping..."
fi
EOF
}

main() {
  local flags="$*"
  if [ -n "$flags" ] && [ "$flags" = "--replace" ] || [ "$flags" = "--rm" ]; then
    remove_bravebox
  fi

  if check_bravebox; then
    echo "Container 'bravebox' already exists, skipping..."
  else
    create_bravebox
  fi

  # Run the installation inside the box
  install_brave_in_box
}

main "$@"
