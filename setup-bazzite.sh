#!/usr/bin/env bash

source ./common.sh
cache_creds

main() {
	# Run the installation steps with confirmations
	run_if_confirmed "Add kernel args for OpenRGB Gigabyte Mobo support?" setup_kernel_args
	run_if_confirmed "Setup SSH/GPG keys and config?" setup_ssh_gpg
	run_if_confirmed "Setup external mounts?" setup_external_mounts
	run_if_confirmed "Perform user-specific customizations?" setup_user_customizations
	run_if_confirmed "Perform assembly and customization of Distrobox containers?" setup_distrobox
	run_if_confirmed "Setup Flatpak repo and add common apps?" setup_flatpak
	run_if_confirmed "Fix libva-nvidia-driver for Flatpak version of Firefox?" fix_firefox_video

	echo "Finished!"
}

# Wrapper function to run a task if confirmed
run_if_confirmed() {
	local prompt="$1"
	local func="$2"

	if confirm "$prompt"; then
		$func
	fi
}

setup_kernel_args() {
	rpm-ostree kargs --append=amd_pstate=active --append=acpi_enforce_resources=lax
}

setup_ssh_gpg() {
	# SSH setup
	$CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
		sudo chown -R "$USER:$USER" "$HOME"/.ssh
	chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}

	# GPG setup
	gpg --list-keys &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc

	$CP "$SUPPORT"/.gnupg/gpg-agent.conf "$HOME"/.gnupg/ &&
		gpg-connect-agent reloadagent /bye
}

setup_external_mounts() {
	local mount_dirs=("Downloads" "FTPRoot" "home" "linuxgames" "linuxdata")
	local mount_types=("automount" "mount")

	# Create systemd mount units
	for mount_type in "${mount_types[@]}"; do
		for dir in "${mount_dirs[@]}"; do
			sed 's/mnt\//var\/mnt\//g' "./systemd-automount/mnt-$dir.$mount_type" >"./systemd-automount/var-mnt-$dir.$mount_type"
			$CP "./systemd-automount/var-mnt-$dir.$mount_type" /etc/systemd/system/ &&
				sudo mkdir -p "/var/mnt/$dir"
		done
	done

	rm ./systemd-automount/var-mnt*.*mount

	# Setup swap file
	sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-linuxgames-Games-swapfile.swap \
		>./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap
	$CP ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/*.swap &&
		rm ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap

	# SMB credentials setup
	$CP "$SUPPORT"/.smb-credentials /etc/ &&
		sudo chown root:root /etc/.smb-credentials &&
		sudo chmod 0400 /etc/.smb-credentials &&
		sudo systemctl daemon-reload

	# Enable swap
	sudo systemctl enable --now var-mnt-linuxgames-Games-swapfile.swap
}

setup_user_customizations() {
	# Copy user files
	$CP -r "$SUPPORT"/bin/ "$HOME"/.local/bin/ &&
		$CP -r "$SUPPORT"/.gitconfig "$HOME"/

	# System config updates
	sudo cat ./etc/environment | sudo tee -a /etc/environment
	$CP ./etc-X11/Xwrapper.config /etc/X11/ &&
		$CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

	# Scripts setup
	$CP ./usr-local-bin/*.sh /usr/local/bin/ &&
		sudo chown root:root /usr/local/bin/*.sh &&
		sudo chmod 0755 /usr/local/bin/*.sh

	# System services setup
	$CP ./etc-systemd/system/* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/{fix-wakeups.service,nvidia-tdp.*} &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now fix-wakeups.service &&
		sudo systemctl enable --now nvidia-tdp.service

	# Systemd suspend configuration
	sudo rsync -rvh --chown=root:root --chmod=D755,F644 ./etc-systemd/system/systemd-{homed,suspend}.service.d /etc/systemd/system/ &&
		sudo systemctl daemon-reload

	# User services setup
	mkdir -p "$HOME"/.config/systemd/user/
	$CP ./systemd-user/*.service "$HOME"/.config/systemd/user/
	systemctl --user daemon-reload &&
		chmod 0755 "$HOME"/.local/bin/*
	systemctl --user enable --now on-session-state.service
	systemctl --user enable --now openrgb-lightsout.service

	# Run optional customizations
	run_if_confirmed "Install common user fonts?" install_fonts
	setup_package_manager
	run_if_confirmed "Install customized NeoVim config?" setup_neovim
}

install_fonts() {
	mkdir -p ~/.fonts &&
		tar xvzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
		fc-cache -fv
}

setup_package_manager() {
	if confirm "Install Brew and some common utils?"; then
		if command -v brew >/dev/null; then
			brew install eza fd ripgrep fzf bat lazygit
		else
			echo "Error! Cannot find 'brew'!"
			exit 1
		fi
	elif confirm "Install Nix as an alternative to Brew?"; then
		chmod +x "$SUPPORT"/lix-installer
		"$SUPPORT"/lix-installer install ostree
		echo && echo "Reminder: deploy dotfiles and do a 'home-manager switch'!"
	fi
}

setup_neovim() {
	rm -rf "$HOME"/.config/nvim "$HOME"/.local/share/nvim "$HOME"/.local/cache/nvim
	git clone git@github.com:WombatFromHell/lazyvim.git "$HOME"/.config/nvim

	# Install AppImages
	appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.* "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.*

	# Link neovim
	nvim_local_path="$HOME/AppImages/nvim.appimage"
	sudo ln -sf "$nvim_local_path" /usr/local/bin/nvim &&
		ln -sf "$nvim_local_path" "$HOME"/.local/bin/nvim
}

setup_distrobox() {
	chmod +x ./distrobox/*.sh

	# Setup development container
	distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini &&
		./distrobox/brave-export-fix.sh
}

setup_flatpak() {
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

	# Install common apps
	flatpak install --user --noninteractive \
		com.vysp3r.ProtonPlus \
		com.github.zocker_160.SyncThingy

	# Fix Firefox notifications
	flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications org.mozilla.firefox

	# Setup Brave browser if requested
	if confirm "Install Flatpak version of Brave browser?"; then
		flatpak install --user --noninteractive com.brave.Browser
		chmod +x ./support/brave-flatpak-fix.sh
		./support/brave-flatpak-fix.sh
	fi
}

fix_firefox_video() {
	outdir="$HOME/.var/app/org.mozilla.firefox/dri"
	mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
	unzip "$SUPPORT"/libva-nvidia-driver_git-0.0.13.zip -d "$outdir"
	flatpak override --user --env=LIBVA_DRIVERS_PATH="$outdir" org.mozilla.firefox
	flatpak --system --noninteractive remove org.mozilla.firefox &&
		flatpak --user --noninteractive install org.mozilla.firefox org.freedesktop.Platform.ffmpeg-full
}

main
