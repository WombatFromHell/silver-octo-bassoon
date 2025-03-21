#!/usr/bin/env bash

source ./lib/common.sh
source ./lib/install.sh
cache_creds

setup_system_shared
setup_external_mounts
setup_package_manager
setup_flatpak
setup_distrobox

echo "Finished!"
