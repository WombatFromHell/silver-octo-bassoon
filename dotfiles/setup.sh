#!/usr/bin/env bash

OS=$(uname)
# Ensure script runs from its directory
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$script_dir" || exit 1

show_help() {
  echo "Usage: $(basename "$0") [-a|--all] [-h|--help]"
  echo "Options:"
  echo "  -a, --all     Skip confirmation prompts"
  echo "  -h, --help    Show this help message"
  exit 0
}
[[ "$1" == "-h" || "$1" == "--help" ]] && show_help
AUTO_CONFIRM=false
[[ "$1" == "-a" || "$1" == "--all" ]] && AUTO_CONFIRM=true

process_perms() {
  find . -type d -exec chmod 0755 {} \;
  find . -type f -exec chmod 0644 {} \;
  find . \
    \( -type f -name "*.tmux" -o -type f -name "*.sh" -o -type f -name "tpm" \) \
    -exec chmod 0755 {} \;
  echo -e "\nFixed repo permissions..."
}

confirm() {
  [[ "$AUTO_CONFIRM" == true ]] && return 0
  read -r -p "$1 (y/N) " response
  [[ "$response" == "y" || "$response" == "Y" ]]
}

check_for_linux() {
  if [ "$OS" != "Linux" ]; then
    return 1
  else
    return 0
  fi
}

unlink_dir() {
  if [[ -L "$1" ]]; then
    unlink "$1"
  else
    rm -rf "${1:?}"/*
  fi

}

handle_home() {
  local files=(".bashrc" ".zshrc" ".wezterm.lua")
  for file in "${files[@]}"; do
    cp -f "$HOME/$file" "$HOME/${file}.stowed"
    rm -f "$HOME/$file"
  done
  stow home
  echo -e "\n$HOME has been stowed!"
}

handle_scripts() {
  local target="$HOME/.local/bin/scripts"
  unlink_dir "$target"
  chmod +x "./$1"/*.sh
  ln -sf "$script_dir/$1" "$target"
}

handle_pipewire() {
  local tgt=".config/pipewire"
  local hesuvi_tgt="$HOME/$tgt/atmos.wav"
  sed -i "s|%PATH%|$hesuvi_tgt|g" "./$1/$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
  stow pipewire
}

handle_nix() {
  local target="$HOME/.nix-flakes"
  unlink_dir "$target"
  stow nix
}

handle_stow() {
  local dir=$1
  local target=$2

  # exclusions from normal stowing...
  if [ "$dir" == "systemd" ] && ! check_for_linux; then
    echo -e "\nSkipping $dir stow on $OS..."
    return
  fi

  if confirm "Removing all files from $target before stowing"; then
    unlink_dir "$target"
    mkdir -p "$target"/
    stow "$dir"
    echo -e "\n'$dir' has been stowed!"

    # Post-stow actions
    case "$dir" in
    fish) fish -c "fisher update" ;;
    bat) bat cache --build ;;
    esac
  fi
}

stow_directory() {
  local dir=$1
  local target="$HOME/.config/$dir"

  case "$dir" in
  home)
    confirm "Are you sure you want to stow $HOME?" && handle_home
    ;;
  scripts)
    confirm "Are you sure you want to stow $dir?" && handle_scripts "$dir"
    ;;
  pipewire)
    if check_for_linux; then
      confirm "Are you sure you want to stow $dir?" && handle_pipewire "$dir"
    else
      echo -e "\nSkipping $dir stow on $OS..."
    fi
    ;;
  nix)
    confirm "Are you sure you want to stow $dir?" && handle_nix
    ;;
  *)
    handle_stow "$dir" "$target"
    ;;
  esac
}

# fix repo perms before stowing (just in case)
process_perms
mapfile -t directories <sources.txt
for dir in "${directories[@]}"; do
  stow_directory "$dir"
done
