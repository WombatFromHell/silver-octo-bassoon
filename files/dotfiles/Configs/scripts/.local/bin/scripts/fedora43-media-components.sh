#!/usr/bin/env bash

sudo dnf install -y \
  dnf-plugins-core \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm

sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 &&
  sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing &&
  sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing &&
  sudo dnf install -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin &&
  sudo dnf install -y \
    rpmfusion-free-release-tainted \
    rpmfusion-nonfree-release-tainted \
    libdvdcss \
    libavcodec-freeworld
