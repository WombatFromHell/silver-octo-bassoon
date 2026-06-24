#!/usr/bin/env bash
flatpak override --user --reset org.openrgb.OpenRGB
flatpak override --user \
  --filesystem="$HOME"/.dotfiles/Configs \
  --filesystem="$HOME"/.ansible-root/files/dotfiles/Configs \
  org.openrgb.OpenRGB
