#!/usr/bin/env bash

NV_DRIVER_VER="565.77"

sudo apt update &&
	sudo apt install -y \
		wget gpg git curl apt-transport-https \
		xdg-desktop-portal-kde flatpak-xdg-utils \
		libfuse2 fish bat eza fzf rdfind fd-find ripgrep zoxide pulseaudio

# Install VSCode repo
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >packages.microsoft.gpg
sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
rm -f packages.microsoft.gpg

# Install Brave browser repo
wget -q https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg -O- | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null

# Install Firefox-dev browser repo
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee -a /etc/apt/sources.list.d/mozilla.list >/dev/null
echo '
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
' | sudo tee /etc/apt/preferences.d/mozilla >/dev/null

# install vscode and brave-browser
sudo apt update &&
	sudo apt install -y brave-browser code firefox-devedition

# make sure appropriate media codecs are installed for firefox to use
deb_src_target="/etc/apt/sources.list.d/debian.sources"
sudo cp -f "$deb_src_target" "${deb_src_target}.bak"
sudo sed -i 's/Components: main/Components: main contrib non-free/' "$deb_src_target"
sudo apt update &&
	sudo apt install -y ffmpeg

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
sudo ln -sf /usr/bin/batcat /usr/bin/bat

# try to fix xdg-open in vscode (when interacting with flatpak firefox)
sudo ln -sf /usr/bin/xdg-open /usr/bin/xdg-open-local
sudo ln -sf /usr/libexec/flatpak-xdg-utils/xdg-open /usr/bin/xdg-open

# try to install matching nvidia drivers
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/modprobe
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/depmod
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/lsmod
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/rmmod
# only install driver libs/utils and not kernel modules
sudo apt install -y build-essential gcc-multilib libglvnd-dev pkg-config mesa-utils vulkan-tools nvidia-vaapi-driver vainfo
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_DRIVER_VER}/NVIDIA-Linux-x86_64-${NV_DRIVER_VER}.run
chmod +x NVIDIA-Linux-x86_64-${NV_DRIVER_VER}.run
sudo ./NVIDIA-Linux-x86_64-${NV_DRIVER_VER}.run --no-kernel-modules --no-x-check -s

# export vscode, brave-browser, and firefox-dev
distrobox-export -a code
distrobox-export -a brave-browser
distrobox-export -a firefox-devedition
