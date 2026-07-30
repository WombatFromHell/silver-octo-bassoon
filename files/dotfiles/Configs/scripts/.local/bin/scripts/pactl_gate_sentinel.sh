#!/usr/bin/env bash
# ponytail: trap EXIT covers normal return + signals bash catches (INT/TERM);
# a SIGKILL on this wrapper leaks the sink — acceptable for a dev sentinel,
# but if that matters, add a systemd unit with ExecStopPost instead.
sink_id=$(pactl load-module module-null-sink sink_name=gate_sentinel \
  sink_properties=application.process.binary=gate_sentinel)
trap 'pactl unload-module "$sink_id"' EXIT
"$@"
