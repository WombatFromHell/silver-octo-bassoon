#!/usr/bin/env bash

set -euxo pipefail
# Check if flags configuration file exists
if [[ -f "$HOME/.config/chromium-flags.conf" ]]; then
  FLAGS_CONF=${FLAGS:-"$HOME/.config/chromium-flags.conf"}
fi
# Check if flags config file exists
if [ ! -f "$FLAGS_CONF" ]; then
  echo "Error: Flags configuration file '$FLAGS_CONF' not found"
  exit 1
fi

# Read flags from configuration file using mapfile
# Use an array to store filtered flags
FLAGS=()
#mapfile -t lines <"$FLAGS_CONF"
mapfile -t lines < <(grep -Ev '^\s*#|^\s*$' "$FLAGS_CONF")

# Filter out empty lines and comments
for line in "${lines[@]}"; do
  # Trim leading and trailing whitespace
  trimmed=$(echo "$line" | xargs)

  # Skip empty lines and comments
  if [[ -n "$trimmed" && ! "$trimmed" =~ ^# ]]; then
    FLAGS+=("$trimmed")
  fi
done

# Execute the command with flags
"$1" ${FLAGS[*]} ${*:2}
