#!/usr/bin/env bash

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
  echo "Error: Cannot obtain sudo credentials!"
  exit 1
fi

sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-"$(rpm -E %fedora)".noarch.rpm &&
  sudo dnf install -y https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-"$(rpm -E %fedora)".noarch.rpm
# add some codecs to better support libva-nvidia-driver
sudo dnf update --refresh -y && \
  sudo dnf install -y libva-utils gstreamer1-vaapi gstreamer1-plugins-bad-free
# make a link to GLX on the host for EGL support
sudo ln -sf /var/run/host/usr/lib/libGLX_nvidia.so.0 /usr/lib/libGLX_nvidia.so.0

# install brave browser repo
sudo dnf4 config-manager --add-repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo && \
  sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc && \
  sudo dnf install -y brave-browser

# install vscode repo
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" | \
  sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
sudo dnf check-update && \
  sudo dnf install -y code
# make a link to the system's pinentry for signing support
sudo ln -s /usr/bin/distrobox-host-exec /usr/bin/pinentry-qt

# install firefox as well
sudo dnf install -y firefox

if command -v brave-browser &>/dev/null; then
  distrobox-export -a brave-browser
else
  exit 1
fi
if command -v code &>/dev/null; then
  distrobox-export -a code
else
  exit 1
fi
if command -v firefox &>/dev/null; then
  distrobox-export -a firefox
else
  exit 1
fi
