#!/usr/bin/env bash

# Ensure script runs from its directory
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$script_dir" || exit 1

# Help message
show_help() {
  echo "Usage: $(basename "$0") [-a|--all] [-h|--help]"
  echo "Options:"
  echo "  -a, --all     Skip confirmation prompts"
  echo "  -h, --help    Show this help message"
  exit 0
}

# Parse arguments
[[ "$1" == "-h" || "$1" == "--help" ]] && show_help
AUTO_CONFIRM=false
[[ "$1" == "-a" || "$1" == "--all" ]] && AUTO_CONFIRM=true

# Confirmation function
confirm() {
  [[ "$AUTO_CONFIRM" == true ]] && return 0
  read -r -p "$1 (y/N) " response
  [[ "$response" == "y" || "$response" == "Y" ]]
}

unlink_dir() {
  if [[ -L "$1" ]]; then
    unlink "$1"
  else
    rm -rf "${1:?}"/*
  fi

}

# Special directory handlers
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

handle_tmux() {
  echo "Attempting to correct tmux source permissions..."
  find "./$1"/ -type d -exec chmod 0755 {} \;
  find "./$1"/ -type f -exec chmod 0644 {} \;
  find "./$1"/ -type f -name "*.tmux" -exec chmod 0755 {} \;
  find "./$1"/ -type f -name "*.sh" -exec chmod 0755 {} \;
  find "./$1"/ -type f -name "tpm" -exec chmod 0755 {} \;
}

# Main stow function
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
    confirm "Are you sure you want to stow $dir?" && handle_pipewire "$dir"
    ;;
  nix)
    confirm "Are you sure you want to stow $dir?" && handle_nix
    ;;
  *)
    if confirm "Removing all files from $target before stowing"; then
      unlink_dir "$target"
      mkdir -p "$target"/
      stow "$dir"
      echo -e "\n'$dir' has been unstowed!"

      # Post-stow actions
      case "$dir" in
      fish) fish -c "fisher update" ;;
      bat) bat cache --build ;;
      tmux) handle_tmux "$dir" ;;
      esac
    fi
    ;;
  esac
}

# Main execution
mapfile -t directories <sources.txt
for dir in "${directories[@]}"; do
  stow_directory "$dir"
done
