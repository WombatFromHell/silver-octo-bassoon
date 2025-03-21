shopt -s nullglob
export SUPPORT="./support"
export CP="sudo rsync -vhP --chown=$USER:$USER --chmod=D755,F644"
export PACMAN=(sudo pacman -Sy --needed --noconfirm)

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
	read -r -p "$1 (y/N) " response
	case "$response" in
	[yY])
		return 0
		;;
	*)
		echo "Action aborted!"
		return 1
		;;
	esac
}

run_if_confirmed() {
	local prompt="$1"
	local func="$2"

	if confirm "$prompt"; then
		$func
	fi
}

check_cmd() {
	local cmd
	cmd="$(command -v "$1")"
	if [ -n "$cmd" ]; then
		echo "$cmd"
	else
		return 1
	fi
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
