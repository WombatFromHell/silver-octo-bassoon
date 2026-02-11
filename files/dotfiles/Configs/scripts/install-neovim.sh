#!/usr/bin/env bash

# Define variables
URL="https://github.com/neovim/neovim/releases/download/nightly/nvim-linux-x86_64.appimage"
INSTALL_DIR="$HOME/AppImages"
FILE_NAME="nvim-linux-x86_64.appimage"
FILE_PATH="$INSTALL_DIR/$FILE_NAME"

# Ensure 'nvim-linux-x86_64.appimage.old' doesn't exist
mkdir -p "$INSTALL_DIR"
if [ -f "${FILE_PATH}.old" ]; then
  rm "${FILE_PATH}.old"
fi
# Check if an active .appimage already exists and rename it to .old
if [ -f "$FILE_PATH" ]; then
  echo "Found existing AppImage. Renaming to ${FILE_NAME}.old"
  mv "$FILE_PATH" "${FILE_PATH}.old"
fi

# Download the latest nightly using curl
echo "Downloading latest Neovim nightly..."
curl -L "$URL" -o "$FILE_PATH"

# Ensure the AppImage is executable
chmod 0755 "$FILE_PATH"

# Create a symlink in /usr/local/bin
if ! [ -x "/usr/local/bin/nvim" ]; then
  echo "Creating symlink in /usr/local/bin (requires sudo)..."
  sudo mkdir -p /usr/local/bin/
  sudo ln -sf "$FILE_PATH" /usr/local/bin/nvim
fi

echo "Neovim nightly installed successfully!"
