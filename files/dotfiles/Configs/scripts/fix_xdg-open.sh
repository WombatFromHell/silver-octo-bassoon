#!/usr/bin/env bash

XDGSET="$(which xdg-settings)"
BROWSER=$(grep "^BrowserApplication=" ~/.config/kdeglobals | cut -d '=' -f2-)

if [ -n "$XDGSET" ] && [ -n "$BROWSER" ] &&
	xdg-settings set default-web-browser "$BROWSER"; then
	echo "Success! KDE BrowserApplication and xdg-settings set to matching browser!"
else
	echo "Error: something went wrong!"
	exit 1
fi
