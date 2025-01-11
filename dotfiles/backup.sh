#!/usr/bin/env bash

RSYNC=$(command -v rsync)
CP=("$RSYNC -azL --partial --update")

# sanity check by making sure we run from the same dir as the script
script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the same directory as the stowed data!"
  exit 1
fi

mapfile -t directories <sources.txt

for dir in "${directories[@]}"; do
  DIR="$HOME/.config/$dir"
  if [ "$dir" == "home" ]; then
    DIR="$HOME"
    files=(
      ".bashrc"
      ".wezterm.lua"
      ".config/chromium-flags.conf"
      ".config/trguing.json"
    )
    for file in "${files[@]}"; do
      ${CP[*]} "$DIR/$file" "${dir}"/
    done
    echo "" && echo "$HOME has been backed up!"
  elif [ "$dir" == "scripts" ]; then
    DIR="$HOME/.local/bin/$dir"
    TARGET="./$dir"
    mkdir -p "$TARGET"
    ${CP[*]} --delete "$DIR"/* "$TARGET"/
    echo "" && echo "Backed up $DIR to $TARGET"
  else
    TARGET="./$dir/.config/$dir"
    mkdir -p "$TARGET"

    if [ "$dir" == "pipewire" ]; then
      hesuvi_tgt="$HOME/.config/pipewire/atmos.wav"
      ${CP[*]} "$DIR"/* "$TARGET"/
      sed -i "s|$hesuvi_tgt|%PATH%|g" "$TARGET"/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf
      echo "" && echo "Backed up generalized pipewire config to $TARGET"
    elif [ "$dir" == "systemd" ]; then
      mkdir -p "$TARGET"
      ${CP[*]} --exclude=*/ \
        --exclude="on-session-state.service" \
        "$DIR"/* "$TARGET"/
      echo "" && echo "Backed up $DIR to $TARGET"
    elif [ "$dir" == "fish" ]; then
      mkdir -p "$TARGET"
      # copy only files necessary to construct working fish config
      ${CP[*]} "$DIR"/config.fish "$DIR"/fish_plugins "$TARGET"/
      echo "" && echo "Backed up $DIR to $TARGET"
    else
      ${CP[*]} "$DIR"/* "$TARGET"/
      echo "" && echo "Backed up $DIR to $TARGET"
    fi
  fi
done
