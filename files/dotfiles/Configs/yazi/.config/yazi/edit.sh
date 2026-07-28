#!/bin/bash
if [ -n "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
  tmux new-window -t main -- "${EDITOR:-vi}" "$@"
elif [ -n "$ZELLIJ" ] && command -v zellij >/dev/null 2>&1; then
  zellij action new-tab --close-on-exit -- "${EDITOR:-vi}" "$@"
elif command -v hx >/dev/null 2>&1; then
  hx "$@"
else
  "${EDITOR:-vi}" "$@"
fi
