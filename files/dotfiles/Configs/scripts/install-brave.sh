#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# CONFIGURATION
#==============================================================================
readonly WRAPPER_PATH="$(realpath "$HOME"/.local/bin/scripts/brave-wrapper.sh)"
readonly WRAPPER_SCRIPT="${WRAPPER_SCRIPT:-$WRAPPER_PATH}"
readonly CONTAINER_NAME="${CONTAINER_NAME:-bravebox}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# Globals set by arg parsing
INSTALL_TYPE=""
USE_FLATPAK="false"
UNINSTALL="false"

# Globals set by config lookup
PKG_NAME=""
REPO_URL=""
EXPORT_NAME=""
FLATPAK_ID="com.brave.Browser"

#==============================================================================
# USAGE
#==============================================================================
show_help() {
  cat <<EOF
Usage: install-brave.sh [OPTIONS] [stable|beta]

Options:
  --flatpak    Install Brave via Flatpak instead of DNF (stable only)
  --uninstall  Remove Brave export from host (does not uninstall from container)
  --help       Show this help message

Examples:
  install-brave.sh stable              # Install stable via DNF
  install-brave.sh beta                # Install beta via DNF
  install-brave.sh --flatpak stable    # Install stable via Flatpak
  install-brave.sh --uninstall stable  # Remove export from host
EOF
}

#==============================================================================
# CORE UTILITIES
#==============================================================================
is_inside_container() { [[ -f /var/run/.containerenv ]]; }

get_container_id() {
  local id=""
  if is_inside_container; then
    # shellcheck disable=SC1091
    source /var/run/.containerenv 2>/dev/null || true
    id="${CONTAINER_ID:-}"
  fi
  echo "$id"
}

is_container_running() {
  distrobox list 2>/dev/null | tail -n +2 | grep -qE "\|\s+${CONTAINER_NAME}\s+\|"
}

set_install_config() {
  case "$INSTALL_TYPE" in
  stable)
    PKG_NAME="brave-browser"
    REPO_URL="https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo"
    EXPORT_NAME="brave"
    ;;
  beta)
    PKG_NAME="brave-browser-beta"
    REPO_URL="https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo"
    EXPORT_NAME="brave-browser-beta"
    ;;
  *)
    echo "Error: Invalid install type '$INSTALL_TYPE'" >&2
    exit 1
    ;;
  esac
}

#==============================================================================
# INSTALLATION LOGIC
#==============================================================================
install_flatpak() {
  if flatpak list --app --columns=application | grep -q "^${FLATPAK_ID}$"; then
    echo "✓ Brave Flatpak already installed: ${FLATPAK_ID}"
    return 0
  fi
  echo "Installing Brave via Flatpak: ${FLATPAK_ID}"
  flatpak install --user -y "${FLATPAK_ID}"
}

install_dnf() {
  if rpm -q "$PKG_NAME" &>/dev/null; then
    echo "✓ ${PKG_NAME} already installed"
  else
    echo "Installing ${PKG_NAME} via DNF"
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager addrepo --overwrite --from-repofile="${REPO_URL}"
    sudo dnf install -y "${PKG_NAME}"
  fi

  # Export to host
  if command -v distrobox-export &>/dev/null; then
    distrobox-export -a "${EXPORT_NAME}"
    echo "✓ Exported ${EXPORT_NAME} to host"
  fi
}

create_xdg_bridge() {
  local target="/usr/local/bin/xdg-open"
  if [[ -f "$target" ]] && grep -q "org.freedesktop.portal.OpenURI" "$target"; then
    echo "✓ XDG open bridge already configured"
    return 0
  fi

  echo "Creating XDG open bridge for container→host integration"
  sudo install -m 755 /dev/stdin "$target" <<'EOF'
#!/usr/bin/python3
import sys, dbus, os
os.environ["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"
try:
    bus = dbus.SessionBus()
    obj = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    dbus.Interface(obj, "org.freedesktop.portal.OpenURI").OpenURI("", sys.argv[1], {})
except Exception: pass
EOF
  sudo ln -sf "$target" /usr/local/bin/distrobox-host-exec
  echo "✓ Created XDG open bridge"
}

#==============================================================================
# EXPORT REMOVAL
#==============================================================================
do_remove_export() {
  echo "Removing ${EXPORT_NAME} export from host"
  if command -v distrobox-export &>/dev/null; then
    distrobox-export -d -a "${EXPORT_NAME}"
    echo "✓ Removed export"
  else
    echo "⚠ distrobox-export not available"
  fi

  local apps_dir="${HOME}/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_id)"
  local removed=0

  # Remove container-specific desktop files and their backups
  if [[ -n "$container_prefix" ]]; then
    # First pass: remove .desktop files
    for f in "${apps_dir}/${container_prefix}"-*.desktop; do
      [[ -f "$f" ]] || continue
      [[ "$(basename "$f")" == "${container_prefix}.desktop" ]] && continue
      if [[ "$f" == *"-com.brave.Browser"* ]] || [[ "$f" == *"-${PKG_NAME}"* ]]; then
        rm -f "$f"
        echo "✓ Removed: $f"
        ((removed++))
      fi
    done
    # Second pass: remove .bak files (may exist even if .desktop was already removed)
    for f in "${apps_dir}/${container_prefix}"-*.desktop.bak; do
      [[ -f "$f" ]] || continue
      # Check if it's a browser-related backup
      if [[ "$f" == *"-com.brave.Browser.desktop.bak" ]] || [[ "$f" == *"-${PKG_NAME}.desktop.bak" ]]; then
        rm -f "$f"
        echo "✓ Removed backup: $f"
        ((removed++))
      fi
    done
  fi

  # Remove Flatpak desktop copy and backup
  local flatpak_desktop="${apps_dir}/com.brave.Browser.desktop"
  if [[ -f "$flatpak_desktop" ]]; then
    rm -f "$flatpak_desktop"
    echo "✓ Removed: $flatpak_desktop"
    ((removed++))
  fi
  # Check for Flatpak backup separately
  if [[ -f "${flatpak_desktop}.bak" ]]; then
    rm -f "${flatpak_desktop}.bak"
    echo "✓ Removed backup: ${flatpak_desktop}.bak"
    ((removed++))
  fi

  [[ $removed -gt 0 ]] && update-desktop-database "${apps_dir}" 2>/dev/null
  return 0
}

#==============================================================================
# DESKTOP FILE MANAGEMENT
#==============================================================================
cleanup_superfluous_desktop_files() {
  local apps_dir="${HOME}/.local/share/applications"
  local container_prefix
  container_prefix="$(get_container_id)"
  local desktop_suffix=""

  [[ "$INSTALL_TYPE" == "beta" ]] && desktop_suffix=".beta"

  # Remove superfluous container-prefixed com.brave.Browser desktop files
  # (created by distrobox-export when it detects Flatpak-style desktop files)
  if [[ -n "$container_prefix" ]]; then
    local superfluous="${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop"
    if [[ -f "$superfluous" ]]; then
      rm -f "$superfluous"
      echo "✓ Removed superfluous: $superfluous"
    fi
  fi
}

configure_desktop_file() {
  local apps_dir="${HOME}/.local/share/applications"
  local desktop_file=""

  # 1. Clean up superfluous desktop files first
  cleanup_superfluous_desktop_files

  # 2. Locate the desktop file
  if [[ "$USE_FLATPAK" == "true" ]]; then
    local src="${HOME}/.local/share/flatpak/exports/share/applications/com.brave.Browser.desktop"
    local dest="${apps_dir}/com.brave.Browser.desktop"

    if [[ ! -f "$src" ]]; then
      echo "⚠ Flatpak desktop file not found" >&2
      return 1
    fi

    # Overwrite destination if needed (or if it's a stale copy)
    if [[ ! -f "$dest" ]] || ! diff -q "$src" "$dest" &>/dev/null; then
      install -Z -m 644 "$src" "$dest"
      echo "✓ Installed Flatpak desktop file to local applications"
    fi
    desktop_file="$dest"
  else
    local container_prefix
    container_prefix="$(get_container_id)"
    if [[ -n "$container_prefix" ]]; then
      desktop_file="${apps_dir}/${container_prefix}-${PKG_NAME}.desktop"
    else
      # Fallback for host installation
      desktop_file=$(find "${apps_dir}" -maxdepth 1 -name "*brave*.desktop" -type f | head -n1)
    fi
  fi

  if [[ ! -f "$desktop_file" ]]; then
    echo "⚠ Desktop file not found" >&2
    return 1
  fi

  # 3. Check if already configured
  if grep -q "^Exec=${WRAPPER_SCRIPT}" "$desktop_file" && grep -q "^StartupWMClass=" "$desktop_file"; then
    echo "✓ Desktop file already configured"
    return 0
  fi

  # 4. Modify Exec line
  cp "${desktop_file}" "${desktop_file}.bak"
  echo "✓ Backed up: ${desktop_file}.bak"

  # Replace distrobox/flatpak command + container args with wrapper, preserving final flags (e.g., --incognito, %U)
  # Pattern 1: Exec=<cmd> -n <container> -- <browser> [flags...] → Exec=<wrapper> [flags...]
  # Pattern 2 (fallback): Exec=<cmd> [flags...] → Exec=<wrapper> [flags...]
  sed -i -E '
    s|^Exec=[^[:space:]]+[[:space:]]+-n[[:space:]]+[^[:space:]]+[[:space:]]+--[[:space:]]+[^[:space:]]+([[:space:]]+(.*))?$|Exec='"${WRAPPER_SCRIPT}"' \2|
    t
    s|^Exec=[^[:space:]]+([[:space:]]+.*)?$|Exec='"${WRAPPER_SCRIPT}"'\1|
  ' "$desktop_file"
  # Clean up any double spaces
  sed -i 's/  \+/ /g' "$desktop_file"
  # Remove trailing space before %U or at end of line
  sed -i 's/  *%U/ %U/g; s/  *$//' "$desktop_file"
  if [[ "$USE_FLATPAK" == "true" ]]; then
    sed -i '/@@/d' "$desktop_file" # Remove lines containing Flatpak placeholders
  fi
  echo "✓ Modified Exec line"

  # 5. Add StartupWMClass after Exec= line in [Desktop Entry] section
  local wm_class="$FLATPAK_ID"
  [[ "$USE_FLATPAK" == "false" ]] && wm_class="$PKG_NAME"

  # Remove any existing StartupWMClass lines to ensure only one instance
  grep -v "^StartupWMClass=" "$desktop_file" > "${desktop_file}.tmp" && mv "${desktop_file}.tmp" "$desktop_file"

  # Insert StartupWMClass after the first Exec= line in [Desktop Entry] section
  awk -v wc="StartupWMClass=${wm_class}" '
    BEGIN { in_desktop_entry = 0; added = 0 }
    /^\[Desktop Entry\]/ { in_desktop_entry = 1 }
    /^\[/ && !/^\[Desktop Entry\]/ { in_desktop_entry = 0 }
    /^Exec=/ && in_desktop_entry && !added { print; print wc; added = 1; next }
    { print }
  ' "$desktop_file" > "${desktop_file}.tmp" && mv "${desktop_file}.tmp" "$desktop_file"
  echo "✓ Added StartupWMClass"

  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

#==============================================================================
# MAIN
#==============================================================================
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --flatpak)
      USE_FLATPAK="true"
      shift
      ;;
    --uninstall)
      UNINSTALL="true"
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    stable | beta)
      INSTALL_TYPE="$1"
      shift
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      show_help
      exit 1
      ;;
    esac
  done

  if [[ -z "$INSTALL_TYPE" ]]; then
    echo "Error: Install type (stable|beta) is required" >&2
    show_help
    exit 1
  fi
  if [[ "$USE_FLATPAK" == "true" && "$INSTALL_TYPE" != "stable" ]]; then
    echo "Error: Flatpak only supports 'stable' channel" >&2
    exit 1
  fi

  set_install_config
}

main() {
  parse_arguments "$@"

  # Handle DNF installation (requires entering container)
  if ! is_inside_container && [[ "$USE_FLATPAK" == "false" ]]; then
    if ! is_container_running; then
      echo "Error: Container '${CONTAINER_NAME}' is not running." >&2
      echo "  Start it with: distrobox start ${CONTAINER_NAME}" >&2
      exit 1
    fi
    echo "ℹ Entering container '${CONTAINER_NAME}'..."
    exec distrobox enter "${CONTAINER_NAME}" -- "${SCRIPT_PATH}" "$@"
  fi

  if [[ "$UNINSTALL" == "true" ]]; then
    do_remove_export
  else
    if [[ "$USE_FLATPAK" == "true" ]]; then
      install_flatpak
    else
      install_dnf
      create_xdg_bridge
    fi

    if ! configure_desktop_file; then
      echo "Warning: Desktop file modification had issues" >&2
    fi
  fi
}

main "$@"
