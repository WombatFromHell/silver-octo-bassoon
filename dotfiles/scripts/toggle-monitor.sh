#!/usr/bin/env bash

set -euxo pipefail

DELAY="1"

FIRST="DP-4"
FIRST_MODE="2560x1440"
FIRST_HZ="144.000"
FIRST_HZ_J="120.000"

SECOND="HDMI-0"
SECOND_MODE="3840x2160"
SECOND_HZ="119.880"
SECOND_HZ_J="$SECOND_HZ"

get_primary() {
  PRIMARY=$(xrandr | awk '/^(.*) connected( primary)/ {print $1}')
  echo "$PRIMARY"
}

switch_monitor() {
  # arguments for toggle are: [switch-to] [switch-from]
  if [[ $DESKTOP_SESSION == *gnome* ]]; then
    xrandr --output "$1" --mode "$2" --rate "$3" --primary
    sleep "$DELAY"
    gnome-randr modify -m "$2@$3" --primary "$1"
    xrandr --output "$4" --off
  else
    xrandr --output "$1" --mode "$2" --rate "$3" --primary --output "$4" --off
  fi
}
join_monitors() {
  # arguments for toggle are: [switch-to] [switch-from]
  if [[ $DESKTOP_SESSION == *gnome* ]]; then
    xrandr --output "$FIRST" --mode "$FIRST_MODE" --rate "$FIRST_HZ_J" --primary \
      --output "$SECOND" --mode "$SECOND_MODE" --rate "$SECOND_HZ_J" --right-of "$FIRST"
    sleep "$DELAY"
    gnome-randr modify -m "$FIRST_MODE@$FIRST_HZ_J" --primary "$FIRST"
    gnome-randr modify -m "$SECOND_MODE@$SECOND_HZ_J" "$SECOND"
  else
    xrandr --output "$FIRST" --mode "$FIRST_MODE" --rate "$FIRST_HZ" --primary \
      --output "$SECOND" --mode "$SECOND_MODE" --rate "$SECOND_HZ" --right-of "$FIRST"
  fi
}

main() {
  SELECTED=$(get_primary)
  if [ "$SELECTED" == "$FIRST" ]; then
    switch_monitor "$SECOND" "$SECOND_MODE" "$SECOND_HZ" "$FIRST"
  elif [ "$SELECTED" == "$SECOND" ]; then
    switch_monitor "$FIRST" "$FIRST_MODE" "$FIRST_HZ" "$SECOND"
  else
    echo "An unknown monitor was found as the primary!"
    exit 1
  fi
}

if [ "$#" -gt 0 ] && [ "$1" == "join" ]; then
  join_monitors
  exit 0
elif [ "$#" -gt 0 ] && [ "$1" == "reset" ]; then
  xrandr --output "$FIRST" --mode "$FIRST_MODE" --rate "$FIRST_HZ" --primary \
    --output "$SECOND" --off
  exit 0
elif [ "$#" -gt 0 ]; then
  main
  "$@"
  main
else
  main
fi

exit 0
