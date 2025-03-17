#!/usr/bin/env bash

source ./common.sh
cache_creds

setup_user_customizations() {
	local env_path="/etc/environment"
	sudo cp -f "${env_path}" "${env_path}".bak
	sudo cp -f ."${env_path}" "${env_path}"

	local jswake="/etc/xdg/autostart/joystickwake.desktop"
	if [ -f "$jswake" ]; then
		rm -f "$jswake" # remove bazzite's joystickwake autostart
	fi

	mkdir -p /usr/local/bin &&
		$CP ./usr-local-bin/* /usr/local/bin/ &&
		sudo chown root:root /usr/local/bin/* &&
		sudo chmod 0755 /usr/local/bin/*

	$CP ./etc-systemd/system/* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/{fix-wakeups.service,nvidia-tdp.*} &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now fix-wakeups.service &&
		sudo systemctl enable --now nvidia-tdp.service

	mkdir -p "$HOME"/.config/systemd/user/
	$CP ./systemd-user/*.service "$HOME"/.config/systemd/user/
	systemctl --user daemon-reload
	chmod 0755 "$HOME"/.local/bin/*

	$CP ./etc-sudoers.d/tuned /etc/sudoers.d/tuned

	# fix duplicate ostree entries in grub
	$CP ./etc-default/grub /etc/default/grub &&
		sudo touch /boot/grub2/.grub2-blscfg-supported &&
		ujust regenerate-grub

	# setup a Trash dir in /var for yazi (just in case)
	local var_trash_path
	var_trash_path="/var/.Trash-$(id -u)"
	sudo mkdir -p "$var_trash_path" &&
		sudo chown -R "$USER":"$USER" "$var_trash_path"

	run_if_confirmed "Install common user fonts?" install_fonts
	setup_package_manager
	run_if_confirmed "Install customized NeoVim config?" setup_neovim
	run_if_confirmed "Install AppImages?" install_appimages
}

main() {
	run_if_confirmed "Add kernel args for OpenRGB Gigabyte Mobo support?" setup_kernel_args
	run_if_confirmed "Setup SSH/GPG keys and config?" setup_ssh_gpg
	run_if_confirmed "Setup external mounts?" setup_external_mounts
	run_if_confirmed "Perform user-specific customizations?" setup_user_customizations
	run_if_confirmed "Perform assembly and customization of Distrobox containers?" setup_distrobox
	run_if_confirmed "Setup Flatpak repo and add common apps?" setup_flatpak
	echo "Finished!"
}

main
