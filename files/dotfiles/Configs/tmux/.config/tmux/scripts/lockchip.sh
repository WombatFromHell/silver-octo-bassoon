#!/usr/bin/env bash
# lockchip.sh — tmux `#()` helper: emit a styled lock glyph before the session
# chip when the leader is locked (prefix None), else emit nothing.
#
# tmux spawns it as a background job on every status draw and inserts the
# last output line into status-left verbatim. Output is a single line:
#   locked:  " #[fg=<@c_base>]<glyph> "  (leading space + glyph + trailing space)
#   unlocked: ""  (empty)
# The script owns all spacing around the glyph: the status-left format
# carries no literal space after #(), so when unlocked the session chip is
# byte-identical to the no-lock state (no visible space).
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# _is_locked -> success (0) if the leader is currently locked (prefix None).
_is_locked() {
  [[ $(tmux show-options -gv prefix 2>/dev/null) == None ]]
}

# _lock_color -> the palette colour for the lock glyph (@c_lock: a dark red
# that contrasts with the chip's teal bg), with a fallback for environments
# without the conf (tests / unconf servers).
_lock_color() {
  local c
  c=$(tmux show-options -gv @c_lock 2>/dev/null)
  printf '%s' "${c:-#d20f39}"
}

if _is_locked; then
  printf ' #[fg=%s]\uea75 ' "$(_lock_color)"
fi
