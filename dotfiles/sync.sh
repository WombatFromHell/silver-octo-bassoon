#!/usr/bin/env bash
LOCAL="."
REMOTE="$(realpath "$HOME/.nas-home")/Projects/silver-octo-bassoon/dotfiles/"

_CMD=(rsync -avL --checksum --update)
EXCLUDES=(
	--exclude='__pycache__/'
	--exclude='monitor-session/'
	--exclude='nix/'
	--exclude='logs/'
	--exclude='pipewire.conf.d/'
	--exclude='*.wants/'
	--exclude='tmux/plugins/*'
	--exclude='hrir.wav'
	--exclude='tray.target'
	--exclude='gpg-agent*'
)

script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
	echo "Error: script must be run from the dotfile root directory!"
	exit 1
fi

if ! [ -r "$LOCAL" ]; then
	echo "Error: $LOCAL does not exist or is not readable!"
	exit 1
fi
if ! [ -r "$REMOTE" ]; then
	echo "Error: $REMOTE does not exist or is not readable!"
	exit 1
fi

help() {
	echo "Usage: $0 [--help | --swap | --force]"
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

equality() {
	if [ "$FORCE" -eq 1 ]; then
		return 1
	fi

	local result
	result=$(
		"${EQ_CMD[@]}" "$@" |
			grep "Number of regular files transferred" |
			awk -F ": " '{print $2}'
	)

	if [ "${result:-0}" -eq 0 ]; then
		echo "No changes detected!"
		return 0
	else
		return 1
	fi
}

do_sync() {
	local pipe_cmd
	pipe_cmd=$(printf " | %s" "${SUFFIX[@]}")
	pipe_cmd=${pipe_cmd:3} # Remove the leading " | "

	if [ "$FORCE" -eq 1 ]; then
		echo "==== PERFORMING A HARD DRY RUN ===="
		UP_CMD=("${UP_CMD[@]}" "-WI")
		echo "DEBUG: ${UP_CMD[*]}"
	else
		echo "==== PERFORMING A DRY RUN ===="
	fi

	"${UP_CMD[@]}" "--dry-run" "$@" | eval "$pipe_cmd"
	if echo && confirm "Confirm syncing: $1 => $2"; then
		"${UP_CMD[@]}" "$@" | eval "$pipe_cmd"
		echo
	fi
}

sync() {
	if [ "$SWAP" -eq 1 ]; then
		TARGETS=("$2" "$1")
	else
		TARGETS=("$1" "$2")
	fi

	if ! equality "${TARGETS[@]}"; then
		do_sync "${TARGETS[@]}"
	fi
}

SWAP=0
FORCE=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--help)
		help
		;;
	--swap)
		shift
		SWAP=1
		;;
	--force)
		shift
		FORCE=1
		;;
	*)
		echo "Invalid argument: $1"
		help
		;;
	esac
done

if [ "$FORCE" -eq 1 ]; then
	# strip out "--checksum" and "--update"
	_CMD=("${_CMD[@]:0:3}" "--force" "-WI")
	DOWN_CMD=("${_CMD[@]}" "--delete" "${EXCLUDES[@]}")
	UP_CMD=("${DOWN_CMD[@]}")
else
	DOWN_CMD=("${_CMD[@]}" "${EXCLUDES[@]}")
	UP_CMD=("${DOWN_CMD[@]}" "--delete")
fi
EQ_CMD=("${DOWN_CMD[@]}" "--stats" "--dry-run")
SUFFIX=("grep -v '/$'" "grep -v '^sending incremental file list$'")

if ! [ -w "$REMOTE" ]; then
	echo "Error: $REMOTE does not exist or is not writable!"
	exit 1
fi
sync "$LOCAL" "$REMOTE"
