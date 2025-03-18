#!/usr/bin/env bash

source ./common.sh
cache_creds

setup_arch_btrfs
setup_system_shared
setup_package_manager
setup_flatpak
setup_distrobox
setup_qemu

echo "Finished!"
