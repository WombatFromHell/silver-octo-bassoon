#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script: open-term-here.sh
# Purpose: Opens specific terminals (Kitty/Ghostty/Alacritty) in a target dir,
#          managing Tmux sessions and windows intelligently.
# -----------------------------------------------------------------------------

TERMINAL="$1"
TARGET_DIR="$2"
SESSION_NAME="main"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

validate_input() {
  if [[ -z "$TARGET_DIR" ]] || [[ ! -d "$TARGET_DIR" ]]; then
    notify-send "Error" "Invalid directory: $TARGET_DIR"
    exit 1
  fi
  if [[ -z "$TERMINAL" ]]; then
    notify-send "Error" "Terminal not specified"
    exit 1
  fi
}

# Check if the specific terminal binary is currently running
# We use -x (exact match) to avoid matching this script's own arguments
is_terminal_process_running() {
  pgrep -x "$(basename "$TERMINAL")" > /dev/null 2>&1
}

# Check if our specific tmux session exists
is_tmux_session_running() {
  tmux has-session -t "$SESSION_NAME" > /dev/null 2>&1
}

# Create a new tmux window (tab) inside the existing session
create_tmux_window() {
  # Create window in background
  tmux new-window -t "$SESSION_NAME" -c "$TARGET_DIR"
}

# Launch the terminal emulator
launch_terminal() {
  cd "$TARGET_DIR" || exit 1

  local term_name
  term_name=$(basename "$TERMINAL")

  # We launch the terminal and tell it to attach to the session.
  # Since we just created the window in 'create_tmux_window' (if running),
  # or are about to create the session (if not), this brings it to view.
  case "$term_name" in
    kitty)
      # Kitty: No flags. Pass args distinctively.
      nohup "$TERMINAL" tmux new-session -A -s "$SESSION_NAME" >/dev/null 2>&1 &
      ;;
    ghostty|alacritty)
      # Ghostty/Alacritty: Use -e.
      nohup "$TERMINAL" -e tmux new-session -A -s "$SESSION_NAME" >/dev/null 2>&1 &
      ;;
    *)
      # Fallback
      nohup "$TERMINAL" -e tmux new-session -A -s "$SESSION_NAME" >/dev/null 2>&1 &
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

validate_input

if is_tmux_session_running; then
  # 1. Tmux IS running.
  # Create the new window (tab) in the existing session first.
  create_tmux_window

  # 2. Check if the GUI is actually open.
  # If not (e.g., you closed the window but left tmux server running), open it.
  if ! is_terminal_process_running; then
    launch_terminal
  fi

else
  # 3. Tmux IS NOT running.
  # Launching the terminal with 'new-session -A' will create the session
  # and default to the directory we cd'd into.
  launch_terminal
fi
