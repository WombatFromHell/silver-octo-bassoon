#!/usr/bin/env bash
#set -euxo pipefail

#
# THIS SCRIPT IS MODELED AFTER BAZZITE'S CONTAINERFILE
#

confirm_action() {
  read -r -p "Continue? (y/[n]): " reply
  case $reply in
  [Yy]*) return 0 ;; # Continue execution
  [Nn]*) return 1 ;; # Exit script
  *) return 1 ;;
  esac
}

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

echo "Setup RPMFusion repos?"
if confirm_action; then
  sudo dnf install -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-"$(rpm -E %fedora)".noarch.rpm &&
    sudo dnf install -y https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-"$(rpm -E %fedora)".noarch.rpm
else
  echo "Aborted..."
fi

ROOT_FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
HOME_FS_TYPE=$(df -T /home | awk 'NR==2 {print $2}')
if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
  echo "Install grub-btrfsd and snapper (with dnf plugin)?"
  echo "IMPORTANT: Root (/) and Home (/home) must be mounted on @ and @home respectively!"
  echo "!! Ensure you have a root (subvolid=5) subvol for @var, @var_tmp, and @var_log before continuing !!"
  if confirm_action; then
    sudo dnf install -y dnf-plugins-extras-snapper inotify-tools make

    unzip "$SUPPORT"/grub-btrfs-4.13.zip &&
      sed -i 's/boot\/grub/boot\/grub2/' ./grub-btrfs-4.13/41_snapshots-btrfs &&
      sudo make -C grub-btrfs-4.13 install &&
      rm -rf ./grub-btrfs-4.13

    sudo systemctl daemon-reload &&
      sudo systemctl enable --now grub-btrfsd

    sudo snapper -c root create-config /
    if [ "$HOME_FS_TYPE" = "btrfs" ]; then
      echo "Detected /home running on a btrfs subvolume, should we setup snapper for it?"
      if confirm_action; then
        sudo snapper -c home create-config /home
      else
        echo "Aborted..."
      fi
    fi

    sudo systemctl enable --now snapper-{cleanup,boot,timeline}.timer
  else
    echo "Aborted..."
  fi
fi

echo "Install some common packages (like Steam/Lutris and X11)?"
if confirm_action; then
  dnf copr enable -y kylegospo/bazzite-multilib
  sudo dnf update -y &&
    sudo dnf install -y \
      at-spi2-core.i686 atk.i686 vulkan-loader.i686 \
      alsa-lib.i686 fontconfig.i686 gtk2.i686 \
      libICE.i686 libnsl.i686 libxcrypt-compat.i686 \
      libpng12.i686 libXext.i686 libXinerama.i686 \
      libXtst.i686 libXScrnSaver.i686 NetworkManager-libnm.i686 \
      nss.i686 pulseaudio-libs.i686 libcurl.i686 \
      systemd-libs.i686 libva.i686 libvdpau.i686 \
      libdbusmenu-gtk3.i686 libatomic.i686 pipewire-alsa.i686 clinfo \
      plasma-workspace-x11 git wget curl podman distrobox flatpak \
      steam steam-devices mangohud.x86_64 mangohud.i686 lutris \
      fluidsynth fluid-soundfont-gm qsynth wxGTK libFAudio \
      wine-core.x86_64 wine-core.i686 wine-pulseaudio.x86_64 \
      wine-pulseaudio.i686 winetricks protontricks
else
  echo "Aborted..."
fi

echo "Install Fsync Kernel?"
if confirm_action; then
  REPO_FILE="/etc/yum.repos.d/fedora-updates.repo"
  sudo dnf copr enable -y sentry/kernel-fsync

  # only allow updates from kernel-fsync (NOT fedora native repo)
  if [ ! -f "${REPO_FILE}.bak" ]; then
    sudo cp "${REPO_FILE}" "${REPO_FILE}.bak" &&
      sudo sed -i '/\[updates\]/a exclude=kernel*' "${REPO_FILE}"
  fi

  sudo dnf update --refresh -y &&
    sudo dnf install -y kernel kernel-core kernel-modules kernel-modules-core \
      kernel-modules-extra kernel-uki-virt kernel-headers kernel-devel

  # enable AMD Ryzen Pstate and enable OpenRGB for Gigabyte mobos (on patched kernels)
  sudo grubby --update-kernel=ALL --remove-args 'quiet' --args='amd_pstate=active acpi_enforce_resources=lax'
else
  echo "Aborted..."
fi

echo "Setup discrete Nvidia GPU drivers?"
if confirm_action; then
  # use negativo17's nvidia drivers
  #sudo dnf config-manager --add-repo=https://negativo17.org/repos/fedora-nvidia.repo
  sudo dnf config-manager --add-repo=https://negativo17.org/repos/fedora-multimedia.repo
  sudo dnf update --refresh -y &&
    sudo dnf --releasever=rawhide upgrade -y xorg-x11-server-Xwayland \
      sudo dnf install -y nvidia-driver akmod-nvidia libva-nvidia-driver libva-utils vdpauinfo &&
    sudo akmods --force --rebuild &&
    sudo systemctl enable nvidia-{suspend,resume,hibernate}

  # only enable below for btrfs
  #$CP ./etc-modprobe.d/nvidia.conf /etc/modprobe.d/
else
  echo "Aborted..."
fi

# echo "Enable System76 Scheduler?"
# if confirm_action; then
# 	sudo dnf copr enable -y kylegospo/system76-scheduler &&
# 		sudo dnf install -y system76-scheduler &&
# 		sudo systemctl daemon-reload &&
# 		sudo systemctl enable --now com.system76.Scheduler.service
#
# 	git clone https://github.com/maxiberta/kwin-system76-scheduler-integration.git &&
# 		kpackagetool6 --type KWin/Script -i ./kwin-system76-scheduler-integration
# else
# 	echo "Aborted..."
# fi

#
# SETUP
#
# import ssh keys
echo "Setup SSH/GPG keys and config?"
if confirm_action; then
  $CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME/.ssh/" &&
    sudo chown -R "$USER:$USER" "$HOME/.ssh" &&
    chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}
  # import GPG GitHub keys
  gpg --list-keys &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc

  $CP "$ROOT"/.gnupg/gpg-agent.conf "$HOME"/.gnupg/ &&
    gpg-connect-agent reloadagent /bye
else
  echo "Aborted..."
fi

echo "Perform user-specific customizations?"
if confirm_action; then
  $CP -r "$ROOT"/.config "$HOME/" &&
    $CP -r "$ROOT"/.local "$HOME/" &&
    $CP -r "$ROOT"/.wezterm.lua "$SUPPORT"/.gitconfig "$HOME/"

  sudo cat ./etc/environment | sudo tee -a /etc/environment
  $CP ./etc-systemd/zram-generator.conf /etc/systemd/zram-generator.conf &&
    $CP ./etc/nfancurve.conf /etc/

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

  NEW_PATH="$PATH:$HOME/.local/bin:$HOME/.local/share/bob/nvim-bin:$HOME/AppImages:/home/linuxbrew/.linuxbrew/bin"
  echo "export PATH=$NEW_PATH" >>"$HOME/.bashrc" &&
    export PATH=$NEW_PATH

  echo "Install Brew and some common utils?"
  if confirm_action; then
    sudo dnf install -y git &&
      bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" &&
      brew install eza fd ripgrep fzf bat fish zoxide xdotool

    # install some aliases for eza
    {
      echo "EZA_STANDARD_OPTIONS='--group --header --group-directories-first --icons --color=auto -A'"
      echo "alias ls='eza \$EZA_STANDARD_OPTIONS'"
      echo "alias ll='eza \$EZA_STANDARD_OPTIONS --long'"
      echo "alias llt='eza \$EZA_STANDARD_OPTIONS --long --tree'"
      echo "alias la='eza \$EZA_STANDARD_OPTIONS --all'"
      echo "alias l='eza \$EZA_STANDARD_OPTIONS'"
      echo "alias cat='bat'"
    } >>"$HOME/.bashrc"

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

  # install bob and latest stable neovim
  # unzip ./appimages/bob-linux-x86_64-openssl.zip -d "$HOME/.local/bin/" &&
  # 	mv "$HOME/.local/bin/bob-linux-x86_64-openssl/bob" "$HOME/.local/bin/"
  # chmod 0755 "$HOME/.local/bin/bob" &&
  # 	"$HOME/.local/bin/bob" use stable &&
  # 	echo "export PATH=$NEW_PATH" >>"$HOME/.bashrc" &&
  # 	source ~/.bashrc

  # install some common appimages
  NVIM_LOCAL="/usr/local/bin/nvim.AppImage"
  $CP ./appimages/nvim-0.10.0.AppImage "$NVIM_LOCAL" &&
    sudo chown root:root "$NVIM_LOCAL" &&
    sudo chmod 0755 "$NVIM_LOCAL" &&
    sudo ln -sf "$NVIM_LOCAL" /usr/local/bin/nvim

  mkdir -p "$HOME/AppImages/" &&
    $CP ./appimages/*.AppImage "$HOME/AppImages/" &&
    chmod 0755 "$HOME"/AppImages/*.AppImage
else
  echo "Aborted..."
fi

echo "Install CDEmu and KDE-CDEmu-Manager?"
if confirm_action; then
  sudo dnf copr enable -y rok/cdemu &&
    sudo dnf copr enable -y rodoma92/kde-cdemu-manager &&
    sudo dnf install -y kde-cdemu-manager-kf6 cdemu-daemon cdemu-client gcdemu libappindicator-gtk3 &&
    sudo akmods &&
    sudo systemctl restart systemd-modules-load.service

else
  echo "Aborted..."
fi

#
# SETUP DISTROBOX CONTAINERS
#
echo "Perform assembly and customization of Distrobox containers?"
if confirm_action; then
  sudo dnf install -y podman distrobox
  chmod +x distrobox-setup-*.sh
  distrobox assemble create --file ./distrobox-assemble.ini
  # ARCHLINUX
  distrobox-enter -n arch-cli -- bash -c ./distrobox-setup-archcli.sh
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
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user --noninteractive \
    runtime/org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/23.08 \
    runtime/org.gtk.Gtk3theme.adw-gtk3/x86_64/3.22 \
    runtime/org.gtk.Gtk3theme.adw-gtk3-dark/x86_64/3.22 \
    com.heroicgameslauncher.hgl \
    com.github.tchx84.Flatseal \
    com.github.zocker_160.SyncThingy \
    it.mijorus.gearlever \
    net.davidotek.pupgui2 \
    org.openrgb.OpenRGB \
    org.equeim.Tremotesf \
    io.github.dvlv.boxbuddyrs
else
  echo "Aborted..."
fi

# provide a way to pre-install libvirt/qemu
echo "Setup libvirt/qemu with vfio passthrough support?"
if confirm_action; then
  sudo dnf install @virtualization &&
    sudo systemctl enable libvirtd

  # add qemu specific kargs if they don't already exist
  sudo grubby --update-kernel=ALL --args='kvm.ignore_msrs=1 kvm.report_ignored_msrs=0 amd_iommu=on iommy=pt rd.driver.pre=vfio_pci vfio_pci.disable_vga=1'

  # install qemu hooks and reload libvirtd
  sudo mkdir -p /etc/libvirt/hooks &&
    sudo tar -xvzf "$SUPPORT"/vfio-hooks.tar.gz -C /etc/libvirt/hooks &&
    sudo systemctl restart libvirtd
else
  echo "Aborted..."
fi

echo "Finished!"
