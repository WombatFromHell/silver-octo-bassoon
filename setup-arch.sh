#!/usr/bin/env bash

source ./common.sh

setup_user_customizations() {
	setup_system_shared
	setup_external_mounts
	setup_fonts

	if confirm "Install Nightly NeoVim and customized config?"; then
		sudo pacman -Sy --noconfirm base-devel procps-ng curl file git &&
			setup_neovim
	fi
}

main() {
	cache_creds
	setup_arch_btrfs
	setup_nvidia_tweaks
	echo "Finished!"
}

main
