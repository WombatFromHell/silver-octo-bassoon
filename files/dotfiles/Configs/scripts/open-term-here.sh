#!/usr/bin/env bash

# Script: open-term-here.sh
# Opens terminal with tmux and creates a new tab in the specified directory

TARGET_DIR="$2"
TERMINAL="$1"

# Validate that a directory was provided
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  notify-send "Error" "No valid directory provided"
  exit 1
fi

# Function to create a new tmux window in the specified directory
create_tmux_window() {
  local dir
  dir="$1"
  # Send command to create new window and change to directory
  tmux new-window -c "$dir" 2>/dev/null || {
    # If tmux isn't running, this will fail - that's okay
    # We'll handle starting tmux in the target directory below
    return 1
  }
}

# Check if tmux is already running
if tmux list-sessions >/dev/null 2>&1; then
  # Tmux is running, create new window in the specified directory
  create_tmux_window "$TARGET_DIR"
else
  # No tmux session running, start the terminal which should start tmux
  # in the target directory. The terminal will be started with a command
  # to change to the target directory first
  (
    cd "$TARGET_DIR" || exit 1
    # Start the terminal, which should automatically start tmux in this directory
    "$TERMINAL" &
    # Give the terminal time to initialize
    sleep 1
    # Now create a new session in the target directory to ensure it's there
    tmux new-session -A -s 'main' -c "$TARGET_DIR" 2>/dev/null || true
  )
fi
