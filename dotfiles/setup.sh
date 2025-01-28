#!/usr/bin/env bash

OS=$(uname -a)
AUTO_CONFIRM=false
# Ensure script runs from its directory
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$script_dir" || exit 1

show_help() {
  echo "Usage: $(basename "$0") [-y|--confirm] [--fix-perms] [-h|--help]"
  echo "Options:"
  echo "  -y, --confirm     Skip confirmation prompts"
  echo "  --fix-perms       Normalize this repo's file permissions"
  echo "  -h, --help        Show this help message"
  exit 0
}
fix_perms() {
  find . -type d -exec chmod 0755 {} \;
  find . -type f -exec chmod 0644 {} \;
  find . \
    \( -type f -name "*.tmux" \
    -o -type f -name "*.sh" \
    -o -type f -name "tpm" \
    -o -type f -path "scripts/*.py" \) \
    -exec chmod 0755 {} \;
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
    stow "$dir"

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
  fi
}

handle_pipewire() {
  local dir=$1
  local target=$2

  local os
  os=$(check_for_os)

  if [[ "$os" == "Linux" || "$os" == "NixOS" ]] && confirm "Are you sure you want to stow $dir?"; then
    local tgt=".config/pipewire"
    local hesuvi_tgt="$HOME/$tgt/atmos.wav"
    sed -i \
      "s|%PATH%|$hesuvi_tgt|g" \
      "./$dir/$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
    stow "$dir"
  else
    echo -e "\nSkipping $dir stow on $os..."
  fi
}

handle_nix() {
  local dir=$1
  local target=$2

  local os
  os=$(check_for_os)

  local root="/etc/nixos"
  local conf="hardware-configuration.nix"

  if
    [ "$os" == "NixOS" ] &&
      confirm "Are you sure you want to setup the nix flake at: $dir?"
  then
    if [ -r "$root/$conf" ]; then
      cp -f "$root/$conf" ./"$dir"/nixos/"$conf"
    else
      echo "Error: unable to read $root/$conf!"
      return 1
    fi
    echo -e "\nPerform a 'sudo nixos-rebuild switch --flake $script_dir/nix#methyl'"
  else
    echo -e "\nSkipping nix flake setup on $os..."
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

  nix)
    handle_nix "$dir" "$target"
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
      stow "$dir"
      echo -e "\n'$dir' has been stowed!"

      #
      # Post-stow actions
      #
      case "$dir" in
      fish) fish -c "fisher update" ;;
      bat) bat cache --build ;;
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
  -h | --help)
    show_help
    ;;
  esac
done

main
