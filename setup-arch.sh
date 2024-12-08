#!/usr/bin/env bash

ROOT="./stow-root"
SUPPORT="./support"
CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
	echo "Error: Cannot obtain sudo credentials!"
	exit 1
fi

confirm_action() {
	read -r -p "Continue? (y/[n]): " reply
	case $reply in
	[Yy]*) return 0 ;; # Continue execution
	[Nn]*) return 1 ;; # Exit script
	*) return 1 ;;
	esac
}

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

ROOT_FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
ROOT_FS_DEV=$(df -T / | awk 'NR==2 {print $1}')
ROOT_FS_UUID=$(sudo blkid -s UUID -o value "$ROOT_FS_DEV")
HOME_FS_TYPE=$(df -T /home | awk 'NR==2 {print $2}')

if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
	echo "Install grub-btrfsd and snapper (with dnf plugin)?"
	echo "IMPORTANT: Root (/) and Home (/home) must be mounted on @ and @home respectively!"
	echo "!! Ensure you have a root (subvolid=5) subvol for @var, @var_tmp, and @var_log before continuing !!"
	btrfs_mount="/mnt/btrfs"

	if confirm_action; then
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

		if [ "$HOME_FS_TYPE" = "btrfs" ]; then
			echo "Detected /home running on a btrfs subvolume, should we setup snapper for it?"
			if confirm_action; then
				sudo snapper -c home create-config /home &&
					sudo mv "$btrfs_mount/@home/.snapshots" "$btrfs_mount/@snapshots/home"

				echo "UUID=$ROOT_FS_UUID /home/.snapshots btrfs subvol=/@snapshots/home,defaults,noatime,compress=zstd,commit=120 0 0" | sudo tee -a /etc/fstab

				snapper_home_conf="/etc/snapper/configs/home"
				sudo cp -f ./etc-snapper-configs/home "$snapper_home_conf" &&
					sudo chown root:root "$snapper_home_conf" &&
					sudo chmod 0644 "$snapper_home_conf"
			else
				echo "Aborted..."
			fi
		fi

		sudo systemctl daemon-reload &&
			sudo systemctl restart --now snapperd.service &&
			sudo systemctl enable snapper-{cleanup,backup,timeline}.timer

		# regenerate grub-btrfs snapshots
		sudo grub-mkconfig -o /boot/grub/grub.cfg
	else
		echo "Aborted..."
	fi
fi

echo "Install Nvidia driver tweaks?"
if confirm_action; then
	$CP ./etc-X11/Xwrapper.config /etc/X11/ &&
		$CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

	$CP ./etc-systemd/system/nvidia-tdp.* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/nvidia-tdp.* &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now nvidia-tdp.service

	$CP ./etc-modprobe.d/nvidia.conf /etc/modprobe.d/nvidia.conf &&
		sudo chown root:root /etc/modprobe.d/nvidia.conf
else
	echo "Aborted..."
fi

echo "Install some common packages and tweaks (like Steam)?"
if confirm_action; then
	sudo pacman -R --noconfirm cachy-browser &&
		sudo pacman -Sy --noconfirm \
			fd zoxide ripgrep bat fzf fish zsh python-pip \
			curl wget firefox steam openrgb rsync gnupg git \
			earlyoom mangohud lib32-mangohud lib32-pulseaudio \
			fuse2 winetricks protontricks wl-clipboard

	# install some aliases
	cat <<EOF >>"$HOME"/.bashrc
if ! [ -f "/var/run/.containerenv" ] && ! [[ "$HOSTNAME" == *libvirt* ]]; then
  EZA_STANDARD_OPTIONS='--group --header --group-directories-first --icons --color=auto -A'
  alias ls='eza \$EZA_STANDARD_OPTIONS'
  alias ll='eza \$EZA_STANDARD_OPTIONS --long'
  alias llt='eza \$EZA_STANDARD_OPTIONS --long --tree'
  alias la='eza \$EZA_STANDARD_OPTIONS --all'
  alias l='eza \$EZA_STANDARD_OPTIONS'
  alias cat='bat'
fi
EOF

	# enable AMD Ryzen Pstate and enable OpenRGB for Gigabyte mobos (on patched kernels)
	rgb_grub_arg="amd_pstate=active acpi_enforce_resources=lax"
	if update_grub_cmdline "$rgb_grub_arg" -eq 0; then
		sudo grub-mkconfig -o /boot/grub/grub.cfg
	fi

	# set user as member of 'gamemode' group to fix gamemode service
	echo "Setup gamemode user service?"
	if confirm_action; then
		sudo pacman -Sy --noconfirm lib32-gamemode gamemode &&
			sudo mkdir -p /etc/polkit-1/localauthority/50-local.d/ &&
			sudo groupadd -f 'gamemode' &&
			sudo gpasswd -a "$USER" gamemode &&
			cat <<EOF >>"/etc/polkit-1/localauthority/50-local.d/gamemode.pkla"
Identity=unix-group:gamemode
Action=com.feralinteractive.GameMode.governor-helper;com.feralinteractive.GameMode.gpu-helper;com.feralinteractive.GameMode.cpu-helper;com.feralinteractive.GameMode.procsys-helper
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF
		systemctl --user enable --now gamemoded.service
	else
		echo "Aborted..."
	fi

	# enable earlyoom for safety when under memory stress
	sudo pacman -Sy earlyoom &&
		sudo systemctl disable --now systemd-oomd &&
		sudo systemctl enable --now earlyoom
else
	echo "Aborted..."
fi

#
# SETUP
#
# import ssh keys
echo "Setup SSH/GPG keys and config?"
if confirm_action; then
	$CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
		sudo chown -R "$USER:$USER" "$HOME/.ssh"
	chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}
	# import GPG GitHub keys
	gpg --list-keys &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
		gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc

	$CP "$ROOT/.gnupg/gpg-agent.conf" "$HOME/.gnupg/" &&
		gpg-connect-agent reloadagent /bye
else
	echo "Aborted..."
fi

echo "Perform user-specific customizations?"
if confirm_action; then
	$CP -r "$ROOT/.config" "$HOME/" &&
		$CP -r "$ROOT/.local" "$HOME/" &&
		$CP "$ROOT/.wezterm.lua" "$SUPPORT"/.gitconfig "$HOME/"

	sudo cat ./etc/environment | sudo tee -a /etc/environment
	$CP ./etc-systemd/zram-generator.conf /etc/systemd/zram-generator.conf

	$CP -f ./etc-udev-rules.d/60-openrgb.rules ./etc-udev-rules.d/60-ioschedulers.rules /etc/udev/rules.d/ &&
		sudo chown root:root /etc/udev/rules.d/* &&
		sudo udevadm control --reload-rules &&
		sudo udevadm trigger

	$CP ./usr-local-bin/*.sh /usr/local/bin/ &&
		sudo chown root:root /usr/local/bin/*.sh &&
		sudo chmod 0755 /usr/local/bin/*.sh

	$CP ./etc-sysctl.d/* /etc/sysctl.d/ &&
		sudo chown root:root /etc/sysctl.d/* &&
		sudo sysctl --system

	$CP ./etc-systemd/system/* /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/fix-wakeups.service &&
		sudo systemctl daemon-reload &&
		sudo systemctl enable --now fix-wakeups.service

	# disable systemd suspend user when entering suspend
	sudo rsync -rvh --chown=root:root --chmod=D755,F644 ./etc-systemd/system/systemd-{homed,suspend}.service.d /etc/systemd/system/ &&
		sudo systemctl daemon-reload

	# modify and copy swap mount
	$CP ./systemd-automount/mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
		sudo chown root:root /etc/systemd/system/*.swap

	# enable optional mounts via systemd-automount
	echo "Enable optional automounts and swapfile?"
	if confirm_action; then
		$CP ./systemd-automount/*.* /etc/systemd/system/

		$CP "$SUPPORT"/.smb-credentials /etc/ &&
			sudo chown root:root /etc/.smb-credentials &&
			sudo chmod 0400 /etc/.smb-credentials
		#sudo mkdir -p /mnt/{Downloads,FTPRoot,home,linuxgames,linuxdata}
		sudo systemctl enable --now mnt-{Downloads,FTPRoot,home,linuxgames,linuxdata}.automount
		sudo systemctl enable --now mnt-linuxgames-Games-swapfile.swap
	else
		echo "Aborted..."
	fi

	# enable some secondary user-specific services
	systemctl --user daemon-reload &&
		chmod 0755 "$HOME"/.local/bin/* &&
		systemctl --user enable --now on-session-state.service

	# update fish shell plugins
	fish_path="$(command -v fish)"
	$fish_path -c "rm -rf $HOME/.config/fish/{completions,conf.d,functions,themes,fish_variables} && \
      fisher update && \
      fish_add_path $HOME/.local/bin /usr/local/bin"

	# SETUP USER DEPENDENCIES
	echo "Install common user fonts?"
	if confirm_action; then
		mkdir -p ~/.fonts &&
			tar xvzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
			fc-cache -fv
	else
		echo "Aborted..."
	fi

	echo "Install customized NeoVim config?"
	if confirm_action; then
		rm -rf "$HOME/.config/nvim" "$HOME/.local/share/nvim" "$HOME/.local/cache/nvim"
		git clone git@github.com:WombatFromHell/lazyvim.git "$HOME/.config/nvim"
		sudo pacman -Sy --noconfirm base-devel procps-ng curl file git
	else
		echo "Aborted..."
	fi

	# install some common appimages
	appimages_path="$HOME/AppImages"
	mkdir -p "$appimages_path" &&
		$CP "$SUPPORT"/appimages/*.* "$appimages_path/" &&
		chmod 0755 "$appimages_path"/*.*

	# link neovim to a global path directory for accessibility
	nvim_local_path="$HOME/AppImages/nvim.appimage"
	sudo ln -sf "$nvim_local_path" /usr/local/bin/nvim &&
		ln -sf "$nvim_local_path" "$HOME"/.local/bin/nvim &&
		cat <<EOF >>"$HOME"/.bashrc
EDITOR='/usr/local/bin/nvim'
alias edit='\$EDITOR'
alias sedit='sudo -E \$EDITOR'
EOF

else
	echo "Aborted..."
fi

#
# SETUP DISTROBOX CONTAINERS
#
echo "Perform assembly and customization of Distrobox containers?"
if confirm_action; then
	chmod +x distrobox-setup-*.sh
	# ARCHLINUX
	# distrobox assemble create --file ./distrobox-archcli.ini && \
	#   distrobox-enter -n arch-cli -- bash -c ./distrobox-setup-archcli.sh
	# DEBIAN (dev container)
	distrobox assemble create --file ./distrobox-debdev.ini &&
		distrobox-enter -n debian-dev -- bash -c ./distrobox-setup-debdev.sh
	# FEDORA (multi-use container)
	# distrobox assemble create --file ./distrobox-fedcli.ini && \
	#   distrobox-enter -n fedora-cli -- bash -c ./distrobox-setup-fedcli.sh
else
	echo "Aborted..."
fi

# pre-install common Flatpaks
echo "Setup Flatpak repo and add common apps?"
if confirm_action; then
	sudo pacman -Sy --noconfirm flatpak
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	flatpak install --user --noninteractive \
		runtime/org.gtk.Gtk3theme.Adwaita-dark/x86_64/3.22 \
		com.github.tchx84.Flatseal \
		com.github.zocker_160.SyncThingy \
		it.mijorus.gearlever \
		com.vysp3r.ProtonPlus
else
	echo "Aborted..."
fi

# provide a way to pre-install libvirt/qemu
echo "Setup libvirt/qemu with vfio passthrough support?"
if confirm_action; then
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
else
	echo "Aborted..."
fi

echo "Finished!"
