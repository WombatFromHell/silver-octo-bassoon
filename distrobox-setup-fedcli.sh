#!/usr/bin/env bash

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
  echo "Error: Cannot obtain sudo credentials!"
  exit 1
fi

sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/podman &&
  sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/docker

sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-"$(rpm -E %fedora)".noarch.rpm &&
  sudo dnf install -y https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-"$(rpm -E %fedora)".noarch.rpm
# sudo dnf config-manager --add-repo=https://negativo17.org/repos/fedora-nvidia.repo
sudo dnf update --refresh -y &&
  sudo dnf --releasever=rawhide upgrade -y xorg-x11-server-Xwayland \
    sudo dnf install -y nvidia-driver libva-nvidia-driver libva-utils vdpauinfo cuda gstreamer1-vaapi gstreamer1-plugins-bad-free
# make a link to GLX on the host for EGL support
sudo ln -sf /var/run/host/usr/lib/libGLX_nvidia.so.0 /usr/lib/libGLX_nvidia.so.0

# install brave browser repo
sudo dnf config-manager --add-repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo &&
  sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc &&
  sudo dnf install -y brave-browser git

if command -v brave-browser &>/dev/null; then
  # export all the things
  distrobox-export -a brave-browser

  exit 0
fi
exit 1
