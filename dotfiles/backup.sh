#!/usr/bin/env bash

RSYNC=("$(command -v rsync)" "-azL" "--partial" "--update")
script_dir="$(dirname "$(readlink -f "$0")")"

if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the same directory as the stowed data!"
  exit 1
fi

backup_home() {
  local src="$HOME"
  local tgt="./home"
  local files=(
    ".bashrc"
    ".zshrc"
    ".wezterm.lua"
    ".config/chromium-flags.conf"
    ".config/trguing.json"
  )

  for file in "${files[@]}"; do
    local dir_path
    dir_path="$(dirname "$tgt/$file")"
    mkdir -p "$dir_path"
    "${RSYNC[@]}" "$src/$file" "$tgt/$file"
  done
}

backup_pipewire() {
  local src="$HOME/.config/pipewire"
  local tgt="./$1/.config/$1"
  mkdir -p "$tgt"

  "${RSYNC[@]}" "$src"/* "$tgt"/
  sed -i "s|$HOME/.config/pipewire/atmos.wav|%PATH%|g" \
    "$tgt/filter-chain.conf.d/sink-virtual-surround-7.1-hesuvi.conf"
}

backup_systemd() {
  local src="$HOME/.config/systemd"
  local tgt="./$1/.config/$1"
  mkdir -p "$tgt"

  "${RSYNC[@]}" --exclude=*/ --exclude="on-session-state.service" "$src"/* "$tgt"/
}

backup_directory() {
  local dir="$1"
  local src="$HOME/.config/$dir"
  local tgt="./$dir"

  case "$dir" in
  "home")
    backup_home
    src="$HOME"
    ;;
  "scripts")
    src="$HOME/.local/bin/$dir"
    mkdir -p "$tgt"
    "${RSYNC[@]}" --delete "$src"/* "$tgt"/
    ;;
  "nix")
    src="$HOME/.nix-flakes"
    "${RSYNC[@]}" "$src" "$tgt"/
    ;;
  "fish")
    tgt="./$dir/.config/$dir"
    mkdir -p "$tgt"
    "${RSYNC[@]}" "$src"/config.fish "$src"/fish_plugins "$tgt"/
    ;;
  "pipewire")
    backup_pipewire "$dir"
    src="$HOME/.config/$dir"
    ;;
  "systemd")
    backup_systemd "$dir"
    src="$HOME/.config/$dir"
    ;;
  *)
    src="$HOME/.config/$dir"
    tgt="./$dir/.config/$dir"
    mkdir -p "$tgt"
    "${RSYNC[@]}" "$src"/* "$tgt"/
    ;;
  esac

  echo -e "\nBacked up $src to $tgt"
}

# Main execution
mapfile -t directories <sources.txt
for dir in "${directories[@]}"; do
  backup_directory "$dir"
done
