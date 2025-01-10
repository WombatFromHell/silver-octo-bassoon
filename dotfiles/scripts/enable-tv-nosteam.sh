#!/bin/sh
killall -9 steam
xrandr --output DP-4 --off
xrandr --output HDMI-0 --rate 120 --mode 3840x2160 --primary --dpi 144
$@
