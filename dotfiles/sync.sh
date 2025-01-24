#!/usr/bin/env bash

script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
	echo "Error: script must be run from the same directory as the dotfiles!"
	exit 1
fi

LOCAL="."
REMOTE="/mnt/home/GDrive/Backups/linux-config/backups/dotfiles/"

if ! [ -r "$LOCAL" ]; then
	echo "Error: $LOCAL does not exist or is not readable!"
	exit 1
fi
if ! [ -r "$REMOTE" ]; then
	echo "Error: $REMOTE does not exist or is not readable!"
	exit 1
fi

help() {
	echo "Usage: $0 [--swap]"
	exit 1
}

confirm() {
	read -r -p "$1 (y/N) " response
	if [[ "$response" == "y" || "$response" == "Y" ]]; then
		return 0
	else
		echo "Aborting..."
		return 1
	fi
}

CMD=(rsync -avzL --checksum --partial --update --info=progress2)
EXCLUDES=(
	--exclude=__pycache__/
	--exclude=pipewire/
	--exclude='*.wants/'
)

sync() {
	CMD+=("--delete" "${EXCLUDES[@]}" "--dry-run")
	echo "==== PERFORMING A DRY RUN ===="
	if [ "$swap" == true ]; then
		echo "Syncing $2 => $1"
		"${CMD[@]}" "$2" "$1"
		if confirm "Please confirm sync of: $2 => $1"; then
			unset 'CMD[${#CMD[@]}-1]'
			"${CMD[@]}" "$2" "$1"
			# echo "Would normally do: ${CMD[*]} $2 $1"
		fi
	else
		echo "Syncing $1 => $2"
		"${CMD[@]}" "$1" "$2"
		if confirm "Please confirm sync of: $1 => $2"; then
			unset 'CMD[${#CMD[@]}-1]'
			"${CMD[@]}" "$1" "$2"
			# echo "Would normally do: ${CMD[*]} $1 $2"
		fi
	fi
}

if [ "$1" == "--help" ]; then
	help
elif [ "$1" == "--swap" ]; then
	swap=true
fi

sync "$LOCAL" "$REMOTE"
