#!/usr/bin/env bash

# cache credentials
sudo -v &
pid=$!
wait $pid
if [ "$?" -eq 130 ]; then
	echo "Error: Cannot obtain sudo credentials!"
	exit 1
fi

SUPPORT="../support/debian-cli"

# install and export TRguiNG
sudo apt-get update &&
	sudo apt-get upgrade -y &&
	sudo apt-get install -y libwebkit2gtk "$SUPPORT"/trgui-ng_1.4.0_amd64.deb

if command -v trgui-ng &>/dev/null; then
	distrobox-export -a trgui-ng
else
	echo "Error! Cannot find 'trgui-ng'!"
	exit 1
fi
