#!/usr/bin/env bash

source ./common.sh
cache_creds

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
	$CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
		sudo chown -R "$USER:$USER" "$HOME"/.ssh
	chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}

	gpg --list-keys &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc
}

setup_external_mounts() {
	local mount_dirs=("Downloads" "FTPRoot" "home" "linuxgames" "linuxdata")
	local mount_types=("automount" "mount")

	for mount_type in "${mount_types[@]}"; do
		for dir in "${mount_dirs[@]}"; do
			sed 's/mnt\//var\/mnt\//g' "./systemd-automount/mnt-$dir.$mount_type" >"./systemd-automount/var-mnt-$dir.$mount_type"
			$CP "./systemd-automount/var-mnt-$dir.$mount_type" /etc/systemd/system/ &&
				sudo mkdir -p "/var/mnt/$dir"
		done
	done

	rm ./systemd-automount/var-mnt*.*mount
	sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-linuxgames-Games-swapfile.swap \
		>./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap
	$CP ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/*.swap &&
		rm ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap

	$CP "$SUPPORT"/.smb-credentials /etc/ &&
		sudo chown root:root /etc/.smb-credentials &&
		sudo chmod 0400 /etc/.smb-credentials &&
		sudo systemctl daemon-reload

	sudo systemctl enable --now var-mnt-linuxgames-Games-swapfile.swap
}

setup_user_customizations() {
	$CP -r "$SUPPORT"/bin/ "$HOME"/.local/bin/

	sudo cp -f /etc/environment /etc/environment.bak
	sudo cp -f ./etc/environment /etc/environment

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

	$CP ./etc-default/grub /etc/default/grub &&
		sudo touch /boot/grub2/.grub2-blscfg-supported &&
		ujust regenerate-grub

	# setup a Trash dir in /var for yazi (just in case)
	var_trash_path="/var/.Trash-$(id -u)"
	sudo mkdir -p "$var_trash_path" &&
		sudo chown -R "$USER":"$USER" "$var_trash_path"

	run_if_confirmed "Install common user fonts?" install_fonts
	setup_package_manager
	run_if_confirmed "Install customized NeoVim config?" setup_neovim
	run_if_confirmed "Install AppImages?" install_appimages
}

install_appimages() {
	appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.AppImage "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.AppImage
}

install_fonts() {
	mkdir -p ~/.fonts &&
		tar xzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
		fc-cache -f
}

setup_package_manager() {
	local brew
	brew="$(which brew)"

	if [ -n "$brew" ] && confirm "Install Brew and some common utils?"; then
		"$brew" install eza fd rdfind ripgrep fzf bat lazygit fish stow zoxide
	elif confirm "Install Nix as an alternative to Brew?"; then
		curl --proto '=https' --tlsv1.2 -sSf -L https://install.lix.systems/lix | sh -s -- install ostree
	fi
}

setup_neovim() {
	local url="https://github.com/MordechaiHadad/bob/releases/download/v4.0.3/bob-linux-x86_64.zip"
	local outdir="/tmp"
	local outpath="$outdir/bob-linux-x86_64"
	local basedir="$HOME/.local"
	local target="$basedir/bin"
	local global_target="/usr/local/bin"

	curl -sfSLO --output-dir "$outdir" "$url"
	unzip "${outpath}.zip" -d "$outdir"
	$CP "${outpath}/bob" "$target"
	chmod 0755 "$target"/bob
	"$target"/bob use nightly

	rm -rf "$outpath" &&
		sudo rm -f "$global_target"/nvim &&
		sudo ln -sf "$basedir"/share/bob/nvim-bin/nvim "$global_target"/nvim

	if confirm "Wipe any existing neovim config and download our distribution?"; then
		rm -rf "$HOME"/.config/nvim "$basedir"/share/nvim "$basedir"/cache/nvim "$basedir"/state/nvim
		git clone git@github.com:WombatFromHell/lazyvim.git "$HOME"/.config/nvim
	fi
}

setup_distrobox() {
	chmod +x ./distrobox/*.sh
	distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini
	# ./distrobox/brave-export-fix.sh
}

setup_flatpak() {
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

	flatpak install --user --noninteractive \
		com.github.zocker_160.SyncThingy \
		net.agalwood.Motrix

	if confirm "Install Flatpak version of Brave browser?"; then
		flatpak install --user --noninteractive com.brave.Browser
		chmod 0755 ./support/brave-flatpak-fix.sh
		"$SUPPORT"/brave-flatpak-fix.sh
	fi

	run_if_confirmed "Fix Firefox Flatpak overrides (for misc support)?" fix_firefox_overrides
}

fix_firefox_overrides() {
	flatpak override --user --reset org.mozilla.firefox
	flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications org.mozilla.firefox

	outdir="$HOME/.var/app/org.mozilla.firefox/dri"
	mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
	$CP /usr/lib64/dri/nvidia_drv_video.so "$outdir"

	flatpak --system --noninteractive install \
		runtime/org.freedesktop.Platform.ffmpeg-full//23.08

	flatpak override --user \
		--env=MOZ_DISABLE_RDD_SANDBOX=1 \
		--env=LIBVA_DRIVERS_PATH="$outdir" \
		--env=LIBVA_DRIVER_NAME=nvidia \
		--env=NVD_BACKEND=direct \
		org.mozilla.firefox

	flatpak override --user --filesystem=xdg-run/app/org.keepassxc.KeePassXC org.mozilla.firefox
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
