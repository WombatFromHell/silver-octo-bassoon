#!/usr/bin/env bash

SUPPORT="./support"
CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"

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
	cmd="$(which command -v "$1")"
	if [ -n "$cmd" ]; then
		echo "$cmd"
	else
		return 1
	fi
}

check_os() {
	local os
	os="$(uname -a)"

	case "$os" in
	*NixOS*) echo "NixOS" ;;
	*bazzite*) echo "Bazzite" ;;
	*Darwin*) echo "Darwin" ;;
	*Linux*) echo "Linux" ;;
	*) echo "Other" ;;
	esac
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

setup_appimages() {
	local appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.AppImage "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.AppImage
}

setup_fonts() {
	local font_archive="$SUPPORT/fonts.tar.gz"

	if [ -r "$font_archive" ] && confirm "Install common user fonts?"; then
		mkdir -p ~/.fonts &&
			tar xzf "$font_archive" -C ~/.fonts/ &&
			fc-cache -f
	else
		echo "Error: unable to find '$font_archive', skipping fonts!"
		return
	fi
}

install_brew() {
	bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" &&
		which brew
}
install_nix() {
	local nix=""
	[[ "$OS" == "Bazzite" ]] && nix="ostree"
	curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install "${nix:+$nix}"
}
setup_package_manager() {
	local brew
	brew="$(which brew)"

	case "$OS" in
	"Bazzite" | "Darwin")
		if confirm "Install Brew and some common utils?"; then
			[ -z "$brew" ] && brew="$(install_brew)"
			[ -n "$brew" ] && "$brew" install eza fd rdfind ripgrep fzf bat lazygit fish zoxide
		fi
		confirm "Install Nix as an alternative to Brew?" && install_nix
		;;
	"Linux")
		confirm "Install Nix as an alternative to Brew?" && install_nix
		;;
	*) echo "Error: incompatible OS, skipping common tweaks!" ;;
	esac
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
	if [ "$OS" == "Linux" ] && confirm "Setup Chaotic AUR?"; then
		sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
		sudo pacman-key --lsign-key 3056513887B78AEB
		sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
		sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
		sudo cp -f /etc/pacman.conf /etc/pacman.conf.pre-chaotic-aur.bak

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

	if confirm "Wipe any existing NeoVim config and download custom distribution?"; then
		rm -rf "$HOME"/.config/nvim "$basedir"/share/nvim "$basedir"/cache/nvim "$basedir"/state/nvim
		git clone git@github.com:WombatFromHell/lazyvim.git "$HOME"/.config/nvim
	fi
}

setup_system_shared() {
	if [ "$OS" == "Linux" ]; then
		$CP ./etc-systemd/zram-generator.conf /etc/systemd/zram-generator.conf

		$CP -f \
			./etc-udev-rules.d/60-openrgb.rules \
			./etc-udev-rules.d/60-ioschedulers.rules \
			/etc/udev/rules.d/ &&
			#
			sudo chown root:root /etc/udev/rules.d/* &&
			sudo udevadm control --reload-rules &&
			sudo udevadm trigger
	fi

	sudo cp -f /etc/environment /etc/environment.bak &&
		$CP ./etc/environment /etc/environment

	$CP ./usr-local-bin/* /usr/local/bin/ &&
		sudo chown root:root /usr/local/bin/* &&
		sudo chmod 0755 /usr/local/bin/*.sh

	rm -f /etc/sysctl.d/*.conf &&
		$CP ./etc-sysctl.d/*.conf /etc/sysctl.d/ &&
		sudo sysctl --system

	$CP ./etc-systemd/system/* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/fix-wakeups.service &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now fix-wakeups.service

	# enable some secondary user-specific services
	mkdir -p "$HOME"/.config/systemd/user/ "$HOME"/.local/bin/
	$CP ./systemd-user/*.service "$HOME"/.config/systemd/user/
	systemctl --user daemon-reload &&
		chmod 0755 "$HOME"/.local/bin/*
	systemctl --user enable --now on-session-state.service
	systemctl --user enable --now openrgb-lightsout.service
}

setup_common_tweaks() {
	case "$OS" in
	"Bazzite")
		confirm "Modify kernel args for Gigabyte Mobo ARGB support?" &&
			rpm-ostree kargs --append=amd_pstate=active --append=acpi_enforce_resources=lax
		;;
	"Linux")
		! confirm "Install some common packages and tweaks?" && return
		{
			if PACMAN="$(check_cmd pacman)"; then
				local pacman="sudo $PACMAN"
				"$pacman" -R --noconfirm cachy-browser &&
					"$pacman" -Sy --noconfirm \
						fd zoxide ripgrep bat fzf fish zsh python-pip \
						curl wget firefox steam openrgb rsync gnupg git \
						earlyoom mangohud lib32-mangohud lib32-pulseaudio \
						fuse2 winetricks protontricks wl-clipboard
				# enable earlyoom for safety when under memory stress
				"$pacman" -Sy earlyoom &&
					sudo systemctl disable --now systemd-oomd &&
					sudo systemctl enable --now earlyoom
			fi
		}

		confirm "Modify kernel args for Gigabyte Mobo ARGB support?" &&
			{
				# enable AMD Ryzen Pstate and enable OpenRGB for Gigabyte mobos (on patched kernels)
				local rgb_grub_arg="amd_pstate=active acpi_enforce_resources=lax"
				if update_grub_cmdline "$rgb_grub_arg" -eq 0; then
					sudo grub-mkconfig -o /boot/grub/grub.cfg
				fi
			}
		;;
	*)
		echo "Error: incompatible OS, skipping common tweaks!"
		;;
	esac
}

create_smb_creds() {
	local creds_file="/etc/.smb-credentials"

	sudo rm -f "$creds_file"
	read -r -p "Enter SMB username: " smb_user
	read -r -s -p "Enter SMB password: " smb_password
	echo && echo -e "user=$smb_user\npassword=$smb_password" | sudo tee "$creds_file" >/dev/null
	sudo chmod 400 "$creds_file"

	echo "Samba credentials saved to: $creds_file"
}
setup_external_mounts() {
	src="./systemd-automount"
	dst="/etc/systemd/system/"
	mkdir -p "$dst"
	rm -f "$dst"/*.{mount,automount,swap}

	unit_files=()
	for file in "$src"/mnt-*.mount "$src"/mnt-*.automount "$src"/mnt-*.swap; do
		[ ! -f "$file" ] && continue # skip to next if unreadable

		basename=$(basename "$file")
		if [ "$OS" = "Bazzite" ]; then
			# create new filename with var-mnt prefix
			new_basename="var-${basename/mnt-/}"
			temp_file="$(mktemp)"
			sed 's#/mnt/#/var/mnt/#g' "$file" >"$temp_file"
			# copy modified file to destination
			$CP "$temp_file" "$dst/$new_basename"
			rm "$temp_file"
			work_files+=("$new_basename")
		elif [ "$OS" = "Linux" ]; then
			$CP "$file" "$dst/$basename" # just copy
			if [[ "$basename" == *.automount* ]] || [[ "$basename" == *.swap* ]]; then
				unit_files+=("$basename")
			fi
		else
			echo "Error: unsupported OS, skipping systemd mounts!"
			return 1
		fi
	done

	if [ "${#unit_files[@]}" -gt 0 ]; then
		create_smb_creds &&
			sudo systemctl daemon-reload &&
			sudo systemctl enable --now "${unit_files[@]}"
	fi
}

install_peazip() {
	if confirm "Install Flatpak version of PeaZip with Dolphin integration?"; then
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
	fi
}
install_brave() {
	if confirm "Install Flatpak version of Brave browser?"; then
		local chromium_app="com.brave.Browser"
		flatpak install --user --noninteractive "$chromium_app"

		local chromium_fix="./dotfiles/Configs/scripts/fix-vaapi-chromium-flatpak.sh"
		if [ -r "$chromium_fix" ]; then
			chmod 0755 "$chromium_fix"
			"$chromium_fix" --user --app "$chromium_app"
		else
			echo "Error: unable to find '$chromium_fix', aborting!"
			return 1
		fi
	fi
}
install_firefox_fix() {
	if confirm "Fix Firefox Flatpak overrides (for nvidia-vaapi and KeepassXC support)?"; then
		local firefox_fix="./dotfiles/Configs/scripts/fix-vaapi-firefox.sh"
		if [ -r "$firefox_fix" ]; then
			chmod 0755 "$firefox_fix"
			"$firefox_fix"
		else
			echo "Error: unable to find '$firefox_fix', aborting!"
			return 1
		fi
	fi
}
setup_flatpak() {
	# pre-install common Flatpaks
	if confirm "Setup Flatpak repo and add common apps?"; then
		sudo pacman -Sy --noconfirm flatpak
		flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
		flatpak install --user --noninteractive \
			org.gtk.Gtk3theme.Adwaita-dark \
			com.github.tchx84.Flatseal \
			com.github.zocker_160.SyncThingy \
			it.mijorus.gearlever \
			com.vysp3r.ProtonPlus

		install_peazip
		install_brave
		install_firefox_fix
	fi
}

setup_distrobox() {
	if confirm "Perform assembly and customization of Distrobox containers?"; then
		chmod +x ./distrobox/*.sh
		# ARCHLINUX
		# distrobox assemble create --file ./distrobox/distrobox-assemble-archcli.ini
		# DEBIAN (dev container)
		distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini
		# ./distrobox/brave-export-fix.sh
		# FEDORA (multi-use container)
		# distrobox assemble create --file ./distrobox/distrobox-assemble-fedcli.ini &&
		# distrobox enter fedcli -- bash -c ./distrobox/distrobox-setup-fedcli.sh
	fi
}

setup_qemu() {
	# provide a way to pre-install libvirt/qemu
	if confirm "Setup libvirt/qemu with vfio passthrough support?"; then
		sudo pacman -Sy --noconfirm libvirt qemu-desktop swtpm

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

	if [ "$ROOT_FS_TYPE" = "btrfs" ] && confirm "Install grub-btrfsd and snapper?"; then
		echo "IMPORTANT: Root (/) and Home (/home) must be mounted on @ and @home respectively!"
		echo "!! Ensure you have a root (subvolid=5) subvol for @var, @var_tmp, and @var_log before continuing !!"
		btrfs_mount="/mnt/btrfs"

		sudo mkdir -p "$btrfs_mount" &&
			sudo mount -o subvolid=5,noatime "$ROOT_FS_DEV" "$btrfs_mount" &&
			sudo btrfs sub cr "$btrfs_mount"/@snapshots
		echo "UUID=$ROOT_FS_UUID /.snapshots btrfs subvol=/@snapshots/root,defaults,noatime,compress=zstd,commit=120 0 0" | sudo tee -a /etc/fstab

		sudo pacman -Sy --noconfirm grub-btrfs snap-pac inotify-tools

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

setup_nvidia_tweaks() {
	if [ "$OS" == "Bazzite" ] && confirm "Install Nvidia driver tweaks?"; then
		$CP ./etc-X11/Xwrapper.config /etc/X11/ &&
			$CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

		$CP ./etc-systemd/system/nvidia-tdp.* /etc/systemd/system/ &&
			sudo chown root:root /etc/systemd/system/nvidia-tdp.* &&
			sudo systemctl daemon-reload &&
			sudo systemctl enable --now nvidia-tdp.service

		$CP ./etc-modprobe.d/nvidia.conf /etc/modprobe.d/nvidia.conf &&
			sudo chown root:root /etc/modprobe.d/nvidia.conf
	else
		echo "Error: unsupported OS, skipping Nvidia tweaks!"
	fi
}
