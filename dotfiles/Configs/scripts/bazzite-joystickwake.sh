#!/usr/bin/env bash

if /usr/libexec/hwsupport/valve-hardware; then
	# Don't do anything on Valve hardware, prevents lizard mode from working properly.
	exit 0
fi

JOYSTICKWAKE="$(which joystickwake)"
"$JOYSTICKWAKE" --command "qdbus org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement wakeup" "$@"
