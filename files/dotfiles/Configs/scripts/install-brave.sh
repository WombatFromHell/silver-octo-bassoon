#!/usr/bin/env bash
set -euo pipefail

# Default values
WRAPPER_SCRIPT="${WRAPPER_SCRIPT:-brave-wrapper.sh}"

show_help() {
  echo "Usage: install-brave.sh [OPTIONS] [stable|beta]"
  echo ""
  echo "Options:"
  echo "  --flatpak    Install Brave via Flatpak instead of DNF (stable only)"
  echo "  --help       Show this help message"
  echo ""
  echo "Examples:"
  echo "  install-brave.sh stable              # Install stable via DNF"
  echo "  install-brave.sh beta                # Install beta via DNF"
  echo "  install-brave.sh --flatpak stable    # Install stable via Flatpak"
}

if [ -z "$1" ] || [ "$1" == "--help" ]; then
  show_help
  exit 0
fi

# Pre-flight: Verify we're running in a container with CONTAINER_ID available
check_container_env() {
  if [ ! -f /var/run/.containerenv ]; then
    echo "⚠ Warning: /var/run/.containerenv not found. CONTAINER_ID may be unavailable." >&2
    echo "  Desktop file fixes will be skipped." >&2
    return 1
  fi
  # Source the container env file to ensure CONTAINER_ID is set
  # shellcheck disable=SC1091
  source /var/run/.containerenv 2>/dev/null || true
  if [ -z "${CONTAINER_ID:-}" ]; then
    echo "⚠ Warning: CONTAINER_ID is empty after sourcing .containerenv" >&2
    return 1
  fi
  return 0
}

do_install() {
  local install_type="$1"
  local use_flatpak="${2:-false}"

  if [ "$use_flatpak" == "true" ]; then
    # Flatpak installation (only stable is available via Flatpak)
    if [ "$install_type" != "stable" ]; then
      echo "Error: Flatpak installation only supports 'stable' channel" >&2
      return 1
    fi

    local flatpak_id="com.brave.Browser"
    echo "Installing Brave via Flatpak: $flatpak_id"
    flatpak install --user -y "$flatpak_id"
    echo 0
  else
    # DNF installation
    if [ "$install_type" == "stable" ]; then
      sudo dnf install -y dnf-plugins-core &&
        sudo dnf config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
        sudo dnf install -y brave-browser &&
        distrobox-export -a brave
      echo 0
    elif [ "$install_type" == "beta" ]; then
      sudo dnf install -y dnf-plugins-core &&
        sudo dnf config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo &&
        sudo dnf install -y brave-browser-beta &&
        distrobox-export -a brave-browser-beta
      echo 0
    else
      echo 1
    fi
  fi
}

do_xdg_fix() {
  #
  # see: https://github.com/89luca89/distrobox/issues/1984
  #

  # 1. Clean broken paths to prevent "command not found" errors
  sudo rm -f /usr/local/bin/xdg-open
  sudo rm -f /usr/local/bin/distrobox-host-exec

  # 2. Create the bridge in /usr/local/bin (High Priority Location)
  sudo install -m 755 /dev/stdin /usr/local/bin/xdg-open <<'EOF'
#!/usr/bin/python3
import sys, dbus, os
# Ensure the Host D-Bus is found
os.environ["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"
try:
    url = sys.argv[1]
    bus = dbus.SessionBus()
    obj = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    iface = dbus.Interface(obj, "org.freedesktop.portal.OpenURI")
    iface.OpenURI("", url, {})
except Exception:
    pass
EOF

  # 4. Create Distrobox integration links
  sudo ln -sf /usr/local/bin/xdg-open /usr/local/bin/distrobox-host-exec
}

do_desktop_fix() {
  local install_type="$1"
  local use_flatpak="${2:-false}"
  local package_name desktop_suffix exec_prefix

  if [ "$install_type" == "stable" ]; then
    package_name="brave-browser"
    desktop_suffix=""
  elif [ "$install_type" == "beta" ]; then
    package_name="brave-browser-beta"
    desktop_suffix=".beta"
  else
    echo "Error: Unknown install type: $install_type" >&2
    return 1
  fi

  local apps_dir="${HOME}/.local/share/applications"
  local container_prefix="${CONTAINER_ID:-}"

  # Determine the Exec command based on installation method
  exec_prefix="${WRAPPER_SCRIPT}"

  # 1. Remove superfluous com.brave.Browser{.beta}.desktop file (from container exports)
  if [ -n "$container_prefix" ]; then
    local superfluous_file="${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop"
    if [ -f "$superfluous_file" ]; then
      rm -f "$superfluous_file"
      echo "✓ Removed superfluous desktop file: $superfluous_file"
    fi
  fi

  # 2. Find and modify the appropriate desktop file
  local main_desktop
  if [ "$use_flatpak" == "true" ]; then
    # For Flatpak: copy from Flatpak exports to user applications directory, then modify
    local flatpak_desktop="${HOME}/.local/share/flatpak/exports/share/applications/com.brave.Browser.desktop"
    local user_desktop="${apps_dir}/com.brave.Browser.desktop"

    if [ -f "$flatpak_desktop" ]; then
      # Check if user desktop file already exists and is already properly configured
      if [ -f "$user_desktop" ]; then
        # Check if Exec line already contains the wrapper and StartupWMClass is set correctly
        if grep -q "^Exec=${exec_prefix}" "$user_desktop" && grep -q "^StartupWMClass=com.brave.Browser" "$user_desktop"; then
          echo "✓ Desktop file already configured: $user_desktop"
          main_desktop="$user_desktop"
        else
          # Backup and replace existing unmodified desktop file
          mv "$user_desktop" "${user_desktop}.old"
          echo "✓ Backed up existing desktop file: ${user_desktop}.old"
          install -Z -m 644 "$flatpak_desktop" "$user_desktop"
          main_desktop="$user_desktop"
          echo "✓ Copied Flatpak desktop file to: $user_desktop"
        fi
      else
        # No existing desktop file, copy from Flatpak exports
        install -Z -m 644 "$flatpak_desktop" "$user_desktop"
        main_desktop="$user_desktop"
        echo "✓ Copied Flatpak desktop file to: $user_desktop"
      fi
    else
      echo "⚠ Warning: Flatpak desktop file not found: $flatpak_desktop" >&2
      return 1
    fi
  elif [ -n "$container_prefix" ]; then
    # For DNF/distrobox in container: use container-prefixed desktop file
    main_desktop="${apps_dir}/${container_prefix}-${package_name}.desktop"
  else
    # Fallback: look for any brave desktop file
    main_desktop=$(find "${apps_dir}" -maxdepth 1 -name "*brave*.desktop" -type f 2>/dev/null | head -n1)
  fi

  if [ -n "$main_desktop" ] && [ -f "$main_desktop" ]; then
    # Skip modification if already configured (Flatpak case with early detection above)
    if [ "$use_flatpak" == "true" ] && grep -q "^Exec=${exec_prefix}" "$main_desktop" && grep -q "^StartupWMClass=com.brave.Browser" "$main_desktop"; then
      echo "✓ Skipping modification (already configured)"
    else
      cp "$main_desktop" "${main_desktop}.bak"

      # Capture and preserve trailing arguments (e.g., %U, --incognito)
      if sed -i -E "s#^Exec=.*(.*)#Exec=${exec_prefix}\1#" "$main_desktop"; then
        echo "✓ Modified desktop file: $main_desktop"

        # Add/Update StartupWMClass in the first [Desktop Entry] block
        local wmclass_value
        if [ "$use_flatpak" == "true" ]; then
          wmclass_value="com.brave.Browser"
        else
          wmclass_value="${package_name}"
        fi

        awk -v wmclass="${wmclass_value}" '
          BEGIN { in_block = 0; added = 0; blank_buffer = "" }
          /^\[Desktop Entry\]/ { in_block = 1; print; next }
          /^\[/ && !/^\[Desktop Entry\]/ {
            if (in_block && !added) {
              print "StartupWMClass=" wmclass
              added = 1
            }
            in_block = 0
            print blank_buffer $0
            blank_buffer = ""
            next
          }
          /^StartupWMClass=/ && in_block {
            if (!added) {
              print "StartupWMClass=" wmclass
              added = 1
            }
            next
          }
          /^[[:space:]]*$/ && in_block && !added {
            blank_buffer = blank_buffer $0 "\n"
            next
          }
          { print blank_buffer $0; blank_buffer = "" }
          END {
            if (in_block && !added) print "StartupWMClass=" wmclass
          }
        ' "$main_desktop" >"${main_desktop}.tmp" && mv "${main_desktop}.tmp" "$main_desktop"
        echo "✓ Added StartupWMClass=${wmclass_value} to: $main_desktop"
        # rm -f "${main_desktop}.bak"
      else
        echo "⚠ Warning: sed modification failed for: $main_desktop" >&2
        mv "${main_desktop}.bak" "$main_desktop"
        return 1
      fi
    fi
  else
    echo "⚠ Warning: Desktop file not found" >&2
    if [ "$use_flatpak" == "true" ]; then
      echo "  Expected: ${HOME}/.local/share/applications/com.brave.Browser.desktop" >&2
    elif [ -n "$container_prefix" ]; then
      echo "  Expected: ${container_prefix}-${package_name}.desktop" >&2
    fi
    return 1
  fi

  # Update desktop database for immediate launcher visibility
  if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi

  return 0
}

# Main execution flow
# Parse arguments
USE_FLATPAK="false"
INSTALL_TYPE=""

while [ $# -gt 0 ]; do
  case "$1" in
  --flatpak)
    USE_FLATPAK="true"
    shift
    ;;
  stable | beta)
    INSTALL_TYPE="$1"
    shift
    ;;
  --help)
    show_help
    exit 0
    ;;
  *)
    echo "Error: Unknown argument: $1" >&2
    show_help
    exit 1
    ;;
  esac
done

if [ -z "$INSTALL_TYPE" ]; then
  echo "Error: Install type (stable|beta) is required" >&2
  show_help
  exit 1
fi

if [ "$USE_FLATPAK" == "true" ] && [ "$INSTALL_TYPE" != "stable" ]; then
  echo "Error: Flatpak installation only supports 'stable' channel" >&2
  show_help
  exit 1
fi

if do_install "$INSTALL_TYPE" "$USE_FLATPAK"; then
  do_xdg_fix

  # Run desktop fixes for Flatpak installs (host) or container-based installs
  if [ "$USE_FLATPAK" == "true" ]; then
    # Flatpak: run desktop fixes on host
    if ! do_desktop_fix "$INSTALL_TYPE" "$USE_FLATPAK"; then
      echo "Warning: Desktop file modification had issues (app may still work)" >&2
    fi
  elif check_container_env; then
    # DNF/distrobox: run desktop fixes only if we can reliably identify the container
    if ! do_desktop_fix "$INSTALL_TYPE" "$USE_FLATPAK"; then
      echo "Warning: Desktop file modification had issues (app may still work)" >&2
    fi
  else
    echo "ℹ Skipping desktop file fixes (container environment not detected)"
  fi
else
  echo "Error: something went wrong!"
  exit 1
fi
