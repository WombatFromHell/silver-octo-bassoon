#!/usr/bin/env bash
set -euo pipefail

sudo rm -f /etc/systemd/system/nix-daemon*.*
sudo install -Z -m 0644 \
  /nix/var/nix/profiles/per-user/root/profile/lib/systemd/system/nix-daemon.socket \
  /etc/systemd/system/nix-daemon.socket
sudo install -Z -m 0644 \
  /nix/var/nix/profiles/per-user/root/profile/lib/systemd/system/nix-daemon@.service \
  /etc/systemd/system/nix-daemon@.service

# ensure .links (which includes the nix dynamic linker) also labels binaries
sudo semanage fcontext -a -t bin_t "/nix/store/.links(/.*)?"
sudo restorecon -Rv /nix

ls -laZ /etc/systemd/system/nix-daemon*.* "$(which nix-daemon)" &&
  sudo systemctl daemon-reload &&
  sudo systemctl enable nix-daemon.socket &&
  sudo systemctl restart nix-daemon.socket
