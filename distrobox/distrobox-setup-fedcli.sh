#!/usr/bin/env bash

sudo dnf update -y &&
	sudo dnf install -y \
		wget gpg git curl fish bat fzf eza rdfind fd-find ripgrep zoxide \
		xdg-desktop-portal-kde flatpak-xdg-utils fuse2 \
		egl-utils glx-utils vulkan-tools vainfo dn4 pciutils

# setup rpmfusion repo
sudo dnf install -y \
	https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
	https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

# setup negativo17 repo
sudo dnf config-manager addrepo --from-repofile=https://negativo17.org/repos/fedora-nvidia.repo
sudo dnf install -y nvidia-driver nvidia-driver-cuda libva-nvidia-driver

# install optional codecs and media dependencies
sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y
sudo dnf4 install -y @multimedia --allowerasing --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin

# setup firefox-dev repo and dependencies
#sudo dnf copr enable -y the4runner/firefox-dev
#sudo dnf install -y firefox-dev

# make some critical symlinks
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/podman
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/podman-compose
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/lazygit
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/getenforce
# symlink wl-clipboard
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/wl-copy
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/wl-paste
# symlink podman and bat
sudo ln -sf /usr/bin/podman /usr/bin/docker
sudo ln -sf /usr/bin/podman /usr/bin/docker-compose
# try to fix xdg-open in vscode (when interacting with flatpak firefox)
sudo ln -sf /usr/bin/xdg-open /usr/bin/xdg-open-local
sudo ln -sf /usr/libexec/flatpak-xdg-utils/xdg-open /usr/bin/xdg-open
