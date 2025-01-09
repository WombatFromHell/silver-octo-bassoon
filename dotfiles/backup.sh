#!/usr/bin/env bash

RSYNC=$(command -v rsync)
CP=("$RSYNC -azL --update")

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
    ${CP[*]} "$DIR"/.bashrc "$DIR"/.wezterm.lua "${dir}"/
    echo "" && echo "$HOME has been backed up!"
  elif [ "$dir" == "fish" ]; then
    TARGET="./$dir/.config/$dir"
    mkdir -p "$TARGET"
    # copy files necessary to construct working fish config
    ${CP[*]} "$DIR"/config.fish "$DIR"/fish_plugins "${TARGET}"/
    echo "" && echo "Backed up $DIR to $TARGET"
  else
    TARGET="./$dir/.config/$dir"
    mkdir -p "$TARGET"
    ${CP[*]} "$DIR"/* "${TARGET}"/
    echo "" && echo "Backed up $DIR to $TARGET"
  fi
done
