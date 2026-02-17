#!/usr/bin/env bash

# Default to 'nightly' if no argument is provided
VERSION="${1:-nightly}"

# Define variables using the version tag
INSTALL_DIR="$HOME/AppImages"
FILE_NAME="nvim-${VERSION}.appimage"
FILE_PATH="$INSTALL_DIR/$FILE_NAME"
URL="https://github.com/neovim/neovim/releases/download/${VERSION}/nvim-linux-x86_64.appimage"

# Ensure the installation directory exists
mkdir -p "$INSTALL_DIR"

# Logic differs for 'nightly' (rolling) vs specific tags (static)
if [[ "$VERSION" == "nightly" ]]; then
  echo "Checking for Neovim Nightly updates..."

  # -R: Preserve remote timestamp (sets file time to build time, not download time)
  # -z: Time-conditioned download (only download if newer than local file)
  # -f: Fail silently on server errors
  # -L: Follow redirects
  if curl -fLR -z "$FILE_PATH" "$URL" -o "$FILE_PATH"; then
    # Ensure executable
    chmod 0755 "$FILE_PATH"
  else
    echo "Error: Failed to check/download Nightly."
    exit 1
  fi
else
  # For specific tags: Check if we already have this version
  if [ -f "$FILE_PATH" ]; then
    echo "Version '$VERSION' is already downloaded."
    echo "Skipping download..."
  else
    echo "Downloading Neovim version: $VERSION..."
    # -R preserves the timestamp for tagged versions as well
    if curl -fLR "$URL" -o "$FILE_PATH"; then
      chmod 0755 "$FILE_PATH"
      echo "Download complete."
    else
      echo "Error: Failed to download version '$VERSION'."
      echo "Please check if the tag is correct (e.g., v0.11.6, stable)."
      rm -f "$FILE_PATH"
      exit 1
    fi
  fi
fi

# Update the symlink to point to the requested version
echo "Switching active Neovim to version '$VERSION'..."
sudo mkdir -p /usr/local/bin/

# Remove existing symlink or file to ensure a clean swap
if [ -L "/usr/local/bin/nvim" ] || [ -e "/usr/local/bin/nvim" ]; then
  sudo rm /usr/local/bin/nvim
fi

# Create the new symlink
sudo ln -s "$FILE_PATH" /usr/local/bin/nvim

echo "Success! Active Neovim version is now '$VERSION'."
