#!/usr/bin/env bash
set -euo pipefail

if [ -z "$1" ] || [ "$1" == "--help" ]; then
  echo "Usage: install-brave.sh [stable|beta]"
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
  if [ "$1" == "stable" ]; then
    sudo dnf install -y dnf-plugins-core &&
      sudo dnf config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
      sudo dnf install -y brave-browser &&
      distrobox-export -a brave
    echo 0
  elif [ "$1" == "beta" ]; then
    sudo dnf install -y dnf-plugins-core &&
      sudo dnf config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo &&
      sudo dnf install -y brave-browser-beta &&
      distrobox-export -a brave-browser-beta
    echo 0
  else
    echo 1
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
  local package_name desktop_suffix

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
  local container_prefix="${CONTAINER_ID}"

  # 1. Remove superfluous com.brave.Browser{.beta}.desktop file
  local superfluous_file="${apps_dir}/${container_prefix}-com.brave.Browser${desktop_suffix}.desktop"
  if [ -f "$superfluous_file" ]; then
    rm -f "$superfluous_file"
    echo "✓ Removed superfluous desktop file: $superfluous_file"
  fi

  # 2. Modify the main desktop file to use bravebox-wrapper.sh
  local main_desktop="${apps_dir}/${container_prefix}-${package_name}.desktop"
  if [ -f "$main_desktop" ]; then
    cp "$main_desktop" "${main_desktop}.bak"

    # Capture and preserve trailing arguments (e.g., %U, --incognito)
    if sed -i -E "s#^Exec=.*distrobox-enter[[:space:]]+-n[[:space:]]+[^[:space:]]+[[:space:]]+--[[:space:]]+/usr/bin/${package_name}(.*)#Exec=bravebox-wrapper.sh\1#" "$main_desktop"; then
      echo "✓ Modified desktop file: $main_desktop"

      # Add/Update StartupWMClass in the first [Desktop Entry] block (ensuring only one exists)
      # This ensures proper window grouping in taskbars/launchers
      awk -v wmclass="${package_name}" '
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
      echo "✓ Added StartupWMClass=${package_name} to: $main_desktop"
      # rm -f "${main_desktop}.bak"
    else
      echo "⚠ Warning: sed modification failed for: $main_desktop" >&2
      mv "${main_desktop}.bak" "$main_desktop"
      return 1
    fi
  else
    echo "⚠ Warning: Desktop file not found: $main_desktop" >&2
    echo "  Expected: ${container_prefix}-${package_name}.desktop" >&2
    return 1
  fi

  # Update desktop database for immediate launcher visibility
  if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi

  return 0
}

# Main execution flow
if do_install "$1"; then
  do_xdg_fix

  # Run desktop fixes only if we can reliably identify the container
  if check_container_env; then
    if ! do_desktop_fix "$1"; then
      echo "Warning: Desktop file modification had issues (app may still work)" >&2
    fi
  else
    echo "ℹ Skipping desktop file fixes (container environment not detected)"
  fi
else
  echo "Error: something went wrong!"
  exit 1
fi
