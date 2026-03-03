#!/usr/bin/env bash
set -euxo pipefail

if [ -z "$1" ] || [ "$1" == "--help" ]; then
  echo "Usage: install-brave.sh [stable|beta]"
  exit 0
fi

do_install() {
  if [ "$1" == "stable" ]; then
    sudo dnf install dnf-plugins-core &&
      sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
      sudo dnf install -y brave-browser &&
      distrobox-export -a brave
    echo 0
  elif [ "$1" == "beta" ]; then
    sudo dnf install dnf-plugins-core &&
      sudo dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-beta.s3.brave.com/brave-browser-beta.repo &&
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
  sudo tee /usr/local/bin/xdg-open <<'EOF'
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

  # 3. Set execution permissions
  sudo chmod 755 /usr/local/bin/xdg-open

  # 4. Create Distrobox integration links
  sudo ln -sf /usr/local/bin/xdg-open /usr/local/bin/distrobox-host-exec

  # 5. FIX FOR ICONS: Global Variable in /etc/environment
  # This ensures that GUI apps (like Antigravity) see the bridge even when opened via the menu
  sudo sh -c "echo 'BROWSER=\"/usr/local/bin/xdg-open\"' >> /etc/environment"

  # 6. Update PATH for the current terminal session (Bash/Fish/Zsh)
  export PATH="/usr/local/bin:$PATH"
  export BROWSER="/usr/local/bin/xdg-open"
  hash -r 2>/dev/null || true
}

if do_install "$1"; then
  do_xdg_fix
else
  echo "Error: something went wrong!"
  exit 1
fi
