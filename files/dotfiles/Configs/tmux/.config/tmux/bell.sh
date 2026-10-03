#!/bin/sh
# bell.sh — handle a tmux bell notification.
# Args: win sess active focused attached
#
# One dot per tab per period: @bell is a boolean. A bell sets it to 1;
# acknowledging (selecting the window, or the terminal regaining focus)
# clears it. Repeated bells within the same period can't re-arm it because
# it is already 1.
win=$1 sess=$2 active=$3 focused=$4 attached=$5

# Already looking at it? Do nothing.
[ "$active" = 1 ] && [ "$focused" = 1 ] && [ "$attached" != 0 ] && exit 0

# Sound (Linux, then macOS)
if command -v paplay >/dev/null 2>&1; then
  paplay /usr/share/sounds/freedesktop/stereo/complete.oga &
elif command -v afplay >/dev/null 2>&1; then
  afplay /System/Library/Sounds/Glass.aiff &
fi

# floax isn't in the tab list, so it gets a global flag shown in status-right
if [ "$sess" = floax ]; then
  tmux set -g @floax_bell 1
else
  tmux set -w -t "$win" @bell 1
fi
tmux refresh-client -S
