#!/usr/bin/env bash

if pgrep -x "gBar" >/dev/null; then
	pkill -f gBar
fi

uwsm app -- gBar bar 0 &
