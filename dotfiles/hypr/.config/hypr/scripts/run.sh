#!/usr/bin/env bash
UWSM=$(command -v uwsm)
if [ -n "$UWSM" ]; then
  "$UWSM" app -- "$@"
else
  echo "Error: uwsm not found!"
  exit 1
fi
