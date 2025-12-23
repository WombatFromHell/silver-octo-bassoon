#!/usr/bin/env bash

# Antigravity IDE Installer for Fedora 43
# This script adds the Antigravity COPR repository and installs the IDE

set -e

echo "=== Antigravity IDE Installer ==="
echo

# Check if running on Fedora
if [ ! -f /etc/fedora-release ]; then
  echo "Error: This script is designed for Fedora systems."
  exit 1
fi

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo or as root."
  exit 1
fi

echo "Adding Antigravity repository..."
sudo tee /etc/yum.repos.d/antigravity.repo <<EOL
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=0
EOL

echo
echo "Repository added successfully!"
echo

echo "Updating package cache..."
dnf makecache

echo
echo "Installing Antigravity IDE..."
dnf install -y antigravity

echo
echo "=== Installation Complete ==="
echo "You can now launch Antigravity IDE from your applications menu or by running 'antigravity' in the terminal."
