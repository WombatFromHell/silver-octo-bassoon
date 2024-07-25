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

echo "Install Nvidia drivers?"
if confirm_action; then
  sudo pacman -Sy --noconfirm \
    nvidia-open-dkms nvidia-settings nvidia-utils lib32-nvidia-utils libva-nvidia-driver
else
  echo "Aborted..."
fi

echo "Install some common packages and tweaks (like Steam)?"
if confirm_action; then
  sudo pacman -R --noconfirm cachyos-browser &&
    sudo pacman -Sy --noconfirm \
      fd zoxide ripgrep bat fzf fish zsh python-pip \
      curl wget firefox steam lib32-gamemode gamemode \
      openrgb rsync gnupg git earlyoom mangohud lib32-mangohud lib32-pulseaudio

  # install some common aliases
  {
    echo "EZA_STANDARD_OPTIONS='--group --header --group-directories-first --icons --color=auto -A'"
    echo "alias ls='eza \$EZA_STANDARD_OPTIONS'"
    echo "alias ll='eza \$EZA_STANDARD_OPTIONS --long'"
    echo "alias llt='eza \$EZA_STANDARD_OPTIONS --long --tree'"
    echo "alias la='eza \$EZA_STANDARD_OPTIONS --all'"
    echo "alias l='eza \$EZA_STANDARD_OPTIONS'"
    echo "alias cat='bat'"
  } >>"$HOME/.bashrc"

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
    sudo systemctl enable --now earlyoom
  # make sure gamemoded is enabled for our user
  systemctl --user daemon-reload &&
    systemctl --user enable --now gamemoded.service
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

  $CP ./etc-X11/Xwrapper.config /etc/X11/ &&
    $CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

  $CP ./usr-local-bin/*.sh /usr/local/bin/ &&
    sudo chown root:root /usr/local/bin/*.sh &&
    sudo chmod 0755 /usr/local/bin/*.sh

  $CP ./etc-sysctl.d/* /etc/sysctl.d/ &&
    sudo chown root:root /etc/sysctl.d/* &&
    sudo sysctl --system

  $CP ./etc-systemd/system/* /etc/systemd/system/ &&
    sudo chown root:root /etc/systemd/system/{fix-wakeups.service,nvidia-tdp.*} &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable --now fix-wakeups.service &&
    sudo systemctl enable --now nvidia-tdp.service
  # enable optional mounts via systemd-automount
  $CP "$SUPPORT"/.smb-credentials /etc/ &&
    sudo chown root:root /etc/.smb-credentials &&
    sudo chmod 0400 /etc/.smb-credentials &&
    sudo mkdir -p /mnt/{Downloads,FTPRoot,home,SSDDATA1,linuxgames}
  #sudo systemctl enable --now mnt-{Downloads,FTPRoot,home,SSDDATA1,linuxgames}.automount

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
  $CP "$SUPPORT"/appimages/nvim-0.10.0.AppImage "$NVIM_LOCAL" &&
    sudo chown root:root "$NVIM_LOCAL" &&
    sudo chmod 0755 "$NVIM_LOCAL" &&
    sudo ln -sf "$NVIM_LOCAL" /usr/local/bin/nvim &&
    {
      echo "EDITOR='/usr/local/bin/nvim'"
      echo "alias edit='\$EDITOR'"
      echo "alias sedit='sudo -E \$EDITOR'"
    } >>"$HOME/.bashrc"

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
  sudo pacman -Sy --noconfirm podman distrobox
  chmod +x distrobox-setup-*.sh
  distrobox assemble create --file ./distrobox-assemble.ini
  # ARCHLINUX (misc container)
  #distrobox-enter -n arch-cli -- bash -c ./distrobox-setup-archcli.sh
  # DEBIAN (dev container)
  distrobox-enter -n debian-dev -- bash -c ./distrobox-setup-dev.sh
  # FEDORA (browser container)
  distrobox-enter -n fedora-cli -- bash -c ./distrobox-setup-fedcli.sh
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
    net.davidotek.pupgui2 \
    org.equeim.Tremotesf \
    io.github.dvlv.boxbuddyrs
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
