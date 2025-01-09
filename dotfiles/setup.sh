#!/usr/bin/env bash

confirm_action() {
  read -p "Proceed with action (y/n)? " -r -n 1 answer
  if [[ $answer =~ ^[Yy]$ ]]; then
    return 0 # Success
  else
    echo "Action aborted!"
    return 1 # Failure
  fi
}

# sanity check by making sure we run from the same dir as the script
script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the same directory as the stowed data!"
  exit 1
fi

mapfile -t directories <sources.txt

for dir in "${directories[@]}"; do
  if [ "$dir" == "home" ]; then
    cp ~/.bashrc ~/.bashrc.stowed
    rm -f ~/.bashrc

    cp ~/.wezterm.lua ~/.wezterm.lua.stowed
    rm -f ~/.wezterm.lua

    stow home
    echo "" && echo "$HOME has been stowed!"
  else
    echo "Removing all files from $HOME/.config/$dir..."
    if confirm_action; then
      rm -rf "$HOME/.config/$dir/*"
      mkdir -p "$HOME/.config/$dir/"
      stow "$dir"
      echo "" && echo "$HOME/.config/$dir has been stowed!"
      if [ "$dir" == "fish" ]; then
        fish -c "fisher update"
      fi
    else
      exit 1
    fi
  fi
done
