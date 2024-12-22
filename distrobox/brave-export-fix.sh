#!/usr/bin/env bash
XDG_LOCAL="$HOME/.local"
BRAVE_EXPORT="$XDG_LOCAL/share/applications/devbox-brave-browser.desktop"
BRAVE="/usr/bin/distrobox-enter  -n devbox  --   /usr/bin/brave-browser-stable"
BRAVER="$XDG_LOCAL/bin/brave.sh"

BRAVE_ESC=$(echo "$BRAVE" | sed 's#\/#\\/#g')
BRAVER_ESC=$(echo "$BRAVER" | sed 's#\/#\\/#g')

if [ ! -f "$BRAVE_EXPORT" ]; then
	echo "Error: Brave export file not found!"
	exit 1
fi

cp -f "$BRAVE_EXPORT" "$BRAVE_EXPORT.bak"
sed -i "s#${BRAVE_ESC}#${BRAVER_ESC}#g" "$BRAVE_EXPORT"
sudo update-desktop-database
