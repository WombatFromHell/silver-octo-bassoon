#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neovim AppImage Manager
# =============================================================================
# Downloads, installs, and manages Neovim AppImage versions.

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly INSTALL_DIR="$HOME/AppImages"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly SYMLINK_PATH="$LOCAL_BIN/nvim"
readonly BASE_URL="https://github.com/neovim/neovim/releases/download"
readonly LATEST_RELEASE_URL="https://github.com/neovim/neovim/releases/latest"
readonly NIGHTLY_URL="${BASE_URL}/nightly/nvim-linux-x86_64.appimage"

# -----------------------------------------------------------------------------
# Command Execution Strategies (for testability)
# -----------------------------------------------------------------------------
CURL_CMD="${CURL_CMD:-curl}"
MKDIR_CMD="${MKDIR_CMD:-mkdir}"
RM_CMD="${RM_CMD:-rm}"
CHMOD_CMD="${CHMOD_CMD:-chmod}"
LN_CMD="${LN_CMD:-ln}"
FUSER_CMD="${FUSER_CMD:-fuser}"
MKTEMP_CMD="${MKTEMP_CMD:-mktemp}"
SUDO_CMD="${SUDO_CMD:-sudo}"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
die() {
  log_error "$*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -i, --install [version]   Install Neovim version (e.g., stable, nightly). Default: stable
  -u, --uninstall [version] Remove a specific Neovim version. Default: stable
  -g, --global           Install symlink to /usr/local/bin (requires sudo)
  -h, --help            Show this help message

Examples:
  $(basename "$0") -i
  $(basename "$0") --install stable
  $(basite "$0") --install nightly
  $(basename "$0") -g --install nightly
  $(basename "$0") -u
  $(basename "$0") --uninstall stable
EOF
}

get_version() {
  local action="$1"
  local version="${2:-}"

  if [[ -z "$version" || "$version" == --* ]]; then
    echo "stable"
    return 1
  fi

  echo "$version"
  return 0
}

# -----------------------------------------------------------------------------
# Core Functions
# -----------------------------------------------------------------------------

get_path() {
  local install_dir="$1"
  local version="$2"
  local suffix="${3:-appimage}"
  echo "${install_dir}/nvim-${version}.${suffix}"
}

get_stable_version() {
  # Follow redirect from /releases/latest to get the current stable version tag
  local redirect_url
  redirect_url=$($CURL_CMD --silent --location --connect-timeout 10 --max-time 10 --write-out '%{url_effective}' --output /dev/null "$LATEST_RELEASE_URL")
  # Extract version tag from URL (e.g., v0.12.0 from .../tag/v0.12.0)
  basename "$redirect_url"
}

get_download_url() {
  local version="$1"
  if [[ "$version" == "nightly" ]]; then
    echo "$NIGHTLY_URL"
  else
    echo "${BASE_URL}/${version}/nvim-linux-x86_64.appimage"
  fi
}

ensure_install_dir() {
  local install_dir="$1"
  $MKDIR_CMD -p "$install_dir"
}

# Fetches only the response headers for $url and writes them to stdout.
fetch_headers() {
  local url="$1"
  $CURL_CMD --silent --fail --location --connect-timeout 10 --max-time 10 --head "$url"
}

# Extracts a named header value (case-insensitive) from a file or stdin.
extract_header() {
  local name="$1"
  local src="${2:-/dev/stdin}"

  if [[ -f "$src" ]]; then
    grep -i "^${name}:" "$src"
  else
    grep -i "^${name}:"
  fi | tail -1 | sed 's/^[^:]*: *//' | tr -d '\r'
}

# Returns 0 if a file is currently in use by another process.
is_file_busy() {
  $FUSER_CMD "$1" &>/dev/null
}

# Checks nightly metadata against remote headers.
# Returns 0 if an update IS needed, 1 if already up to date.
check_nightly_update() {
  local url="$1"
  local meta_path="$2"

  local remote_headers
  remote_headers=$(fetch_headers "$url") || die "Failed to fetch headers for nightly build."

  local remote_etag remote_last_modified
  remote_etag=$(echo "$remote_headers" | extract_header "etag")
  remote_last_modified=$(echo "$remote_headers" | extract_header "last-modified")

  local stored_etag stored_last_modified
  stored_etag=$(grep '^etag=' "$meta_path" | cut -d= -f2- || true)
  stored_last_modified=$(grep '^last-modified=' "$meta_path" | cut -d= -f2- || true)

  if [[ -n "$remote_etag" && -n "$stored_etag" ]]; then
    [[ "$remote_etag" == "$stored_etag" ]] && return 1
  elif [[ -n "$remote_last_modified" && -n "$stored_last_modified" ]]; then
    [[ "$remote_last_modified" == "$stored_last_modified" ]] && return 1
  fi

  return 0
}

# Downloads a tagged version and sets permissions.
# Downloads an AppImage and optionally updates metadata if meta_path is provided.
download_appimage() {
  local url="$1"
  local dest="$2"
  local meta_path="${3:-}"

  local curl_args=("-fLR" "--connect-timeout" "10" "--max-time" "300")
  local resp_headers_file=""

  if [[ -n "$meta_path" ]]; then
    resp_headers_file=$($MKTEMP_CMD)
    curl_args+=("--remote-time" "--dump-header" "$resp_headers_file")
  fi

  if $CURL_CMD "${curl_args[@]}" "$url" -o "$dest"; then
    $CHMOD_CMD 0755 "$dest"
    if [[ -n "$meta_path" && -n "$resp_headers_file" ]]; then
      local new_etag new_last_modified
      new_etag=$(extract_header "etag" <"$resp_headers_file")
      new_last_modified=$(extract_header "last-modified" <"$resp_headers_file")
      {
        echo "etag=${new_etag}"
        echo "last-modified=${new_last_modified}"
      } >"$meta_path"
      $RM_CMD -f "$resp_headers_file"
    fi
    return 0
  else
    [[ -n "$resp_headers_file" ]] && $RM_CMD -f "$resp_headers_file"
    [[ -f "$dest" ]] && $RM_CMD -f "$dest"
    return 1
  fi
}

# Returns 0 if an update was performed/downloaded.
# Returns 1 if no update was needed (already up to date).
# Exits script on error.
download_version() {
  local install_dir="$1"
  local version="$2"
  local file_path="$3"
  local url="$4"

  if [[ "$version" == "nightly" ]]; then
    local meta_path
    meta_path=$(get_path "$install_dir" "$version" "meta")

    [[ -f "$file_path" && -f "$meta_path" ]] && ! check_nightly_update "$url" "$meta_path" && return 1

    [[ -f "$file_path" ]] && is_file_busy "$file_path" && {
      log_error "Cannot update: Neovim is running."
      return 1
    }

    log_info "Downloading nightly build..."
    download_appimage "$url" "$file_path" "$meta_path" || die "Failed to download nightly build."
    return 0
  fi

  [[ -f "$file_path" ]] && {
    log_info "Version '$version' is already installed."
    return 1
  }

  log_info "Downloading Neovim version: $version..."
  download_appimage "$url" "$file_path" || die "Failed to download version '$version'."
  return 0
}

update_symlink() {
  local symlink_path="$1"
  local file_path="$2"
  local dir
  dir=$(dirname "$symlink_path")

  [[ ! -d "$dir" ]] && $SUDO_CMD mkdir -p "$dir"

  local current_target
  if [[ -L "$symlink_path" ]]; then
    current_target=$(readlink "$symlink_path")
    [[ "$current_target" == "$file_path" ]] && return 1
  fi

  [[ -e "$symlink_path" || -L "$symlink_path" ]] && $SUDO_CMD rm -f "$symlink_path"

  $SUDO_CMD ln -s "$file_path" "$symlink_path" || die "Failed to create symlink at $symlink_path."
  return 0
}

remove_version() {
  local install_dir="$1"
  local symlink_path="$2"
  local version="$3"
  local file_path
  file_path=$(get_path "$install_dir" "$version" "appimage")

  [[ ! -f "$file_path" ]] && {
    log_info "Version '$version' is not installed."
    return 0
  }

  log_info "Removing version '$version'..."
  $RM_CMD -f "$file_path" "$(get_path "$install_dir" "$version" "meta")"

  if [[ -L "$symlink_path" ]] && [[ "$(readlink "$symlink_path")" == "$file_path" ]]; then
    $SUDO_CMD rm -f "$symlink_path"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

prompt_sudo() {
  local prompt="$1"
  local reply

  read -r -p "$prompt [y/N] " reply || return 1
  [[ "${reply,,}" == "y" ]]
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  local action=""
  local version=""
  local global_install=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -g | --global)
      global_install=true
      shift
      ;;
    -i | --install | -u | --uninstall)
      action="${1#--}"
      if version=$(get_version "$1" "$2"); then
        shift 2
      else
        shift
      fi
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1\n$(usage)"
      ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage
    exit 1
  fi

  ensure_install_dir "$INSTALL_DIR"

  # Resolve 'stable' alias to actual version tag for file naming
  local resolved_version="$version"
  if [[ "$version" == "stable" ]]; then
    resolved_version=$(get_stable_version)
  fi

  local file_path
  file_path=$(get_path "$INSTALL_DIR" "$resolved_version" "appimage")

  if [[ "$action" == "install" ]]; then
    local url
    url=$(get_download_url "$resolved_version")

    # download_version returns 0 if updated, 1 if already up-to-date
    if download_version "$INSTALL_DIR" "$resolved_version" "$file_path" "$url"; then
      log_info "Update downloaded successfully."
    else
      log_info "No new update found."
    fi

    # Ensure symlink is set (default: ~/.local/bin/nvim)
    local symlink_path="$SYMLINK_PATH"
    if [[ "$global_install" == true ]]; then
      symlink_path="/usr/local/bin/nvim"
      if prompt_sudo "Install symlink to /usr/local/bin (requires sudo)?"; then
        log_info "Installing global symlink..."
      else
        log_info "Skipping global symlink. Using $symlink_path"
        symlink_path="$SYMLINK_PATH"
      fi
    fi
    update_symlink "$symlink_path" "$file_path"

    # Offer to add to PATH if needed
    if [[ "$symlink_path" == "$SYMLINK_PATH" ]] && [[ ":$PATH:" != *"$LOCAL_BIN"* ]]; then
      log_info "Add to PATH: export PATH=\"$LOCAL_BIN:\$PATH\""
    fi
  elif [[ "$action" == "uninstall" ]]; then
    remove_version "$INSTALL_DIR" "$SYMLINK_PATH" "$resolved_version"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
