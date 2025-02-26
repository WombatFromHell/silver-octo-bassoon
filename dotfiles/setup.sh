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

check_program() {
	local program=$1
	local message=${2:-"Error: $program is required, skipping..."}
	if ! command -v "$program" &>/dev/null; then
		echo "$message"
		return 1
	else
		return 0
	fi
}

which_early_bail() {
	if ! check_program "$1"; then
		return 1
	else
		return 0
	fi
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
	cmds=("git" "nix")
	for c in "${cmds[@]}"; do
		if ! check_program "$c" "Error: cannot find '$c'!"; then
			return 1
		fi
	done
	git clone git@github.com:WombatFromHell/automatic-palm-tree.git "$script_dir"/nix
}

handle_home() {
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
		stow -R "home"
		echo -e "\n$HOME has been stowed!"
		return 0
	else
		return 1
	fi
}

handle_scripts() {
	local dir=$1
	local target="$HOME/.local/bin/scripts"

	if confirm "Are you sure you want to stow $dir?"; then
		remove_this "$target"
		# make sure the parent exists
		mkdir -p "$(dirname "$target")"
		chmod +x "./$1"/*.sh
		# just link, don't stow
		ln -sf "$script_dir/$1" "$target"
		echo -e "\nSuccessfully stowed $dir!"
		return 0
	else
		return 1
	fi
}

handle_pipewire() {
	local dir=$1
	local target=$2
	local os=$3

	if [[ "$os" == "Linux" ]] && confirm "Are you sure you want to stow $dir?"; then
		local tgt=".config/pipewire"
		local hesuvi_tgt="$HOME/$tgt/hrir.wav"
		sed -i \
			"s|%PATH%|$hesuvi_tgt|g" \
			"./$dir/$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
		stow -R "$dir"
		echo -e "\nSuccessfully stowed $dir!"
		return 0
	else
		echo -e "\nSkipping $dir stow on $os..."
		return 1
	fi
}

handle_spicetify() {
	check_program "spicetify"

	local dir="$1"
	local target="$2"
	local bypass="$3"

	if [ -z "$bypass" ] && confirm "Are you sure you want to stow $dir?"; then
		if command -v spicetify &>/dev/null; then
			echo -e "\nMake sure to double check your 'prefs' path at: $target/config-xpui.ini"
			stow -R "$dir"
			echo -e "\nSuccessfully stowed $dir!"
			return 0
		else
			if confirm "Download and install 'spicetify'?"; then
				curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh
				handle_spicetify "$dir" "$target" true
			else
				return 1
			fi
		fi
	else
		return 1
	fi
}

handle_tmux() {
	check_program "tmux"

	local dir=$1
	local target="$2"

	if confirm "Are you sure you want to stow $dir?"; then
		if check_program "git" "Error: 'git' command not found!"; then
			echo -e "\nWiping old '$dir' config..."
			rm -rf ./"$dir"/.config/tmux/plugins/ "$target"
			echo -e "\nFetching 'tpm'..."
			git clone https://github.com/tmux-plugins/tpm ./"$dir"/.config/tmux/plugins/tpm
			stow -R "$dir"
			echo -e "\nSuccessfully stowed $dir!"
			return 0
		else
			return 1
		fi
	else
		return 1
	fi
}

do_pre_stow() {
	local dir=$1
	local target=$2
	local os=$3

	case "$dir" in
	hypr) which_early_bail "hyprland" ;;
	MangoHud) which_early_bail "mangohud" ;;
	topgrade.d) which_early_bail "topgrade" ;;

	home) handle_home "$os" ;;
	pipewire) handle_pipewire "$dir" "$target" "$os" ;;
	scripts) handle_scripts "$os" ;;
	systemd)
		# exclude systemd on non-Linux OS'
		if [[ "$os" != "Linux" ]]; then
			echo -e "\nSkipping $dir stow on $os..."
			return 1
		fi
		;;

	nix) return 1 ;;
	spicetify) handle_spicetify "$dir" "$target" ;;
	tmux) handle_tmux "$dir" "$target" "$os" ;;

	*) which_early_bail "$dir" ;;
	esac
}

do_post_stow() {
	local dir=$1
	local target=$2
	local os=$3

	case "$dir" in
	home)
		if [ "$os" == "NixOS" ]; then
			# let nix flake determine global profile vars
			remove_this "$HOME"/.profile
		elif check_program "uwsm" "Error: 'uwsm' not found, skipping!"; then
			# workaround uwsm not handling env import properly
			remove_this "$HOME/.config/uwsm"
			mkdir -p "$HOME/.config/uwsm"
			ln -sf "$HOME/.profile" "$HOME/.config/uwsm/env"
		fi
		;;
	fish) fish -c "fisher update" ;;
	bat) bat cache --build ;;
	tmux)
		remove_this "$HOME"/.tmux.conf
		ln -sf "$HOME"/.config/tmux/tmux.conf "$HOME"/.tmux.conf
		;;
	esac
}

do_stow() {
	local dir=$1
	local target=$2
	local os=$3

	if confirm "Removing all files from $target before stowing"; then
		remove_this "$target"
		mkdir -p "$target"/
		stow -R "$dir"
		echo -e "\n'$dir' has been stowed!"
		return 0
	else
		return 1
	fi
}

handle_stow() {
	local dir=$1
	local target="$HOME/.config/$dir"
	local os
	os=$(check_for_os)

	if ! do_pre_stow "$dir" "$target" "$os"; then
		return
	fi
	if ! do_stow "$dir" "$target" "$os"; then
		return
	fi
	do_post_stow "$dir" "$target" "$os"
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
