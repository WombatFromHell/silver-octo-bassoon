#!/bin/sh
# Run the full gate-route unit suite. Exits non-zero on any failure.
cd "$(dirname "$0")" || exit 1
exec luajit harness.lua *.spec.lua
