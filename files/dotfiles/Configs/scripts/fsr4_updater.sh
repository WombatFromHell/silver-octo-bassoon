#!/usr/bin/env bash
#
# fsr4_updater.sh - Manage FSR 4 DLL symlinks across Steam prefixes
#
# Maintains symlinks from centralized FSR 4 DLL cache to all Steam
# compatibility data prefixes.
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

readonly CACHE_DIR="${HOME}/.cache/protonfixes/upscalers"
readonly DEFAULT_STEAM_LIBRARY="${HOME}/.steam/steam/steamapps/compatdata"
readonly EXTRA_STEAM_LIBRARIES=(
  "/var/mnt/data/Games/Steam Library/steamapps/compatdata"
)
readonly DLL_PATTERN="amdxcffx64_v*.dll"
readonly TARGET_NAME="amdxcffx64.dll"

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

log_info() { echo -e "\e[36m[INFO]\e[0m $*"; }
log_ok() { echo -e "\e[32m[OK]\e[0m   $*"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Discovery
# ─────────────────────────────────────────────────────────────────────────────

# Find all available FSR 4 DLL versions in cache
# Returns: sorted list of DLL filenames (newest first by version)
discover_available_versions() {
  if [[ ! -d "$CACHE_DIR" ]]; then
    log_error "Cache directory not found: $CACHE_DIR"
    return 1
  fi

  find "$CACHE_DIR" -maxdepth 1 -name "$DLL_PATTERN" -type f -printf '%f\n' 2>/dev/null |
    sort -t'_' -k2 -Vr
}

# Get the latest available version
# Args: $1 = optional specific version (filename) to use
# Returns: filename of selected DLL
select_version() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    if [[ -f "${CACHE_DIR}/${requested}" ]]; then
      echo "$requested"
      return 0
    else
      log_error "Requested version not found: $requested"
      return 1
    fi
  fi

  discover_available_versions | head -n1
}

# ─────────────────────────────────────────────────────────────────────────────
# Prefix Management
# ─────────────────────────────────────────────────────────────────────────────

# Find all prefix directories containing a system32 folder
# First checks for existing amdxcffx64.dll, falls back to scanning all prefixes
# Args: $1 = optional specific compatdata root (defaults to DEFAULT_STEAM_LIBRARY)
# Returns: list of system32 directory paths
find_prefix_system32_dirs() {
  local search_root
  if [[ -n "${1:-}" ]]; then
    search_root="$1"
  else
    search_root="$DEFAULT_STEAM_LIBRARY"
  fi

  if [[ ! -d "$search_root" ]]; then
    log_error "Steam library not found: $search_root"
    return 1
  fi

  # First, find prefixes that already have amdxcffx64.dll
  local existing_dlls
  existing_dlls=$(find "$search_root" \( -type f -o -type l \) -name "$TARGET_NAME" 2>/dev/null || true)

  if [[ -n "$existing_dlls" ]]; then
    # Return parent directories of existing DLLs
    while IFS= read -r dll_path; do
      [[ -n "$dll_path" ]] && dirname "$dll_path"
    done <<<"$existing_dlls"
  else
    # Fallback: scan all system32 directories
    find "$search_root" -maxdepth 3 -type d -name "system32" 2>/dev/null || true
  fi
}

# Create symlink in a target directory
# Args: $1 = source DLL path, $2 = target directory
create_symlink() {
  local source_dll="$1"
  local target_dir="$2"
  local target_path="${target_dir}/${TARGET_NAME}"

  # Remove existing file/link
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    rm -f "$target_path"
  fi

  # Create symlink
  ln -sf "$source_dll" "$target_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

# Extract appid from a system32 directory path
# Args: $1 = system32 path
# Returns: appid string
extract_appid() {
  local system32_path="$1"
  # Path format: .../compatdata/<appid>/pfx/drive_c/windows/system32
  echo "$system32_path" | sed -n 's|.*/compatdata/\([^/]*\)/.*|\1|p'
}

# Get the compatdata root for a given appid
# Args: $1 = appid, $2 = optional search root (defaults to DEFAULT_STEAM_LIBRARY)
# Returns: system32 directory path or empty if not found
find_appid_system32() {
  local appid="$1"
  local search_root="${2:-$DEFAULT_STEAM_LIBRARY}"
  local dll_path

  # Check in the specified search root
  dll_path="${search_root}/${appid}/pfx/drive_c/windows/system32/${TARGET_NAME}"
  if [[ -e "$dll_path" || -L "$dll_path" ]]; then
    dirname "$dll_path"
    return 0
  fi

  return 1
}

# Check if a DLL path is managed by this script
# Args: $1 = dll path, $2 = current version
# Returns: 0 if managed, 1 if not
is_managed() {
  local dll_path="$1"
  local current_version="$2"

  if [[ -L "$dll_path" ]]; then
    local target
    target=$(readlink "$dll_path")
    if [[ "$target" == *"$current_version"* ]]; then
      return 0 # Managed (current)
    else
      return 2 # Managed but outdated
    fi
  fi
  return 1 # Not managed (regular file or missing)
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Operations
# ─────────────────────────────────────────────────────────────────────────────

# List available versions
cmd_list() {
  log_info "Available FSR 4 versions in cache:"
  discover_available_versions | nl -w2 -s'. '
}

# Show current status
# Args: $1 = optional specific compatdata root
cmd_status() {
  local search_root
  if [[ -n "${1:-}" ]]; then
    search_root="$1"
  else
    search_root="$DEFAULT_STEAM_LIBRARY"
  fi
  local current_version
  local prefix_dir
  local dll_path
  local appid

  current_version=$(select_version) || return 1
  log_info "Latest available version: $current_version"
  log_info "Scanning: $search_root"
  echo

  local managed_count=0
  local unmanaged_count=0
  local outdated_count=0

  # Header
  printf "%-12s %-10s %s\n" "APPID" "STATUS" "PATH"
  printf "%s\n" "─────────────────────────────────────────────────────────────────────"

  while IFS= read -r prefix_dir; do
    [[ -z "$prefix_dir" ]] && continue
    dll_path="${prefix_dir}/${TARGET_NAME}"
    appid=$(extract_appid "$prefix_dir")

    local status_icon=""
    local status_text=""

    if [[ -L "$dll_path" ]]; then
      local target
      target=$(readlink "$dll_path")
      if [[ "$target" == *"$current_version"* ]]; then
        status_icon="🟢"
        status_text="managed"
        ((++managed_count))
      else
        status_icon="🟡"
        status_text="outdated ($(basename "$target"))"
        ((++outdated_count))
      fi
    elif [[ -f "$dll_path" ]]; then
      status_icon="🔴"
      status_text="unmanaged (file)"
      ((++unmanaged_count))
    else
      status_icon="⚪"
      status_text="missing"
      ((++unmanaged_count))
    fi

    # Shorten path: show library root + appid + ...
    local short_path
    short_path=$(echo "$dll_path" | sed 's|.*/compatdata/|compatdata/|; s|/pfx/drive_c/windows/system32|...|')

    printf "%-12s %-10s %s\n" "$appid" "$status_icon $status_text" "$short_path"
  done < <(find_prefix_system32_dirs "$search_root")

  echo
  log_info "Summary: $managed_count managed, $outdated_count outdated, $unmanaged_count unmanaged/missing"
}

# Apply symlinks to all prefixes
# Args: $1 = optional version or path, $2 = optional path or version
# Smart detection: arguments starting with '/' or '~' are treated as paths
cmd_update() {
  local arg1="${1:-}"
  local arg2="${2:-}"
  local version=""
  local search_root="$DEFAULT_STEAM_LIBRARY"

  # Detect argument types
  if [[ "$arg1" == /* || "$arg1" == ~* ]]; then
    # arg1 is a path
    search_root="$arg1"
    version="${arg2:-}"
  elif [[ "$arg2" == /* || "$arg2" == ~* ]]; then
    # arg2 is a path
    search_root="$arg2"
    version="$arg1"
  else
    # Both (or neither) look like versions
    version="$arg1"
    # arg2 ignored unless it looks like a path
  fi

  version=$(select_version "$version") || return 1
  local source_dll="${CACHE_DIR}/${version}"
  local count=0
  local total

  log_info "Using FSR 4 version: $version"
  log_info "Scanning: $search_root"

  local prefix_dirs=()
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && prefix_dirs+=("$dir")
  done < <(find_prefix_system32_dirs "$search_root")

  total=${#prefix_dirs[@]}
  [[ $total -eq 0 ]] && {
    log_warn "No Steam prefixes found"
    return 0
  }

  log_info "Updating $total prefix(es)..."

  for prefix_dir in "${prefix_dirs[@]}"; do
    create_symlink "$source_dll" "$prefix_dir"
    log_ok "${prefix_dir}/${TARGET_NAME}"
    ((++count))
  done

  echo
  log_ok "Updated $count/$total prefixes with $version"
}

# Relink a specific appid
# Args: $1 = appid, $2/$3 = optional version/path (flexible order)
# Smart detection: arguments starting with '/' or '~' are treated as paths
cmd_relink() {
  local appid="${1:-}"
  local arg2="${2:-}"
  local arg3="${3:-}"
  local version=""
  local search_root="$DEFAULT_STEAM_LIBRARY"

  if [[ -z "$appid" ]]; then
    log_error "AppID required. Usage: $(basename "$0") relink <appid> [version] [path]"
    return 1
  fi

  # Detect argument types for arg2 and arg3
  if [[ "$arg2" == /* || "$arg2" == ~* ]]; then
    # arg2 is a path
    search_root="$arg2"
    version="${arg3:-}"
  elif [[ "$arg3" == /* || "$arg3" == ~* ]]; then
    # arg3 is a path
    search_root="$arg3"
    version="$arg2"
  else
    # arg2 is version (or empty)
    version="$arg2"
  fi

  version=$(select_version "$version") || return 1
  local source_dll="${CACHE_DIR}/${version}"

  local system32_dir
  system32_dir=$(find_appid_system32 "$appid" "$search_root")

  if [[ -z "$system32_dir" ]]; then
    log_error "No amdxcffx64.dll found for AppID $appid in $search_root"
    return 1
  fi

  log_info "Relinking AppID $appid to FSR 4 version: $version"
  create_symlink "$source_dll" "$system32_dir"
  log_ok "${system32_dir}/${TARGET_NAME} → $(basename "$source_dll")"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  list                          List available FSR 4 versions in cache
  status [path]                 Show current symlink status with AppIDs
                                path: compatdata root (default: ~/.steam/steam/steamapps/compatdata)
  update [version] [path]       Update all prefixes to latest (or specified) version
                                version: DLL filename (default: latest available)
                                path: compatdata root, NOT the system32 subdirectory
  relink <appid> [version]      Relink a specific AppID to latest (or specified) version
                                appid: Steam App ID (e.g., 1903340)
                                version: DLL filename (default: latest available)
                                path: compatdata root (default: ~/.steam/steam/steamapps/compatdata)

Options:
  -h, --help                    Show this help message

Examples:
  $(basename "$0") list
  $(basename "$0") status
  $(basename "$0") status /var/mnt/data/Games/Steam\\ Library/steamapps/compatdata
  $(basename "$0") update
  $(basename "$0") update amdxcffx64_v4.0.3_6930960536b9000.dll
  $(basename "$0") update /var/mnt/data/Games/Steam\\ Library/steamapps/compatdata
  $(basename "$0") relink 1903340
  $(basename "$0") relink 2350790 amdxcffx64_v4.0.2_68840348eb8000.dll
  $(basename "$0") relink 3764200 /var/mnt/data/Games/Steam\\ Library/steamapps/compatdata

EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
  list)
    cmd_list
    ;;
  status)
    cmd_status "${2:-}"
    ;;
  update)
    cmd_update "${2:-}" "${3:-}"
    ;;
  relink)
    cmd_relink "${2:-}" "${3:-}" "${4:-}"
    ;;
  -h | --help | help)
    usage
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    log_error "Unknown command: $cmd"
    usage
    exit 1
    ;;
  esac
}

main "$@"
