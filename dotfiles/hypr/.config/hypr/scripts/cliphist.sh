#!/usr/bin/env bash

if
  ! command -v uwsm &>/dev/null ||
    ! command -v cliphist &>/dev/null ||
    ! command -v fuzzel &>/dev/null ||
    ! command -v wl-copy &>/dev/null
then
  echo "Error: an executable dependency of this script has not been found!"
  echo "Please install the following packages: uwsm, cliphist, fuzzel, wl-copy"
  exit 1
fi

cliphist list | fuzzel --launch-prefix="uwsm app --" --dmenu | cliphist decode | wl-copy
