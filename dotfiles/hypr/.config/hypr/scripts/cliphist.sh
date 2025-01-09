#!/usr/bin/env bash

cliphist list | fuzzel --launch-prefix="uwsm app --" --dmenu | cliphist decode | wl-copy
