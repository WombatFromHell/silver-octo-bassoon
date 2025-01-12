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

  read -r -p "$1 (Y/n) " response
  case "$response" in
  [nN])
    echo "Action aborted..."
    return 1
    ;;
  [yY] | "")
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
  if [ "$dir" == "home" ]; then
    files=(
      ".bashrc"
      ".wezterm.lua"
      ".config/chromium-flags.conf"
      ".config/trguing.json"
    )
    for file in "${files[@]}"; do
      cp -f "$HOME/$file" "$HOME/${file}.stowed"
      rm -f "$HOME/$file"
    done

    stow home
    echo "" && echo "$HOME has been stowed!"
  elif [ "$dir" == "scripts" ]; then
    target="$HOME/.local/bin/$dir"
    rm -f "$target"
    chmod +x "./$dir"/*.sh
    ln -sf "$script_dir/$dir" "$target"
  elif [ "$dir" == "pipewire" ]; then
    hesuvi_tgt="$HOME/.config/pipewire/atmos.wav"
    sed -i "s|%PATH%|$hesuvi_tgt|g" "$dir/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
    stow pipewire
  else
    TARGET="$HOME/.config/$dir"
    if confirm "Removing all files from $TARGET before stowing"; then
      rm -rf "${TARGET:?}"/*
      mkdir -p "$TARGET"/
      stow "$dir"

      echo "" && echo "$TARGET has been stowed!"
      if [ "$dir" == "fish" ]; then
        fish -c "fisher update"
      fi
    fi
  fi
done
