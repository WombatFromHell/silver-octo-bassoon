#!/usr/bin/env bash

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
	echo "Error: Cannot obtain sudo credentials!"
	exit 1
fi

# SETUP DISTROBOX ARCH-CLI
sudo ln -s /usr/bin/distrobox-host-exec /usr/bin/podman &&
	sudo ln -s /usr/bin/distrobox-host-exec /usr/bin/docker
# enable systemd and dbus
sudo ln -s /run/host/run/systemd/system /run/systemd &&
	sudo mkdir -p /run/dbus &&
	sudo ln -s /run/host/run/dbus/system_bus_socket /run/dbus &&
	sudo pacman -S --noconfirm dbus-broker
# enable paru
sudo pacman -Syu --needed --noconfirm &&
	cd ~/Downloads &&
	git clone https://aur.archlinux.org/paru.git &&
	cd paru && makepkg -si --noconfirm
# install some common tools and services
#paru -S --noconfirm nvfancontrol
paru -S --noconfirm joystickwake

if command -v nvfancontrol; then
	distrobox-export -b $(which nvfancontrol)
	systemctl --user enable --now nvfancontrol.service
	exit 0
fi
if command -v joystickwake; then
	distrobox-export -b $(which joystickwake)
	systemctl --user enable joystickwake.service && \
		systemctl --user start joystickwake
	exit 0
fi
exit 1
