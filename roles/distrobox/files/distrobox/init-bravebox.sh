#!/bin/bash

# Install RPM Fusion repos if not present
if ! rpm -q rpmfusion-free-release &>/dev/null; then
	dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
	dnf install -y https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

# Install dnf-plugins-core
dnf install -y dnf-plugins-core

# Add Brave repo if not present
if ! grep -q "brave-browser-rpm-release" /etc/yum.repos.d/*.repo; then
	dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
fi

# Install graphics drivers and Brave
dnf install -y mesa-dri-drivers mesa-libGL mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers
dnf install -y brave-browser

# Multimedia group and codecs
dnf group install -y multimedia --allowerasing
dnf swap -y ffmpeg-free ffmpeg --allowerasing
dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld
dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
dnf update -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
