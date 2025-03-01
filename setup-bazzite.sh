#!/usr/bin/env bash

source ./common.sh
cache_creds

main() {
	run_if_confirmed "Add kernel args for OpenRGB Gigabyte Mobo support?" setup_kernel_args
	run_if_confirmed "Setup SSH/GPG keys and config?" setup_ssh_gpg
	run_if_confirmed "Setup external mounts?" setup_external_mounts
	run_if_confirmed "Perform user-specific customizations?" setup_user_customizations
	run_if_confirmed "Perform assembly and customization of Distrobox containers?" setup_distrobox
	run_if_confirmed "Setup Flatpak repo and add common apps?" setup_flatpak
	echo "Finished!"
}

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
	$CP -r "$SUPPORT"/bin/ "$HOME"/.local/bin/ &&
		$CP -r "$SUPPORT"/.gitconfig "$HOME"/

	sudo cat ./etc/environment | sudo tee -a /etc/environment

	$CP ./usr-local-bin/*.* /usr/local/bin/ &&
		sudo chown root:root /usr/local/bin/*.* &&
		sudo chmod 0755 /usr/local/bin/*.*

	$CP ./etc-systemd/system/* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/{fix-wakeups.service,nvidia-tdp.*} &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now fix-wakeups.service &&
		sudo systemctl enable --now nvidia-tdp.service

	sudo rsync -rvh --chown=root:root --chmod=D755,F644 ./etc-systemd/system/systemd-{homed,suspend}.service.d /etc/systemd/system/ &&
		sudo systemctl daemon-reload

	mkdir -p "$HOME"/.config/systemd/user/
	$CP ./systemd-user/*.service "$HOME"/.config/systemd/user/
	systemctl --user daemon-reload &&
		chmod 0755 "$HOME"/.local/bin/*
	systemctl --user enable --now on-session-state.service
	systemctl --user enable --now openrgb-lightsout.service

	run_if_confirmed "Install common user fonts?" install_fonts
	setup_package_manager
	run_if_confirmed "Install customized NeoVim config?" setup_neovim
	run_if_confirmed "Install AppImages?" install_appimages
}

install_appimages() {
	appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.* "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.*
}

install_fonts() {
	mkdir -p ~/.fonts &&
		tar xvzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
		fc-cache -fv
}

setup_package_manager() {
	local brew
	brew="$(check_cmd "brew")"

	if [ -n "$brew" ] && confirm "Install Brew and some common utils?"; then
		"$brew" install eza fd rdfind ripgrep fzf bat lazygit fish
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
	distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini &&
		./distrobox/brave-export-fix.sh
}

setup_flatpak() {
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

	flatpak install --user --noninteractive \
		com.github.zocker_160.SyncThingy

	flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications org.mozilla.firefox

	if confirm "Install Flatpak version of Brave browser?"; then
		flatpak install --user --noninteractive com.brave.Browser
		chmod 0755 ./support/brave-flatpak-fix.sh
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
