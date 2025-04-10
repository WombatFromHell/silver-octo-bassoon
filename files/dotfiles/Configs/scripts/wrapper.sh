#!/usr/bin/env bash

BPFLAND="$(which scx_bpfland)"
if [ -n "$BPFLAND" ]; then
	"$BPFLAND" &
fi

export PULSE_LATENCY_MSEC=60

"$@"

pkill -f "scx_bpfland"
