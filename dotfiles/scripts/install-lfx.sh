#!/usr/bin/env bash

help() {
  echo "$0 <latencyflex path> <proton install path | proton subdirname>"
  echo "Warning: this is only compatible with Proton/GE-Proton!"
  echo
  exit 1
}

SUB_PATH="$2/files/lib64/wine"
LFX_INST_BASE="$1/wine/usr/lib/wine"

LIN_SUBPATH="x86_64-unix"
WIN_SUBPATH="x86_64-windows"
LIN_PATH="$SUB_PATH/$LIN_SUBPATH"
WIN_PATH="$SUB_PATH/$WIN_SUBPATH"

if [ -z "$1" ] || [ -z "$2" ] || ! [ -r "$LFX_INST_BASE/$LIN_SUBPATH/latencyflex_layer.so" ] || ! [ -r "$2" ]; then
  help
else
  cp -f "$LFX_INST_BASE/$LIN_SUBPATH/latencyflex_layer.so" "$LIN_PATH/latencyflex_layer.so"
  cp -f "$LFX_INST_BASE/$WIN_SUBPATH/latencyflex_layer.dll" "$WIN_PATH/latencyflex_layer.dll"
  cp -f "$LFX_INST_BASE/$WIN_SUBPATH/latencyflex_wine.dll" "$WIN_PATH/latencyflex_wine.dll"
fi
