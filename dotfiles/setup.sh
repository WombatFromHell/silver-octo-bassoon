#!/usr/bin/env bash

# sanity check by making sure we run from the same dir as the script
script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the same directory as the stowed data!"
  exit 1
fi

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
  echo "Usage: $(basename "$0") [-a|--all] [-h|--help]"
  echo "Options:"
  echo "  -a, --all     Skip confirmation prompts"
  echo "  -h, --help    Show this help message"
  exit 0
fi
CONFIRM=""
if [ "$1" == "-a" ] || [ "$1" == "--all" ]; then
  CONFIRM="true"
fi

confirm() {
  if [ "$CONFIRM" == "true" ]; then
    return 0 # skip confirmation for ALL prompts
  fi

  read -r -p "$1 (y/N) " response
  case "$response" in
  [nN] | "")
    echo "Action aborted..."
    return 1
    ;;
  [yY])
    return 0
    ;;
  *)
    echo "Action aborted!"
    return 1
    ;;
  esac
}

mapfile -t directories <sources.txt

for dir in "${directories[@]}"; do
  TARGET="$HOME/.config/$dir"
  if [ "$dir" == "home" ]; then
    if confirm "Are you sure you want to stow $HOME?"; then
      files=(
        ".bashrc"
        ".zshrc"
        ".wezterm.lua"
      )
      for file in "${files[@]}"; do
        cp -f "$HOME/$file" "$HOME/${file}.stowed"
        rm -f "$HOME/$file"
      done

      stow home
      echo "" && echo "$HOME has been stowed!"
    fi
  elif [ "$dir" == "scripts" ]; then
    if confirm "Are you sure you want to stow $dir?"; then
      target="$HOME/.local/bin/$dir"
      rm -f "$target"
      chmod +x "./$dir"/*.sh
      ln -sf "$script_dir/$dir" "$target"
    fi
  elif [ "$dir" == "pipewire" ]; then
    if confirm "Are you sure you want to stow $dir?"; then
      hesuvi_tgt="$HOME/.config/pipewire/atmos.wav"
      sed -i "s|%PATH%|$hesuvi_tgt|g" "$dir/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
      stow pipewire
    fi
  elif [ "$dir" == "nix" ]; then
    TARGET="$HOME/.nix-flakes"
    if confirm "Are you sure you want to stow $dir?"; then
      rm -rf "${TARGET:?}"/*
      stow nix
    fi
  else
    if confirm "Removing all files from $TARGET before stowing"; then
      if [[ -L "$TARGET" ]]; then
        unlink "$TARGET"
      else
        # only recursively delete if it's a real directory
        rm -rf "${TARGET:?}"/*
      fi
      mkdir -p "$TARGET"/
      stow "$dir"

      echo "" && echo "$TARGET has been stowed!"
      if [ "$dir" == "fish" ]; then
        fish -c "fisher update"
        if [ "$dir" == "bat" ]; then
          bat cache --build
        fi
      elif [ "$dir" == "tmux" ]; then
        echo "Attempting to correct tmux source permissions..."
        find "./$dir"/ -type d -exec chmod 0755 {} \;
        find "./$dir"/ -type f -exec chmod 0644 {} \;
        find "./$dir"/ -type f -name "*.tmux" -exec chmod 0755 {} \;
        find "./$dir"/ -type f -name "*.sh" -exec chmod 0755 {} \;
        find "./$dir"/ -type f -name "tpm" -exec chmod 0755 {} \;
      fi
    fi
  fi
done
