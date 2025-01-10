#!/usr/bin/env bash

BASE_ROOT="$HOME/.steam/steam/compatibilitytools.d"
ROOT="${1:-$BASE_ROOT/GE-Proton9-16-GPLASYNC-LFX}"
# only Proton is supported!
BASE_PATH="$ROOT/files/lib64/wine"
LINPATH="$BASE_PATH/x86_64-unix"
WINBPATH="$BASE_PATH/x86_64-windows"

TARGET_PATH="$(pwd)/drive_c/windows/system32"

if ! [ -r "$TARGET_PATH" ]; then
  echo "Error: cannot find system32 dir, please run this script from the base of the prefix!"
  exit 1
else
  cd "$TARGET_PATH" || exit 1
fi

LINLFX_LAYER="$LINPATH/latencyflex_layer.so"
WINLFX_LAYER="$WINBPATH/latencyflex_layer.dll"
WINLFX_WINE="$WINBPATH/latencyflex_wine.dll"

if ! [ -r "$LINLFX_LAYER" ] || ! [ -r "$WINLFX_LAYER" ] || ! [ -r "$WINLFX_WINE" ]; then
  echo "Error: a valid LatencyFleX install could not be found at: $ROOT!"
  exit 1
else
  ln -sf "$LINLFX_LAYER" .
  ln -sf "$WINLFX_LAYER" .
  ln -sf "$WINLFX_WINE" .
fi
