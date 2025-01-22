#!/usr/bin/env bash

OS=$(uname)
AUTO_CONFIRM=false
# Ensure script runs from its directory
script_dir="$(dirname "$(readlink -f "$0")")"
cd "$script_dir" || exit 1

show_help() {
  echo "Usage: $(basename "$0") [-y|--confirm] [-h|--help]"
  echo "Options:"
  echo "  -y, --confirm     Skip confirmation prompts"
  echo "  -h, --help    Show this help message"
  exit 0
}
[[ "$1" == "-h" || "$1" == "--help" ]] && show_help
[[ "$1" == "-y" || "$1" == "--confirm" ]] && AUTO_CONFIRM=true

fix_perms() {
  find . -type d -exec chmod 0755 {} \;
  find . -type f -exec chmod 0644 {} \;
  find . \
    \( -type f -name "*.tmux" \
    -o -type f -name "*.sh" \
    -o -type f -name "tpm" \
    -o type f -path "scripts/*.py" \) \
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
    chmod +x "./$1"/*.sh
    # just link, don't stow
    ln -sf "$script_dir/$1" "$target"
  fi
}

handle_pipewire() {
  local dir=$1
  local target=$2

  if check_for_linux && confirm "Are you sure you want to stow $dir?"; then
    local tgt=".config/pipewire"
    local hesuvi_tgt="$HOME/$tgt/atmos.wav"
    sed -i \
      "s|%PATH%|$hesuvi_tgt|g" \
      "./$dir/$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
    stow "$dir"
  else
    echo -e "\nSkipping $dir stow on $OS..."
  fi
}

handle_stow() {
  local dir=$1
  local target="$HOME/.config/$dir"

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
    target="$HOME/.nix-flakes"
    if confirm "Are you sure you want to stow $dir?"; then
      remove_this "$target"
      stow "$dir"
    fi
    ;;

  *)
    #
    # Pre-stow actions
    #
    case "$dir" in
    systemd)
      # exclude systemd on non-Linux OS'
      if ! check_for_linux; then
        echo -e "\nSkipping $dir stow on $OS..."
        return
      fi
      ;;

    tmux)
      # try to workaround tmux.fish "tmuxconf" issue
      cp -f "$HOME"/.tmux.conf "$HOME"/.tmux.conf.stowed &&
        remove_this "$HOME"/.tmux.conf &&
        ln -sf "$HOME"/.config/tmux/tmux.conf "$HOME"/.tmux.conf
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
  mapfile -t directories <sources.txt
  for dir in "${directories[@]}"; do
    handle_stow "$dir"
  done
}

main
