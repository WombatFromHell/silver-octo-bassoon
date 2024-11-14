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
      sudo btrfs sub cr "$btrfs_mount"/@snapshots &&
      sudo btrfs sub cr "$btrfs_mount"/@snapshots/root
    echo "UUID=$ROOT_FS_UUID /.snapshots btrfs subvol=/@snapshots/root,defaults,noatime,compress=zstd,commit=120 0 0" | sudo tee -a /etc/fstab

    sudo pacman -Sy --noconfirm snapper snap-pac inotify-tools
    paru -Sy --noconfirm grub-btrfs

    sudo snapper -c root create-config / &&
      sudo btrfs sub del /.snapshots &&
      sudo mkdir "$btrfs_mount"/@/.snapshots

    snapper_root_conf="/etc/snapper/configs/root"
    sudo cp -f ./etc-snapper-configs/root "$snapper_root_conf" &&
      sudo chown root:root "$snapper_root_conf" &&
      sudo chmod 0644 "$snapper_root_conf"

    if [ "$HOME_FS_TYPE" = "btrfs" ]; then
      echo "Detected /home running on a btrfs subvolume, should we setup snapper for it?"
      if confirm_action; then
        sudo snapper -c home create-config /home &&
          sudo btrfs sub del /home/.snapshots

        sudo btrfs sub cr "$btrfs_mount"/@snapshots/home &&
          sudo mkdir "$btrfs_mount"/@home/.snapshots
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
      sudo systemctl enable snapper-{cleanup,boot,timeline}.timer

    # regenerate grub-btrfs snapshots
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    echo "Aborted..."
  fi
fi

echo "Install Nvidia driver tweaks?"
if confirm_action; then
  sudo pacman -Sy nvidia-open-dkms lib32-nvidia-utils libva-nvidia-driver

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
      curl wget firefox steam lib32-gamemode gamemode \
      openrgb rsync gnupg git earlyoom mangohud lib32-mangohud \
      lib32-pulseaudio fuse2 winetricks protontricks xclip wl-clipboard

  # install some aliases
  cat <<EOF >>"$HOME"/.bashrc
# If not running interactively, don't do anything
! [[ -n "$PS1" ]] && return
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

  # enable scx_rusty and set as default on boot (assuming CachyOS)
  sudo pacman -Sy --noconfirm scx-scheds &&
    sudo systemctl enable --now scx
  # enable earlyoom for safety when under memory stress
  sudo pacman -Sy earlyoom &&
    sudo systemctl disable --now systemd-oomd &&
    sudo systemctl enable --now earlyoom
  # make sure gamemoded is enabled for our user
  systemctl --user daemon-reload &&
    systemctl --user enable --now gamemoded.service
  # enable scx_lavd
  if command -v scx_lavd >/dev/null; then
    $CP ./etc-default/scx /etc/default/scx &&
      sudo systemctl enable --now scx
  fi
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
    $CP -r "$ROOT/.wezterm.lua" "$SUPPORT"/.gitconfig "$HOME/"

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

  # modify and copy swap mount
  $CP ./systemd-automount/mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
    sudo chown root:root /etc/systemd/system/*.swap

  # enable optional mounts via systemd-automount
  $CP ./systemd-automount/*.* /etc/systemd/system/

  $CP "$SUPPORT"/.smb-credentials /etc/ &&
    sudo chown root:root /etc/.smb-credentials &&
    sudo chmod 0400 /etc/.smb-credentials &&
    sudo mkdir -p /mnt/{Downloads,FTPRoot,home,linuxgames,linuxdata}
  #sudo systemctl enable --now mnt-{Downloads,FTPRoot,home,linuxgames,linuxdata}.automount
  #sudo systemctl enable --now mnt-linuxgames-Games-swapfile.swap

  # enable some secondary user-specific services
  systemctl --user daemon-reload &&
    chmod 0755 "$HOME"/.local/bin/* &&
    systemctl --user enable --now on-session-state.service

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
  else
    echo "Aborted..."
  fi

  # install some common appimages
  NVIM_LOCAL="/usr/local/bin/nvim.AppImage"
  $CP "$SUPPORT"/appimages/nvim.AppImage "$NVIM_LOCAL" &&
    sudo chown root:root "$NVIM_LOCAL" &&
    sudo chmod 0755 "$NVIM_LOCAL" &&
    sudo ln -sf "$NVIM_LOCAL" /usr/local/bin/nvim &&
    cat <<EOF >>"$HOME"/.bashrc
echo "EDITOR='/usr/local/bin/nvim'"
echo "alias edit='\$EDITOR'"
echo "alias sedit='sudo -E \$EDITOR'"
EOF

  mkdir -p "$HOME/AppImages/" &&
    $CP "$SUPPORT"/appimages/*.AppImage "$HOME/AppImages/" &&
    chmod 0755 "$HOME"/AppImages/*.AppImage
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
    runtime/org.gtk.Gtk3theme.adw-gtk3/x86_64/3.22 \
    runtime/org.gtk.Gtk3theme.adw-gtk3-dark/x86_64/3.22 \
    com.github.tchx84.Flatseal \
    com.github.zocker_160.SyncThingy \
    it.mijorus.gearlever \
    org.equeim.Tremotesf \
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
