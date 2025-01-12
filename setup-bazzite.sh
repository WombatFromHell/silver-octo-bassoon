#!/usr/bin/env bash

source ./common.sh
cache_creds

if confirm "Add some kernel args for OpenRGB Gigabyte Mobo support?"; then
  rpm-ostree kargs --append=amd_pstate=active --append=acpi_enforce_resources=lax
fi

# import ssh keys
if confirm "Setup SSH/GPG keys and config?"; then
  $CP "$SUPPORT"/.ssh/{id_rsa,id_rsa.pub,config} "$HOME"/.ssh/ &&
    sudo chown -R "$USER:$USER" "$HOME"/.ssh
  chmod 0400 "$HOME"/.ssh/{id_rsa,id_rsa.pub}
  # import GPG GitHub keys
  gpg --list-keys &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/public-key.asc &&
    gpg --import "$SUPPORT"/.ssh/gnupg-keys/private-key.asc

  $CP "$SUPPORT"/.gnupg/gpg-agent.conf "$HOME"/.gnupg/ &&
    gpg-connect-agent reloadagent /bye
fi

# enable optional mounts via systemd-automount
if confirm "Setup external mounts?"; then
  for i in automount mount; do
    for j in Downloads FTPRoot home linuxgames linuxdata; do
      sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-$j.$i >./systemd-automount/var-mnt-$j.$i
      $CP ./systemd-automount/var-mnt-$j.$i /etc/systemd/system/ &&
        sudo chown root:root /etc/systemd/system/*.*mount &&
        sudo mkdir -p /var/mnt/$j &&
        rm ./systemd-automount/var-mnt*.*mount
    done
  done

  # modify and copy and any swap file mounts
  sed 's/mnt\//var\/mnt\//g' ./systemd-automount/mnt-linuxgames-Games-swapfile.swap \
    >./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap
  $CP ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap /etc/systemd/system/ &&
    sudo chown root:root /etc/systemd/system/*.swap &&
    rm ./systemd-automount/var-mnt-linuxgames-Games-swapfile.swap

  $CP "$SUPPORT"/.smb-credentials /etc/ &&
    sudo chown root:root /etc/.smb-credentials &&
    sudo chmod 0400 /etc/.smb-credentials &&
    sudo systemctl daemon-reload
  # sudo systemctl enable --now var-mnt-{Downloads,FTPRoot,home,linuxgames,linuxdata}.automount
  sudo systemctl enable --now var-mnt-linuxgames-Games-swapfile.swap
fi

if confirm "Perform user-specific customizations?"; then
  $CP -r "$SUPPORT"/bin/ "$HOME"/.local/bin/ &&
    $CP -r "$SUPPORT"/.gitconfig "$HOME"/

  sudo cat ./etc/environment | sudo tee -a /etc/environment
  #$CP ./etc-systemd/zram-generator.conf /etc/systemd/zram-generator.conf

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

  # disable systemd suspend user when entering suspend
  sudo rsync -rvh --chown=root:root --chmod=D755,F644 ./etc-systemd/system/systemd-{homed,suspend}.service.d /etc/systemd/system/ &&
    sudo systemctl daemon-reload

  # enable some secondary user-specific services
  systemctl --user daemon-reload &&
    chmod 0755 "$HOME"/.local/bin/* &&
    systemctl --user enable --now on-session-state.service

  # SETUP USER DEPENDENCIES
  if confirm "Install common user fonts?"; then
    mkdir -p ~/.fonts &&
      tar xvzf "$SUPPORT"/fonts.tar.gz -C ~/.fonts/ &&
      fc-cache -fv
  fi

  if confirm "Install Brew and some common utils?"; then
    if command -v brew >/dev/null; then
      brew install eza fd ripgrep fzf bat lazygit
    else
      echo "Error! Cannot find 'brew'!"
      exit 1
    fi

    # install some aliases for eza
    cat <<EOF >>"$HOME"/.bashrc
# If not running interactively, don't do anything
! [[ -n "\$PS1" ]] && return
[ -f "/var/run/.containerenv" ] && [[ "\$HOSTNAME" == *debian-dev* ]] && /usr/bin/fish -l
if ! [ -f "/var/run/.containerenv" ] && ! [[ "\$HOSTNAME" == *libvirt* ]]; then
  EZA_STANDARD_OPTIONS='--group --header --group-directories-first --icons --color=auto -A'
  alias ls='eza \$EZA_STANDARD_OPTIONS'
  alias ll='eza \$EZA_STANDARD_OPTIONS --long'
  alias llt='eza \$EZA_STANDARD_OPTIONS --long --tree'
  alias la='eza \$EZA_STANDARD_OPTIONS --all'
  alias l='eza \$EZA_STANDARD_OPTIONS'
  alias cat='bat'
fi
EOF
  fi

  if confirm "Install Nix as an alternative to Brew?"; then
    chmod +x "$SUPPORT"/lix-installer
    "$SUPPORT"/lix-installer install ostree
    echo && echo "Don't forget to copy \"./home-manager/home.nix\" and do: home-manager switch!"
  fi

  if confirm "Install customized NeoVim config?"; then
    rm -rf "$HOME"/.config/nvim "$HOME"/.local/share/nvim "$HOME"/.local/cache/nvim
    git clone git@github.com:WombatFromHell/lazyvim.git "$HOME"/.config/nvim
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
export EDITOR='/usr/local/bin/nvim'
export VISUAL='/usr/local/bin/nvim'
alias edit='\$EDITOR'
alias sedit='sudo -E \$EDITOR'
EOF
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
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user --noninteractive \
    com.vysp3r.ProtonPlus \
    com.github.zocker_160.SyncThingy
  # add a workaround for degraded notification support cased by libnotify
  flatpak override --user --socket=session-bus --env=NOTIFY_IGNORE_PORTAL=1 --talk-name=org.freedesktop.Notifications org.mozilla.firefox

  if confirm "Install Flatpak version of Brave browser?"; then
    flatpak install --user --noninteractive com.brave.Browser
    chmod +x ./support/brave-flatpak-fix.sh
    # include a fix for hardware acceleration
    ./support/brave-flatpak-fix.sh
  fi
fi

# fix libva-nvidia-driver using git version of nvidia-vaapi-driver
if confirm "Fix libva-nvidia-driver for Flatpak version of Firefox?"; then
  outdir="$HOME/.var/app/org.mozilla.firefox/dri"
  mkdir -p "$outdir" && rm -rf "$outdir"/*.* || exit 1
  unzip "$SUPPORT"/libva-nvidia-driver_git-0.0.13.zip -d "$outdir"
  flatpak override --user --env=LIBVA_DRIVERS_PATH="$outdir" org.mozilla.firefox
  flatpak --system --noninteractive remove org.mozilla.firefox &&
    flatpak --user --noninteractive install org.mozilla.firefox org.freedesktop.Platform.ffmpeg-full
fi

echo "Finished!"
