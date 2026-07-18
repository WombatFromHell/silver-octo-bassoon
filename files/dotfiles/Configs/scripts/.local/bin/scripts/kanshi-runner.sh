#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "tv" ]; then
  notify-send 'Kanshi' 'Switched to tv profile - gamemode enabled!'
  # switch-audio-out.sh output_a
  # gamemode on
  exec env SWITCH_OUTPUT="alsa_output.pci-0000_03_00.1.hdmi-stereo-extra3" bazzified-steam.sh tenfoot
else
  # switch-audio-out.sh output_b
  # gamemode off
  exec env SWITCH_OUTPUT="alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game" bazzified-steam.sh -- -silent
fi
