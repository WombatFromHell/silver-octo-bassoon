#!/usr/bin/env bash

SUPPORT="./support"
CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"
PACMAN=(sudo pacman -Sy --needed --noconfirm)

# cache credentials
cache_creds() {
	sudo -v &
	pid=$!
	wait $pid
	if [ "$?" -eq 130 ]; then
		echo "Error: Cannot obtain sudo credentials!"
		exit 1
	fi
}

confirm() {
	read -r -p "$1 (y/N) " response
	case "$response" in
	[yY])
		return 0
		;;
	*)
		echo "Action aborted!"
		return 1
		;;
	esac
}

run_if_confirmed() {
	local prompt="$1"
	local func="$2"

	if confirm "$prompt"; then
		$func
	fi
}

check_cmd() {
	local cmd
	cmd="$(command -v "$1")"
	if [ -n "$cmd" ]; then
		echo "$cmd"
	else
		return 1
	fi
}

is_archlike() {
	local os="$1"
	local archlikes=("Arch" "CachyOS")

	for os_name in "${archlikes[@]}"; do
		if [ "$os_name" == "$os" ]; then
			return 0
		fi
	done
	return 1
}
check_os() {
	local os
	os="$(grep "NAME=" /etc/os-release | head -n 1 | cut -d\" -f2 | cut -d' ' -f1)"
	# check fallback in case of macOS
	local fallback
	fallback="$(uname -a | cut -d' ' -f1)"

	local supported=("Arch" "Bazzite")

	for distro in "${supported[@]}"; do
		if is_archlike "$os"; then
			echo "Arch"
			return
		elif [[ "$os" == "$distro" ]]; then
			echo "$os"
			return
		fi
	done

	if [ -n "$fallback" ] && [ "$fallback" == "Darwin" ]; then
		echo "$fallback"
	else
		echo "Unknown"
	fi
}
OS="$(check_os)"

update_grub_cmdline() {
	local text_to_add="$1"
	local target_file="/etc/default/grub"
	local backup_file="${target_file}.bak"
	local variable_name="GRUB_CMDLINE_LINUX_DEFAULT"

	# Create a backup of the target file
	if ! sudo cp -f "$target_file" "$backup_file"; then
		echo "Error: Failed to create backup file."
		return 1
	fi
	# Check if the text already exists in the target file
	if grep -q "$text_to_add" "$target_file"; then
		echo "Text already exists in $target_file. No changes made."
		return 1
	fi

	sudo sed -i "s/^$variable_name=\"\(.*\)\"/$variable_name=\"\1 $text_to_add\"/" "$target_file"
}

bootstrap_arch() {
	if [ "$OS" = "Arch" ]; then
		"${PACMAN[@]}" base-devel procps-ng curl \
			file git unzip rsync unzip \
			sudo nano libssh2 curl \
			libcurl-gnutls
	fi
}

setup_arch_btrfs() {
	local ROOT_FS_TYPE
	ROOT_FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
	local ROOT_FS_DEV
	ROOT_FS_DEV=$(df -T / | awk 'NR==2 {print $1}')
	local ROOT_FS_UUID
	ROOT_FS_UUID=$(sudo blkid -s UUID -o value "$ROOT_FS_DEV")
	local HOME_FS_TYPE
	HOME_FS_TYPE=$(df -T /home | awk 'NR==2 {print $2}')

	local is_systemd_boot
	is_systemd_boot="$(sudo ls -l /boot/loader)"
	is_systemd_boot="$?"
	if [ "$is_systemd_boot" -eq 0 ]; then
		echo "Error: systemd-boot detected, skipping grub-btrfs setup!"
		return 1
	fi

	if [ "$ROOT_FS_TYPE" = "btrfs" ] && confirm "Install grub-btrfsd and snapper?"; then
		echo "IMPORTANT: Root (/) and Home (/home) must be mounted on @ and @home respectively!"
		echo "!! Ensure you have a root (subvolid=5) subvol for @var, @var_tmp, and @var_log before continuing !!"
		btrfs_mount="/mnt/btrfs"

		sudo mkdir -p "$btrfs_mount" &&
			sudo mount -o subvolid=5,noatime "$ROOT_FS_DEV" "$btrfs_mount" &&
			sudo btrfs sub cr "$btrfs_mount"/@snapshots
		echo "UUID=$ROOT_FS_UUID /.snapshots btrfs subvol=/@snapshots/root,defaults,noatime,compress=zstd,commit=120 0 0" | sudo tee -a /etc/fstab

		"${PACMAN[@]}" grub-btrfs snap-pac inotify-tools

		sudo snapper -c root create-config / &&
			sudo mv "$btrfs_mount/@/.snapshots" "$btrfs_mount/@snapshots/root"

		snapper_root_conf="/etc/snapper/configs/root"
		sudo cp -f ./etc-snapper-configs/root "$snapper_root_conf" &&
			sudo chown root:root "$snapper_root_conf" &&
			sudo chmod 0644 "$snapper_root_conf"

		if [ "$HOME_FS_TYPE" = "btrfs" ] &&
			confirm "Detected /home running on a btrfs subvolume, should we setup snapper for it?"; then
			sudo snapper -c home create-config /home &&
				sudo mv "$btrfs_mount/@home/.snapshots" "$btrfs_mount/@snapshots/home"

			echo "UUID=$ROOT_FS_UUID /home/.snapshots btrfs subvol=/@snapshots/home,defaults,noatime,compress=zstd,commit=120 0 0" | sudo tee -a /etc/fstab

			snapper_home_conf="/etc/snapper/configs/home"
			sudo cp -f ./etc-snapper-configs/home "$snapper_home_conf" &&
				sudo chown root:root "$snapper_home_conf" &&
				sudo chmod 0644 "$snapper_home_conf"
		fi

		sudo systemctl daemon-reload &&
			sudo systemctl restart --now snapperd.service &&
			sudo systemctl enable snapper-{cleanup,backup,timeline}.timer

		# regenerate grub-btrfs snapshots
		sudo grub-mkconfig -o /boot/grub/grub.cfg
	fi
}

setup_ssh_gpg() {
	local src="$SUPPORT/.ssh"
	local tgt="$HOME/.ssh"

	if [ -r "$src" ] && [ -r "$src/gnupg-keys/public-key.asc" ] &&
		confirm "Setup SSH/GPG keys and config?"; then
		$CP "$src"/{id_rsa,id_rsa.pub,config} "$tgt" &&
			sudo chown -R "$USER:$USER" "$tgt"
		chmod 0400 "$tgt"/{id_rsa,id_rsa.pub}

		gpg --list-keys &&
			gpg --import "$src"/gnupg-keys/public-key.asc &&
			gpg --import "$src"/gnupg-keys/private-key.asc
	else
		echo "Error: unable to find '$src', skipping SSH/GPG setup!"
	fi
}

setup_chaotic_aur() {
	if [ "$OS" == "Arch" ] && confirm "Setup Chaotic AUR?"; then
		sudo pacman-key --init &&
			sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com &&
			sudo pacman-key --lsign-key 3056513887B78AEB &&
			sudo pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' &&
			sudo pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' &&
			sudo cp -f /etc/pacman.conf /etc/pacman.conf.pre-chaotic-aur.bak &&
			if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
				cat <<EOF | sudo tee -a "/etc/pacman.conf"

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
			fi
	else
		echo "Error: incompatible OS, skipping Chaotic AUR setup!"
	fi
}

install_neovim_config() {
	local basedir="$HOME/.local"
	local git
	git="$(check_cmd git)"

	confirm "Wipe any existing NeoVim config and download custom distribution?" &&
		{
			if [ -n "$git" ]; then
				rm -rf "$HOME"/.config/nvim "$basedir"/share/nvim "$basedir"/cache/nvim "$basedir"/state/nvim
				"$git" clone git@github.com:WombatFromHell/lazyvim.git "$HOME"/.config/nvim
			elif [ -z "$git" ]; then
				echo "Error: unable to find 'git', skipping NeoVim config installation!"
			fi
		}
}
setup_neovim() {
	local url="https://github.com/MordechaiHadad/bob/releases/download/v4.0.3/bob-linux-x86_64.zip"
	local outdir="/tmp"
	local outpath="$outdir/bob-linux-x86_64"
	local basedir="$HOME/.local"
	local target="$basedir/bin"
	local global_target="/usr/local/bin"

	confirm "Install NeoVim nightly via BOB?" &&
		{
			# install Mason Pre-reqs when in Archlinux
			[ "$OS" == "Arch" ] && "${PACMAN[@]}" base-devel procps-ng curl file git unzip rsync

			if [ "$OS" == "Arch" ] || [ "$OS" == "Bazzite" ]; then
				curl -sfSLO --output-dir "$outdir" "$url"
				unzip "${outpath}.zip" -d "$outdir"
				$CP "${outpath}/bob" "$target"
				chmod 0755 "$target"/bob
				"$target"/bob use nightly

				rm -rf "$outpath" &&
					sudo rm -f "$global_target"/nvim &&
					sudo ln -sf "$basedir"/share/bob/nvim-bin/nvim "$global_target"/nvim

				install_neovim_config
			else
				install_neovim_config
			fi
		}
}

install_smb_creds() {
	local creds_file="/etc/.smb-credentials"

	sudo rm -f "$creds_file"
	read -r -p "Enter SMB username: " smb_user
	read -r -s -p "Enter SMB password: " smb_password
	echo && echo -e "user=$smb_user\npassword=$smb_password" | sudo tee "$creds_file" >/dev/null
	sudo chmod 400 "$creds_file"

	echo "Samba credentials saved to: $creds_file"
}
setup_external_mounts() {
	local src="./systemd-automount"
	local dst="/etc/systemd/system/"

	confirm "Setup external filesystem mounts?" &&
		{
			if [ "$OS" = "Arch" ] || [ "$OS" = "Bazzite" ]; then
				mkdir -p "$dst"

				echo "Attempting to remove existing mount units (if any)..."
				for unit in "$dst"/*.mount "$dst"/*.automount "$dst"/*.swap; do
					local unit_basename
					unit_basename="$(basename "$unit")"

					if [[ "$unit_basename" == *.automount* ]] || [[ "$unit_basename" == *.swap* ]]; then
						sudo systemctl disable "$(basename "$unit")" &&
							sudo systemctl stop "$(basename "$unit")"
					fi
					sudo rm -f "$unit"
				done

				unit_files=()
				for file in "$src"/mnt-*.mount "$src"/mnt-*.automount "$src"/mnt-*.swap; do
					[ ! -f "$file" ] && continue # skip to next if unreadable

					basename=$(basename "$file")
					if [ "$OS" = "Bazzite" ]; then
						# create new filename with var-mnt prefix
						new_basename="var-${basename}"
						temp_file="$(mktemp)"
						sed 's#/mnt/#/var/mnt/#g' "$file" >"$temp_file"
						# copy modified file to destination
						sudo cp -f "$temp_file" "$dst/$new_basename" &&
							sudo chmod 0644 "$dst/$new_basename"
						rm "$temp_file"
						unit_files+=("$new_basename")
					elif [ "$OS" = "Arch" ]; then
						sudo cp -f "$file" "$dst/$basename" # just copy
						if [[ "$basename" == *.automount* ]] || [[ "$basename" == *.swap* ]]; then
							unit_files+=("$basename") # only include automounts and swap
						fi
					else
						echo "Error: unsupported OS, skipping systemd mounts!"
						return 1
					fi
				done

				if [ "${#unit_files[@]}" -gt 0 ]; then
					install_smb_creds &&
						sudo systemctl daemon-reload &&
						sudo systemctl enable "${unit_files[@]}" &&
						sudo systemctl start "${unit_files[@]}"
				else
					echo "Error: no unit files found, skipping systemd mounts!"
				fi
			fi
		}
}

setup_grub_args() {
	confirm "Modify kernel args for Gigabyte Mobo ARGB support?" &&
		{
			if [ "$OS" = "Bazzite" ]; then
				rpm-ostree kargs --append=amd_pstate=active --append=acpi_enforce_resources=lax
			elif [ "$OS" == "Arch" ]; then
				# enable AMD Ryzen Pstate and enable OpenRGB for Gigabyte mobos (on patched kernels)
				local rgb_grub_arg="amd_pstate=active acpi_enforce_resources=lax"
				if update_grub_cmdline "$rgb_grub_arg" -eq 0; then
					sudo grub-mkconfig -o /boot/grub/grub.cfg
				fi
			else
				echo "Error: unsupported OS, skipping grub args!"
				return
			fi
		}
}

install_appimages() {
	local appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.AppImage "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.AppImage
}
install_fonts() {
	local font_archive="$SUPPORT/fonts.tar.gz"
	confirm "Install common user fonts?" &&
		{
			if [ -r "$font_archive" ]; then
				mkdir -p ~/.fonts &&
					tar xzf "$font_archive" -C ~/.fonts/ &&
					fc-cache -f
			else
				echo "Error: unable to find '$font_archive', skipping fonts!"
				return
			fi
		}
}
install_nvidia_tweaks() {
	if [ "$OS" == "Arch" ] && confirm "Install Nvidia driver tweaks?"; then
		local dst="/etc/modprobe.d/nvidia.conf"
		sudo rm -f "$dst"
		sudo cp -f ./etc-modprobe.d/nvidia.conf "$dst"
	else
		echo "Error: unsupported OS, skipping Nvidia tweaks!"
	fi
}
setup_system_shared() {
	! confirm "Install some common packages and tweaks?" && return

	# OS-specific tweaks
	case "$OS" in
	"Bazzite")
		# remove bazzite's joystickwake autostart
		local jswake="/etc/xdg/autostart/joystickwake.desktop"
		[ -f "$jswake" ] && sudo rm -f "$jswake"

		local tuned_path="/etc/sudoers.d/tuned"
		sudo rm -f "$tuned_path"
		sudo cp -f ./etc-sudoers.d/tuned "$tuned_path"

		# fix duplicate ostree entries in grub
		local grub_path="/etc/default/grub"
		sudo cp -f "$grub_path" "${grub_path}".bak &&
			sudo cp -f ./etc-default/grub "$grub_path" &&
			sudo touch /boot/grub2/.grub2-blscfg-supported &&
			sudo mv -f /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak &&
			ujust regenerate-grub

		# setup a Trash dir in /var for yazi (just in case)
		local var_trash_path
		var_trash_path="/var/.Trash-$(id -u)"
		sudo mkdir -p "$var_trash_path" &&
			sudo chown -R "$USER":"$USER" "$var_trash_path"

		setup_grub_args
		;;

	"Arch" | "CachyOS")
		local zram_path="/etc/systemd/zram-generator.conf"
		sudo cp -f "$zram_path" "${zram_path}".bak &&
			sudo cp -f ./etc-systemd/zram-generator.conf "$zram_path"

		sudo cp -f ./etc-udev-rules.d/*.rules /etc/udev/rules.d/

		sudo pacman -R --noconfirm cachy-browser
		"${PACMAN[@]}" \
			fd zoxide ripgrep bat fzf fish zsh python-pip \
			curl wget firefox steam openrgb rsync gnupg git \
			earlyoom mangohud lib32-mangohud lib32-pulseaudio \
			fuse2 winetricks protontricks wl-clipboard
		# enable earlyoom for safety when under memory stress
		"${PACMAN[@]}" earlyoom &&
			sudo systemctl disable --now systemd-oomd &&
			sudo systemctl enable --now earlyoom

		install_nvidia_tweaks
		setup_grub_args
		;;
	esac

	# Common things only supported on non-NixOS Linux
	if [ "$OS" == "Bazzite" ] || [ "$OS" == "Arch" ]; then
		local env_path="/etc/environment"
		sudo cp -f "$env_path" "${env_path}".bak &&
			$CP ."${env_path}" "$env_path"

		mkdir -p /usr/local/bin/ &&
			sudo cp -f ./usr-local-bin/* /usr/local/bin/ &&
			sudo chown root:root /usr/local/bin/* &&
			sudo chmod 0755 /usr/local/bin/*

		sudo rm -f /etc/sysctl.d/*.conf &&
			sudo cp -f ./etc-sysctl.d/*.conf /etc/sysctl.d/ &&
			sudo sysctl --system &>/dev/null

		sudo cp -f ./etc/nvidia-pm.conf ./etc/veridian-controller.toml /etc/ &&
			sudo cp -f ./etc-systemd/system/* /etc/systemd/system/ &&
			sudo chown root:root /etc/systemd/system/fix-wakeups.service &&
			sudo systemctl daemon-reload &&
			sudo systemctl enable --now {fix-wakeups,nvidia-tdp,veridian-controller}.service

		# enable some secondary user-specific services
		mkdir -p "$HOME"/.config/systemd/user/ "$HOME"/.local/bin/
		$CP ./systemd-user/*.service "$HOME"/.config/systemd/user/
		systemctl --user daemon-reload && chmod 0755 "$HOME"/.local/bin/*
		systemctl --user enable --now {on-session-state,openrgb-lightsout}.service

		setup_ssh_gpg
		setup_chaotic_aur
		install_appimages
		install_fonts
	else
		echo "Error: unsupported OS, skipping setup!"
	fi
}

install_brew() {
	(
		bash -ic "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1 | tee /dev/tty
	)
}
install_nix() {
	local nix=""
	case "$OS" in
	"Bazzite") nix="ostree" ;;
	"Darwin") nix="linux --determinate" ;;
	"Arch" | "CachyOS") nix="linux" ;;
	*) ;;
	esac
	curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install "${nix:+$nix}"
}
setup_package_manager() {
	local brew
	brew="$(check_cmd brew)"

	case "$OS" in
	"Bazzite" | "Darwin")
		if confirm "Install Brew and some common utils?"; then
			[ -z "$brew" ] && brew="$(install_brew)"
			[ -n "$brew" ] && "$brew" install eza fd rdfind ripgrep fzf bat lazygit fish zoxide
			setup_neovim # use BOB for Neovim
		elif confirm "Install Nix as an alternative to Brew?"; then
			install_nix
		fi
		;;

	"Arch" | "CachyOS") confirm "Install Nix?" && install_nix ;;

	*) echo "Error: incompatible OS, skipping package manager setup!" ;;
	esac
}

install_peazip() {
	confirm "Install Flatpak version of PeaZip with Dolphin integration?" &&
		{
			local peazip_app="io.github.peazip.PeaZip"

			if flatpak --user install --noninteractive "$peazip_app" &&
				[ "$OS" == "Bazzite" ]; then
				# pin PeaZip to v10.0.0 for compatibility reasons
				flatpak --user upgrade --noninteractive \
					"$peazip_app" --commit=04aea5bd3a84ddd5ddb032ef08c2e5214e3cc2448bdce155d446d30a84185278 &&
					flatpak --user mask --noninteractive "$peazip_app"
			fi

			local peazip_fix="./dotfiles/Configs/scripts/fix-peazip-dolphin-integration.sh"
			if [ -r "$peazip_fix" ]; then
				chmod 0755 "$peazip_fix"
				"$peazip_fix"
			fi
		}
}
install_brave() {
	confirm "Install Flatpak version of Brave browser?" &&
		{
			local chromium_app="com.brave.Browser"
			flatpak install --user --noninteractive "$chromium_app"

			if [ "$OS" == "Arch" ]; then
				"${PACMAN[@]}" libva-nvidia-driver
			fi

			local chromium_fix="./dotfiles/Configs/scripts/fix-vaapi-chromium-flatpak.sh"
			if [ -r "$chromium_fix" ]; then
				chmod 0755 "$chromium_fix"
				"$chromium_fix" --user --app "$chromium_app"
			else
				echo "Error: unable to find '$chromium_fix', aborting!"
				return 1
			fi
		}
}
install_firefox_fix() {
	confirm "Fix Firefox Flatpak overrides (for nvidia-vaapi and KeepassXC support)?" &&
		{
			if [ "$OS" == "Arch" ]; then
				"${PACMAN[@]}" libva-nvidia-driver
			fi

			local firefox_fix="./dotfiles/Configs/scripts/fix-vaapi-firefox.sh"
			if [ -r "$firefox_fix" ]; then
				chmod 0755 "$firefox_fix"
				"$firefox_fix"
			else
				echo "Error: unable to find '$firefox_fix', aborting!"
				return 1
			fi
		}
}
install_obs() {
	confirm "Install Flatpak version of OBS Studio?" &&
		{
			flatpak install --user --noninteractive \
				org.freedesktop.Platform.VulkanLayer.OBSVkCapture \
				com.obsproject.Studio.Plugin.OBSVkCapture \
				com.obsproject.Studio.Plugin.Gstreamer \
				com.obsproject.Studio.Plugin.GStreamerVaapi \
				com.obsproject.Studio
		}
}
setup_flatpak() {
	# pre-install common Flatpaks
	if confirm "Setup Flatpak and add common apps?"; then
		[ "$OS" == "Arch" ] && "${PACMAN[@]}" flatpak

		# remove existing flatpaks
		local installed_flatpaks=()
		while IFS= read -r app; do
			installed_flatpaks+=("$app")
		done < <(flatpak list --app --columns=application | tail -n +1)
		sudo flatpak remove --unused

		flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
		flatpak install --user --noninteractive \
			com.github.zocker_160.SyncThingy \
			com.spotify.Client \
			net.agalwood.Motrix \
			com.vysp3r.ProtonPlus \
			com.usebottles.bottles \
			org.freedesktop.Platform.VulkanLayer.MangoHud

		if [ "$OS" == "Bazzite" ]; then
			flatpak install --noninteractive \
				org.gtk.Gtk3theme.Adwaita-dark \
				com.github.tchx84.Flatseal \
				it.mijorus.gearlever \
				org.kde.filelight \
				org.kde.gwenview \
				org.kde.haruna \
				org.kde.kcalc \
				org.kde.okular \
				com.github.Matoking.protontricks
		fi

		install_peazip
		install_brave
		install_firefox_fix
		install_obs
	fi
}

setup_distrobox() {
	local distrobox
	distrobox="$(check_cmd distrobox)"

	if [ -z "$distrobox" ] &&
		[ "$OS" == "Arch" ] &&
		confirm "Attempt to install distrobox?"; then
		"${PACMAN[@]}" distrobox
	fi

	confirm "Perform assembly and customization of Distrobox containers?" &&
		{
			if [ -n "$distrobox" ]; then
				chmod +x ./distrobox/*.sh
				# distrobox assemble create --file ./distrobox/distrobox-assemble-archcli.ini
				distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini
				# distrobox assemble create --file ./distrobox/distrobox-assemble-fedcli.ini &&
				# distrobox enter fedcli -- bash -c ./distrobox/distrobox-setup-fedcli.sh
				el
			elif [ -z "$distrobox" ]; then
				echo "Error: 'distrobox' not found, skipping distrobox setup!"
			fi
		}
}

setup_qemu() {
	confirm "Setup libvirt/qemu with vfio passthrough support?" &&
		{
			# provide a way to pre-install libvirt/qemu
			if [ "$OS" == "Arch" ]; then
				"${PACMAN[@]}" libvirt qemu-desktop swtpm

				# add qemu specific kargs for passthrough if they don't already exist
				vm_grub_arg="kvm.ignore_msrs=1 kvm.report_ignored_msrs=0 amd_iommu=on iommy=pt rd.driver.pre=vfio_pci vfio_pci.disable_vga=1"
				if update_grub_cmdline "$vm_grub_arg" -eq 0; then
					sudo grub-mkconfig -o /boot/grub/grub.cfg
				fi

				# install qemu hooks and reload libvirtd
				sudo mkdir -p /etc/libvirt/hooks &&
					sudo tar -xvzf "$SUPPORT"/vfio-hooks.tar.gz -C /etc/libvirt/hooks &&
					sudo systemctl restart libvirtd

				# add current user to libvirt group
				sudo usermod -aG libvirt "$USER"
			else
				echo "Error: incompatible OS detected, skipping libvirt/qemu setup!"
			fi
		}
}
