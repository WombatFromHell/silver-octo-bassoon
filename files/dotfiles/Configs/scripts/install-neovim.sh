#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim AppImage Installer
# =============================================================================
# Downloads and manages Neovim AppImage installations (nightly or tagged versions).
# Usage: ./install-neovim.sh [VERSION]
#   VERSION: 'nightly' (default) or a specific tag (e.g., v0.11.6, stable)
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly INSTALL_DIR="$HOME/AppImages"
readonly SYMLINK_PATH="/usr/local/bin/nvim"
readonly NIGHTLY_URL="https://github.com/neovim/neovim/releases/download/nightly/nvim-linux-x86_64.appimage"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() {
  echo "[INFO] $*"
}

log_error() {
  echo "[ERROR] $*" >&2
}

die() {
  log_error "$*"
  exit 1
}

# -----------------------------------------------------------------------------
# Core Functions
# -----------------------------------------------------------------------------

get_file_path() {
  local version="$1"
  echo "${INSTALL_DIR}/nvim-${version}.appimage"
}

get_download_url() {
  local version="$1"
  if [[ "$version" == "nightly" ]]; then
    echo "$NIGHTLY_URL"
  else
    echo "https://github.com/neovim/neovim/releases/download/${version}/nvim-linux-x86_64.appimage"
  fi
}

ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
}

download_nightly() {
  local file_path="$1"
  local url="$2"

  if [[ -f "$file_path" ]]; then
    # Get local file mtime in RFC 2822 format for curl's --time-cond
    local local_mtime
    local_mtime="$(date -r "$file_path" -R)"

    # Use -w to capture HTTP response code; 304 means Not Modified
    local http_code
    http_code="$(curl --silent --fail --location --time-cond "$local_mtime" --remote-time -w '%{http_code}' "$url" -o "$file_path")"

    if [[ "$http_code" == "304" ]]; then
      return 1 # No update needed
    elif [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      chmod 0755 "$file_path"
      return 0 # Update was performed
    else
      die "Failed to check/download Nightly build (HTTP $http_code)."
    fi
  else
    if ! curl --fail --location --remote-time "$url" -o "$file_path"; then
      die "Failed to download Nightly build."
    fi
    chmod 0755 "$file_path"
    return 0 # Update was performed
  fi
}

download_tagged_version() {
  local version="$1"
  local file_path="$2"
  local url="$3"

  if [[ -f "$file_path" ]]; then
    log_info "Version '$version' is already downloaded. Skipping download..."
    return 1 # No update needed
  fi

  log_info "Downloading Neovim version: $version..."

  if ! curl -fLR "$url" -o "$file_path"; then
    rm -f "$file_path"
    die "Failed to download version '$version'. Please verify the tag exists (e.g., v0.11.6, stable)."
  fi

  chmod 0755 "$file_path"
  log_info "Download complete."
  return 0 # Update was performed
}

update_symlink() {
  local version="$1"
  local file_path="$2"

  log_info "Updating symlink to '$file_path'..."

  if ! sudo mkdir -p "$(dirname "$SYMLINK_PATH")"; then
    die "Failed to create directory for symlink."
  fi

  # Remove existing symlink or file
  if [[ -L "$SYMLINK_PATH" ]] || [[ -e "$SYMLINK_PATH" ]]; then
    sudo rm "$SYMLINK_PATH"
  fi

  if ! sudo ln -s "$file_path" "$SYMLINK_PATH"; then
    die "Failed to create symlink at $SYMLINK_PATH."
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  local version="${1:-nightly}"
  local file_path
  local url

  file_path="$(get_file_path "$version")"
  url="$(get_download_url "$version")"

  ensure_install_dir

  if [[ "$version" == "nightly" ]]; then
    if download_nightly "$file_path" "$url"; then
      update_symlink "$version" "$file_path"
      log_info "Neovim '$version' updated successfully."
    else
      log_info "Neovim '$version' is already up-to-date."
    fi
  else
    if download_tagged_version "$version" "$file_path" "$url"; then
      update_symlink "$version" "$file_path"
      log_info "Neovim '$version' installed successfully."
    else
      log_info "Neovim '$version' is already installed."
    fi
  fi
}

main "$@"
