#!/usr/bin/env bash

if command -v "$HOME"/.nix-profile/bin/fish &>/dev/null; then
	# prioritize nix fish over system fish
	exec "$HOME"/.nix-profile/bin/fish "$@"
elif command -v /home/linuxbrew/.linuxbrew/bin/fish &>/dev/null; then
	# use linuxbrew fish if it exists
	exec /home/linuxbrew/.linuxbrew/bin/fish "$@"
else
	# default to whatever else is in the environment
	FISH="$(which fish)"
	if [ -e "$FISH" ]; then
		exec "$FISH" "$@"
	fi
fi
