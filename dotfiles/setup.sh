#!/usr/bin/env bash

OS=$(uname -a)
AUTO_CONFIRM=false
# Ensure script runs from its directory
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$script_dir" || exit 1

show_help() {
	echo "Usage: $(basename "$0") [-y|--confirm] [--fix-perms] [--fetch-nix] [-h|--help]"
	echo "Options:"
	echo "  -y, --confirm     Skip confirmation prompts"
	echo "  --fix-perms       Normalize this repo's file permissions"
	echo "  --fetch-nix       Grab Nix flake from GitHub"
	echo "  -h, --help        Show this help message"
	exit 0
}

fix_perms() {
	local filter
	filter=(-not -type l -not -path "nix/*")

	find . -type d "${filter[@]}" -print0 | xargs -0 chmod 0755
	find . -type f "${filter[@]}" -print0 | xargs -0 chmod 0644
	find . \( -type f "${filter[@]}" -name "*.tmux" \
		-o -type f "${filter[@]}" -name "*.sh" \
		-o -type f "${filter[@]}" -name "tpm" \
		-o -type f "${filter[@]}" -path "scripts/*.py" \) \
		-print0 | xargs -0 chmod 0755

	echo "Fixed repo permissions..."
}

confirm() {
	[[ "$AUTO_CONFIRM" == true ]] && return 0
	read -r -p "$1 (y/N) " response
	[[ "$response" == "y" || "$response" == "Y" ]]
}

check_for_os() {
	if echo "$OS" | grep -q "NixOS"; then
		echo "NixOS"
	elif echo "$OS" | grep -q "Darwin"; then
		echo "Darwin"
	elif echo "$OS" | grep -q "Linux"; then
		echo "Linux"
	else
		echo "Other"
	fi
}

remove_this() {
	if [[ -L "$1" ]] && unlink "$1"; then
		return 0
	else
		rm -rf "${1:?}"/
		return 1
	fi
}

fetch_nix() {
	GIT=$(command -v git)
	NIX=$(command -v nix)
	if [[ -z "$GIT" ]]; then
		echo "Error: cannot find 'git', might not be installed?"
		exit 1
	fi
	if [[ -z "$NIX" ]]; then
		echo "Warning: cannot find 'nix', might not be installed?"
		exit 1
	fi
	git clone git@github.com:WombatFromHell/automatic-palm-tree.git "$script_dir"/nix
}

handle_home() {
	local dir=$1
	local target=$2

	if confirm "Are you sure you want to stow $HOME?"; then
		local files=(
			".gitconfig"
			".profile"
			".bashrc"
			".zshrc"
			".wezterm.lua"
		)
		for file in "${files[@]}"; do
			cp -f "$HOME/$file" "$HOME/${file}.stowed"
			rm -f "$HOME/$file"
		done
		stow -R "$dir"

		# workaround uwsm not handling env import properly
		remove_this "$HOME/.config/uwsm"
		mkdir -p "$HOME/.config/uwsm"
		ln -sf "/.profile" "$HOME/.config/uwsm/env"
		echo -e "\n$HOME has been stowed!"
	fi
}

handle_scripts() {
	local dir=$1
	local target=$2

	if confirm "Are you sure you want to stow $dir?"; then
		local target="$HOME/.local/bin/scripts"
		remove_this "$target"
		mkdir -p "$(dirname "$target")"
		chmod +x "./$1"/*.sh
		# just link, don't stow
		ln -sf "$script_dir/$1" "$target"
		echo -e "\nSuccessfully stowed $dir!"
	fi
}

handle_pipewire() {
	local dir=$1
	local target=$2

	local os
	os=$(check_for_os)

	if [[ "$os" == "Linux" ]] && confirm "Are you sure you want to stow $dir?"; then
		local tgt=".config/pipewire"
		local hesuvi_tgt="$HOME/$tgt/hrir.wav"
		sed -i \
			"s|%PATH%|$hesuvi_tgt|g" \
			"./$dir/$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
		stow -R "$dir"
		echo -e "\nSuccessfully stowed $dir!"
	else
		echo -e "\nSkipping $dir stow on $os..."
	fi
}

handle_tmux() {
	local dir=$1
	local target="$2"

	if confirm "Are you sure you want to stow $dir?"; then
		if command -v git &>/dev/null; then
			echo -e "\nWiping old '$dir' config..."
			rm -rf ./"$dir"/.config/tmux/plugins/ "$target"
			echo -e "\nFetching 'tpm'..."
			git clone https://github.com/tmux-plugins/tpm ./"$dir"/.config/tmux/plugins/tpm
			stow -R "$dir"
			echo -e "\nSuccessfully stowed $dir!"
		else
			echo "Error: cannot find 'git', aborting!"
		fi
	fi
}

handle_stow() {
	local dir=$1
	local target="$HOME/.config/$dir"

	local os
	os=$(check_for_os)

	case "$dir" in

	home)
		target="$HOME"
		handle_home "$dir" "$target"
		;;

	scripts)
		target="$HOME/.local/bin/scripts"
		handle_scripts "$dir" "$target"
		;;

	pipewire)
		handle_pipewire "$dir" "$target"
		;;

	tmux)
		handle_tmux "$dir" "$target"
		;;

	*)
		#
		# Pre-stow actions
		#
		case "$dir" in
		systemd)
			# exclude systemd on non-Linux OS'
			if [[ "$os" != "Linux" ]]; then
				echo -e "\nSkipping $dir stow on $os..."
				return
			fi
			;;
		esac

		if confirm "Removing all files from $target before stowing"; then
			remove_this "$target"
			mkdir -p "$target"/
			stow -R "$dir"
			echo -e "\n'$dir' has been stowed!"

			#
			# Post-stow actions
			#
			case "$dir" in
			home)
				if [ "$os" == "NixOS" ]; then
					# let nix flake determine global profile vars
					remove_this "$HOME"/.profile
				fi
				;;
			fish) fish -c "fisher update" ;;
			bat) bat cache --build ;;
			tmux)
				remove_this "$HOME"/.tmux.conf
				ln -sf "$HOME"/.config/tmux/tmux.conf "$HOME"/.tmux.conf
				;;
			esac
		fi
		;;
	esac
}

main() {
	fix_perms # normalize permissions
	mapfile -t directories < <(find . -mindepth 1 -maxdepth 1 -type d | sed 's|^./||' | sort)
	for dir in "${directories[@]}"; do
		handle_stow "$dir"
	done
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
	-y | --confirm)
		AUTO_CONFIRM=true
		shift
		;;
	--fix-perms)
		fix_perms
		shift
		exit 0
		;;
	--fetch-nix)
		fetch_nix
		shift
		exit 0
		;;
	-h | --help)
		show_help
		;;
	esac
done

main
