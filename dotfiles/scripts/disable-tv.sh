#!/bin/sh
xrandr --output HDMI-0 --off
xrandr --output DP-4 --rate 144 --mode 2560x1440 --primary --dpi 96
$@
