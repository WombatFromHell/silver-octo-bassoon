#!/usr/bin/env bash

ROOT="./Configs"
AUTO_CONFIRM=false

# Ensure the script runs from its directory
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
	local filter=(-not -type l -not -path "nix/*")
	find . -type d "${filter[@]}" -print0 | xargs -0 chmod 0755
	find . -type f "${filter[@]}" -print0 | xargs -0 chmod 0644
	find . \( \
		-type f -name "*.tmux" \
		-o -type f -name "*.sh" \
		-o -type f -name "tpm" \
		-o -path "$ROOT/tmux/.config/tmux/plugins/tpm/bindings/*" \
		-o -path "$ROOT/scripts/*.py" \
		\) \
		"${filter[@]}" -print0 | xargs -0 chmod 0755
	echo "Repo permissions fixed!"
}

confirm() {
	[[ "$AUTO_CONFIRM" == true ]] && return 0
	read -r -p "$1 (y/N) " response
	[[ "$response" == "y" || "$response" == "Y" ]]
}

check_program() {
	local prog=$1
	local msg=${2:-"Error: $prog is required, skipping..."}
	if ! which "$prog" &>/dev/null; then
		echo "$msg"
		return 1
	fi
	return 0
}

is_archlike() {
	local os="$1"
	local archlikes=("Arch" "CachyOS")
	for os_name in "${archlikes[@]}"; do
		if [ "$os_name" == "$os" ]; then
			return 0
		fi
	done
	return 1
}
check_os() {
	local os=""
	if [ -f "/etc/os-release" ]; then
		os="$(grep "NAME=" /etc/os-release | head -n 1 | cut -d\" -f2 | cut -d' ' -f1)"
	fi
	local kernel
	kernel="$(uname -s)"

	if [ "$kernel" == "Darwin" ]; then
		echo "Darwin"
	elif is_archlike "$os"; then
		echo "Arch"
	elif [ "$os" == "Bazzite" ] || [ "$os" == "NixOS" ]; then
		echo "$os"
	elif [ "$kernel" == "Linux" ]; then
		echo "Linux"
	else
		echo "Unknown"
	fi
}
OS="$(check_os)"
is_linux() {
	case "$OS" in
	# do NOT list NixOS variants here!
	"Linux" | "Arch" | "Bazzite") return 0 ;;

	*) return 1 ;;
	esac
}

remove_this() {
	local target="$1"
	local use_sudo="${2:-sudo}"
	if [[ -L "$target" ]]; then
		if [[ "$use_sudo" == "sudo" ]]; then
			command=(sudo unlink)
		else
			command=(unlink)
		fi
		"${command[@]}" "$target" && return 0
		return 1
	fi

	if [[ "$use_sudo" == "sudo" ]]; then
		command=(sudo rm -rf)
	else
		command=(rm -rf)
	fi
	"${command[@]}" "$target" && return 0
	return 1
}

stow_this() {
	tuckr rm "$1"
	if tuckr add -f -y "$1"; then
		echo "Successfully stowed '$1'!"
		return 0
	else
		echo "Error: failed to stow '$1'!"
		return 1
	fi
}

fetch_nix() {
	for cmd in git nix; do
		check_program "$cmd" "Error: cannot find '$cmd'!" || exit 1
	done
	if [ -d "$HOME/.nix" ]; then
		echo "Error: $HOME/.nix already exists or cannot be fetched!"
		exit 1
	fi
	if git clone git@github.com:WombatFromHell/automatic-palm-tree.git "$HOME/.nix"; then
		echo "Cloned Nix flake from Github to $HOME/.nix!"
	else
		echo "Error: fetching Nix flake failed!"
		exit 1
	fi
}

handle_home() {
	local src_dir="$ROOT/home"
	if ! confirm "Are you sure you want to stow '$HOME'?"; then
		return 1
	fi
	for item in "$src_dir"/* "$src_dir"/.*; do
		local filename
		filename="$(basename "$item")"
		local tgt="$HOME/$filename"
		if [ -f "$item" ] && [ -e "$tgt" ]; then
			cp -f "$tgt" "${tgt}.stowed" # Backup existing dotfile
			remove_this "$tgt"
		fi
	done
	stow_this "home"
	return 2
}

handle_openrgb() {
	export PATH="$PATH:$HOME/.local/bin:/usr/local/bin"
	local dir=$1
	local target="$HOME/.config/$dir"
	check_program "openrgb" || return 1
	if [ -n "$flatpak" ] && ! ("$flatpak" list | grep -q org.openrgb.OpenRGB); then
		echo "Error: flatpak detected, but 'org.openrgb.OpenRGB' not found!"
		return 1
	fi
	if ! confirm "Are you sure you want to stow $dir?"; then
		return 1
	fi
	remove_this "$target"
	stow_this "$dir"
	return 2
}

handle_scripts() {
	local dir=$1
	local target="$HOME/.local/bin/scripts"
	if ! confirm "Are you sure you want to stow $dir?"; then
		return 1
	fi
	remove_this "$target"
	mkdir -p "$(dirname "$target")"
	chmod +x "$ROOT/$dir"/*.*
	ln -sf "$(realpath "$ROOT/$dir")" "$target"
	echo "Linking 'fish.sh' in /usr/local/bin for compatibility..."
	local fish="/usr/local/bin/fish.sh"
	remove_this "$fish" "sudo" # use sudo mode here
	sudo ln -sf "$target/fish.sh" "$fish"
	return 2
}

handle_pipewire() {
	local dir=$1 target=$2
	if ! is_linux || ! confirm "Are you sure you want to stow $dir?"; then
		echo "Skipping $dir stow on $OS..."
		return 1
	fi
	local conf_root=".config/pipewire"
	local conf_path="$conf_root/pipewire.conf.d/virtual-spatializer-7.1.conf"
	local local_root="$ROOT/$dir"
	local sofa_path
	sofa_path="$(realpath "$local_root")/$conf_root/kemar.sofa"

	mkdir -p "$(dirname "$ROOT/$dir/$conf_path")"
	cp -f "$local_root/$conf_root/spatializer-template.conf" "$local_root/$conf_path"
	sed -i "s|%PATH%|$sofa_path|g" "$local_root/$conf_path"
	stow_this "$dir" && return 2 || return 1
}

handle_spicetify() {
	local dir="$1"
	local target="$2"
	local bypass="${3:-1}"

	if [ "$OS" == "Darwin" ] ||
		[ "$bypass" -ne 0 ] && ! confirm "Are you sure you want to stow $dir?"; then
		return 1
	fi

	# main install path
	if check_program "spicetify"; then
		echo "Double-check your 'prefs' path at: $target/config-xpui.ini"
		stow_this "$dir"
		return 2 # signal to bypass additional stow steps
	elif confirm "Download and install 'spicetify'?"; then
		# try using brew if available, otherwise pull remotely and rerun the stow
		if check_program "brew" && brew install spicetify ||
			curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh; then
			handle_spicetify "$dir" "$target" 0
		else
			echo "Error: something went wrong, aborting!"
			return 1
		fi
	else
		return 1
	fi

}

handle_tmux() {
	local dir=$1
	local target="$2"
	if ! check_program "tmux" || ! check_program "git"; then
		echo "Error: 'tmux' and 'git' are required, skipping..."
		return 1
	fi
	if ! confirm "Are you sure you want to stow $dir?"; then
		return 1
	fi
	local tpm_root=".config/tmux/plugins"
	echo "Wiping old '$dir' config..."
	remove_this "$HOME/.config/$dir"
	cp -f "$HOME/.tmux.conf" "$HOME/.tmux.conf.stowed"
	remove_this "$HOME/.tmux.conf"
	ln -sf "$(realpath "$ROOT")/tmux/.config/tmux/tmux.conf" "$HOME/.tmux.conf"
	echo "Linked 'tmux.conf' to '$HOME/.tmux.conf'..."
	if [ ! -d "$ROOT/$dir/$tpm_root/tpm" ]; then
		echo "Fetching 'tpm'..."
		git clone https://github.com/tmux-plugins/tpm "$ROOT/$dir/$tpm_root/tpm"
	fi
	stow_this "$dir"
	return 2
}

do_pre_stow() {
	local dir=$1 target=$2
	case "$dir" in
	hypr) check_program "hyprland" || return 1 ;;
	MangoHud) check_program "mangohud" || return 1 ;;
	topgrade.d) check_program "topgrade" || return 1 ;;
	home) handle_home || return $? ;;
	pipewire) handle_pipewire "$dir" "$target" || return $? ;;
	scripts) handle_scripts "$dir" || return $? ;;
	systemd)
		if ! is_linux; then
			echo "Skipping $dir stow on $OS..."
			return 1
		fi
		;;
	nix) return 1 ;;
	OpenRGB) handle_openrgb "$dir" || return $? ;;
	spicetify) handle_spicetify "$dir" "$target" || return $? ;;
	tmux) handle_tmux "$dir" "$target" || return $? ;;
	*) check_program "$dir" || return 1 ;;
	esac
}

do_post_stow() {
	local dir=$1 target=$2
	case "$dir" in
	home)
		if [ "$OS" == "NixOS" ]; then
			remove_this "$HOME/.profile"
			echo "Detected NixOS; removed ~/.profile to avoid env clobbering."
		elif check_program "uwsm" "Error: 'uwsm' not found, skipping!"; then
			remove_this "$HOME/.config/uwsm"
			mkdir -p "$HOME/.config/uwsm"
			ln -sf "$HOME/.profile" "$HOME/.config/uwsm/env"
			echo "Detected 'uwsm'; linked ~/.profile to ~/.config/uwsm/env."
			remove_this "$HOME/.config/trguing.json"
			ln -sf "$(realpath "$ROOT/$dir/.config/trguing.json")" "$(realpath "$HOME/.config/trguing.json")"
			echo "Linked to realpath of 'trguing.json'."
		fi
		local MONITOR_SCRIPTS="$HOME/.local/bin/monitor-session"
		local SCRIPTS_DIR="$HOME/.local/bin/scripts"
		rm -rf "$MONITOR_SCRIPTS"
		mkdir -p "$MONITOR_SCRIPTS"
		ln -sf "$(realpath "$SCRIPTS_DIR")/fix-gsync.py" "$MONITOR_SCRIPTS/fix-gsync.py"
		ln -sf "$(realpath "$SCRIPTS_DIR")/openrgb-load.sh" "$MONITOR_SCRIPTS/openrgb-load.sh"
		rm -f "$HOME"/.dotfiles && ln -sf "$(realpath "$script_dir")" "$(realpath "$HOME")"/.dotfiles
		echo "Linked monitor-session scripts to '$MONITOR_SCRIPTS'."
		;;
	fish)
		[[ "$SHELL" == *fish* ]] && fish -c "source $HOME/.config/fish/config.fish && update_fisher"
		;;
	bat)
		bat cache --build
		;;
	scripts)
		local bin_dir
		bin_dir="$(realpath "$HOME")/.local/bin"

		if [ -r "$HOME/.config/systemd/user/on-session-state.service" ]; then
			mkdir -p "$bin_dir/monitor-session/"
			remove_this "$bin_dir/monitor-session/*.*"
			ln -sf "$bin_dir/scripts/fix-gsync.py" "$bin_dir/monitor-session/fix-gsync.py" &&
				ln -sf "$bin_dir/scripts/openrgb-load.sh" "$bin_dir/monitor-session/openrgb-load.sh"
			echo "Linked common scripts for use with 'on-session-state' systemd service..."
		fi
		;;
	esac
}

do_stow() {
	local dir=$1 target=$2
	if ! confirm "Removing all files from $target before stowing '$dir'?"; then
		return 1
	fi
	remove_this "$target"
	mkdir -p "$target"
	stow_this "$dir"
}

handle_stow() {
	local dir=$1
	local target="$HOME/.config/$dir"
	do_pre_stow "$dir" "$target" || return 1
	do_stow "$dir" "$target" || return 1
	do_post_stow "$dir" "$target"
}

main() {
	check_program "tuckr" "Error: cannot find 'tuckr'!" || exit 1
	fix_perms
	# Get subdirectories under Configs and sort them
	mapfile -t directories < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d | sed 's|^./Configs/||' | sort)
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
		exit 0
		;;
	--fetch-nix)
		fetch_nix
		exit 0
		;;
	-h | --help)
		show_help
		;;
	*)
		shift
		;;
	esac
done

main
