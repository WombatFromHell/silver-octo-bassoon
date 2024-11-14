#!/usr/bin/env bash

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
  echo "Error: Cannot obtain sudo credentials!"
  exit 1
fi

sudo ln -s /usr/bin/distrobox-host-exec /usr/bin/podman &&
  sudo ln -s /usr/bin/distrobox-host-exec /usr/bin/docker

# install vscode repo and signing key
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >packages.microsoft.gpg
sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
rm -f packages.microsoft.gpg
sudo apt-get update -y &&
  sudo apt-get install -y code

# install firefox-dev edition repo and signing key
sudo mkdir -p /etc/apt/keyrings &&
  wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc | awk '/pub/{getline; gsub(/^ +| +$/,""); if($0 == "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3") print "\nThe key fingerprint matches ("$0").\n"; else print "\nVerification failed: the fingerprint ("$0") does not match the expected one.\n"}' &&
  echo '
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
' | sudo tee /etc/apt/preferences.d/mozilla &&
  echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null &&
  sudo apt-get update &&
  sudo apt-get install -y firefox-devedition

# install brave-browser repo and signing key
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" |
  sudo tee /etc/apt/sources.list.d/brave-browser-release.list
sudo apt-get update &&
  sudo apt-get install -y brave-browser

#
# install some common dev environment tools and repos
#
# add the eza community repo
# sudo mkdir -p /etc/apt/keyrings &&
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg &&
  echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list &&
  sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list &&
  sudo apt update &&
  sudo apt install -y bat fd-find ripgrep fish fzf zoxide eza xclip wl-clipboard pulseaudio &&
  sudo mv /usr/bin/cat /usr/bin/cat.old &&
  sudo ln -sf /usr/bin/batcat /usr/bin/bat &&
  sudo ln -sf /usr/bin/batcat /usr/bin/cat

# try to fix pinentry issues preemptively
sudo mv /usr/bin/gpg /usr/bin/gpg.disabled &&
  sudo mv /usr/bin/gpg-connect-agent /usr/bin/gpg-connect-agent.disabled &&
  sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/pinentry-qt &&
  sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/gpg &&
  sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/gpg-connect-agent &&
  pkill -9 gpg-agent && gpg-connect-agent reloadagent /bye

# link lazygit from the host
sudo ln -sf /usr/bin/distrobox-host-exec /usr/bin/lazygit

# link and apply fixup for docker/podman from the host
sudo ln -sf /usr/bin/distrobox-host-exec /usr/local/bin/podman &&
  sudo ln -sf /usr/local/bin/podman /usr/local/bin/docker &&
  sudo ln -sf /usr/bin/distrobox-host-exec /usr/local/bin/getenforce

# fix xdg-open in vscode (when interacting with flatpak)
sudo mv /usr/local/bin/xdg-open /usr/local/bin/xdg-open-host &&
  sudo mv /usr/bin/xdg-open /usr/bin/xdg-open-local &&
  sudo ln -s /usr/libexec/flatpak-xdg-utils/xdg-open /usr/bin/xdg-open

# check they've been installed correctly
if command -v code &>/dev/null; then
  # export them
  distrobox-export -a code &&
    distrobox-export -b /usr/bin/wl-copy &&
    distrobox-export -b /usr/bin/wl-paste &&
    distrobox-export -b /usr/bin/xclip &&
    distrobox-export -b /usr/bin/xclip-copyfile &&
    distrobox-export -b /usr/bin/xclip-cutfile &&
    distrobox-export -b /usr/bin/xclip-pastefile &&
    echo "GTK_USE_PORTAL=1" >>"$HOME"/.bashrc
else
  echo "Error! Cannot find 'code'!"
  exit 1
fi

if command -v brave-browser &>/dev/null; then
  distrobox-export -a brave-browser
else
  echo "Error! Cannot find 'brave-browser'!"
  exit 1
fi

if command -v firefox-devedition &>/dev/null; then
  distrobox-export -a firefox-devedition
else
  echo "Error! Cannot find 'firefox-devedition'!"
  exit 1
fi
