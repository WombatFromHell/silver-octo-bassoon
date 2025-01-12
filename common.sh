#!/usr/bin/env bash

SUPPORT="./support"
CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"

# cache credentials
cache_creds() {
	sudo -v &
	pid=$!
	wait $pid
	if [ "$?" -eq 130 ]; then
		echo "Error: Cannot obtain sudo credentials!"
		exit 1
	fi
}

confirm() {
	read -r -p "$1 (Y/n) " response
	case "$response" in
	[nN])
		echo "Action aborted..."
		return 1
		;;
	[yY] | "")
		return 0
		;;
	*)
		echo "Action aborted!"
		return 1
		;;
	esac
}

update_grub_cmdline() {
	local text_to_add="$1"
	local target_file="/etc/default/grub"
	local backup_file="${target_file}.bak"
	local variable_name="GRUB_CMDLINE_LINUX_DEFAULT"

	# Create a backup of the target file
	if ! sudo cp -f "$target_file" "$backup_file"; then
		echo "Error: Failed to create backup file."
		return 1
	fi
	# Check if the text already exists in the target file
	if grep -q "$text_to_add" "$target_file"; then
		echo "Text already exists in $target_file. No changes made."
		return 1
	fi

	sudo sed -i "s/^$variable_name=\"\(.*\)\"/$variable_name=\"\1 $text_to_add\"/" "$target_file"
}
