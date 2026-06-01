#!/usr/bin/env bash

REALHOME="$(realpath "$HOME")"
ARGS=(
  LSFGVK_DLL_PATH="$REALHOME/.local/share/Lossless.dll"
  LSFG_DLL_PATH="$REALHOME/.local/share/Lossless.dll"
  LSFGVK_PERFORMANCE_MODE=1
  LSFG_PERFORMANCE_MODE=1
)

env -u DISABLE_LSFGVK -u DISABLE_LSFG "${ARGS[@]}" "$@"
