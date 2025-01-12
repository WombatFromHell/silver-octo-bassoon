#!/usr/bin/env bash

source ./common.sh
cache_creds

ROOT_FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
ROOT_FS_DEV=$(df -T / | awk 'NR==2 {print $1}')
ROOT_FS_UUID=$(sudo blkid -s UUID -o value "$ROOT_FS_DEV")
HOME_FS_TYPE=$(df -T /home | awk 'NR==2 {print $2}')

if [ "$ROOT_FS_TYPE" = "btrfs" ] && confirm "Install grub-btrfsd and snapper?"; then
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
  fi

  sudo systemctl daemon-reload &&
    sudo systemctl restart --now snapperd.service &&
    sudo systemctl enable snapper-{cleanup,backup,timeline}.timer

  # regenerate grub-btrfs snapshots
  sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

if confirm "Install Nvidia driver tweaks?"; then
  $CP ./etc-X11/Xwrapper.config /etc/X11/ &&
    $CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

  $CP ./etc-systemd/system/nvidia-tdp.* /etc/systemd/system/ &&
    sudo chown root:root /etc/systemd/system/nvidia-tdp.* &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable --now nvidia-tdp.service

  $CP ./etc-modprobe.d/nvidia.conf /etc/modprobe.d/nvidia.conf &&
    sudo chown root:root /etc/modprobe.d/nvidia.conf
fi

if confirm "Install some common packages and tweaks (like Steam)?"; then
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
  fi

  # enable earlyoom for safety when under memory stress
  sudo pacman -Sy earlyoom &&
    sudo systemctl disable --now systemd-oomd &&
    sudo systemctl enable --now earlyoom
fi

if confirm "Setup Chaotic AUR?"; then
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
fi

#
# SETUP
#
# import ssh keys
if confirm "Setup SSH/GPG keys and config?"; then
  $CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
    sudo chown -R "$USER:$USER" "$HOME/.ssh"
  chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}
  # import GPG GitHub keys
  gpg --list-keys &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc

  $CP "$SUPPORT"/.gnupg/gpg-agent.conf "$HOME"/.gnupg/ &&
    gpg-connect-agent reloadagent /bye
fi

echo
if confirm "Perform user-specific customizations?"; then
  $CP -r "$SUPPORT"/bin/ "$HOME"/.local/bin/ &&
    $CP "$SUPPORT"/.gitconfig "$HOME"/

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
  if confirm "Enable optional automounts and swapfile?"; then
    $CP ./systemd-automount/*.* /etc/systemd/system/

    $CP "$SUPPORT"/.smb-credentials /etc/ &&
      sudo chown root:root /etc/.smb-credentials &&
      sudo chmod 0400 /etc/.smb-credentials
    #sudo mkdir -p /mnt/{Downloads,FTPRoot,home,linuxgames,linuxdata}
    sudo systemctl enable --now mnt-{Downloads,FTPRoot,home,linuxgames,linuxdata}.automount
    sudo systemctl enable --now mnt-linuxgames-Games-swapfile.swap
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
  if confirm "Install common user fonts?"; then
    mkdir -p ~/.fonts &&
      tar xvzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
      fc-cache -fv
  fi

  if confirm "Install customized NeoVim config?"; then
    rm -rf "$HOME/.config/nvim" "$HOME/.local/share/nvim" "$HOME/.local/cache/nvim"
    git clone git@github.com:WombatFromHell/lazyvim.git "$HOME/.config/nvim"
    sudo pacman -Sy --noconfirm base-devel procps-ng curl file git
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
fi

if confirm "Install Nix?"; then
  chmod +x "$SUPPORT"/lix-installer
  "$SUPPORT"/lix-installer install linux
fi

#
# SETUP DISTROBOX CONTAINERS
#
if confirm "Perform assembly and customization of Distrobox containers?"; then
  chmod +x ./distrobox/*.sh
  # ARCHLINUX
  # distrobox assemble create --file ./distrobox/distrobox-assemble-archcli.ini
  # DEBIAN (dev container)
  distrobox assemble create --file ./distrobox/distrobox-assemble-devbox.ini &&
    ./distrobox/brave-export-fix.sh
  # FEDORA (multi-use container)
  # distrobox assemble create --file ./distrobox/distrobox-assemble-fedcli.ini &&
  # distrobox enter fedcli -- bash -c ./distrobox/distrobox-setup-fedcli.sh
fi

# pre-install common Flatpaks
if confirm "Setup Flatpak repo and add common apps?"; then
  sudo pacman -Sy --noconfirm flatpak
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user --noninteractive \
    runtime/org.gtk.Gtk3theme.Adwaita-dark/x86_64/3.22 \
    com.github.tchx84.Flatseal \
    com.github.zocker_160.SyncThingy \
    it.mijorus.gearlever \
    com.vysp3r.ProtonPlus

  if confirm "Install Flatpak version of Brave browser?"; then
    flatpak install --user --noninteractive com.brave.Browser
    chmod +x ./support/brave-flatpak-fix.sh
    # include a fix for hardware acceleration
    ./support/brave-flatpak-fix.sh
  fi
fi

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

echo "Finished!"
