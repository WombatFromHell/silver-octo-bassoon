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
CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
  echo "Error: Cannot obtain sudo credentials!"
  exit 1
fi

#
# SETUP
#
#
echo "Add some kernel args for OpenRGB Gigabyte Mobo support?"
if confirm_action; then
  rpm-ostree kargs --append=amd_pstate=active --append=acpi_enforce_resources=lax
else
  echo "Aborted..."
fi

# import ssh keys
echo "Setup SSH/GPG keys and config?"
if confirm_action; then
  $CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
    sudo chown -R "$USER:$USER" "$HOME"/.ssh
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

# enable optional mounts via systemd-automount
echo "Setup external mounts?"
if confirm_action; then
  for i in automount mount; do
    for j in Downloads FTPRoot home linuxgames SSDDATA1; do
      sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-$j.$i >./systemd-automount/var-mnt-$j.$i
      $CP ./systemd-automount/var-mnt-$j.$i /etc/systemd/system/ &&
        sudo chown root:root /etc/systemd/system/*.*mount &&
        sudo mkdir -p /var/mnt/$j &&
        rm ./systemd-automount/var-mnt*.*mount
    done
    # modify and copy and any swap file mounts
    sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-linuxgames-Games-swapfile.swap \
      >./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap
    $CP ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
      sudo chown root:root /etc/systemd/system/*.swap &&
      rm ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap
  done
  $CP "$SUPPORT"/.smb-credentials /etc/ &&
    sudo chown root:root /etc/.smb-credentials &&
    sudo chmod 0400 /etc/.smb-credentials &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable --now var-mnt-{Downloads,FTPRoot,home,SSDDATA1,linuxgames}.automount
  #sudo systemctl enable --now var-mnt-linuxgames-Games-swapfile.swap
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

  $CP ./etc-X11/Xwrapper.config /etc/X11/ &&
    $CP ./etc-xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/

  $CP ./usr-local-bin/*.sh /usr/local/bin/ &&
    sudo chown root:root /usr/local/bin/*.sh &&
    sudo chmod 0755 /usr/local/bin/*.sh

  $CP ./etc-systemd/system/* /etc/systemd/system/ &&
    sudo chown root:root /etc/systemd/system/{fix-wakeups.service,nvidia-tdp.*} &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable --now fix-wakeups.service &&
    sudo systemctl enable --now nvidia-tdp.service

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
    ujust install-brew
    brew install eza fd ripgrep fzf bat clipboard xclip
    tar -xvzf "$SUPPORT"/appimages/lazygit_0.42.0_Linux_x86_64.tar.gz &&
      sudo mv lazygit /usr/local/bin/

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
    com.github.zocker_160.SyncThingy \
    dev.vencord.Vesktop \
    org.openrgb.OpenRGB org.equeim.Tremotesf
else
  echo "Aborted..."
fi

echo "Finished!"
