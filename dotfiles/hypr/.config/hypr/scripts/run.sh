#!/usr/bin/env bash
if command -v uwsm >/dev/null; then
  uwsm app -- "$@"
else
  echo "Error: uwsm not found!"
  exit 1
fi
