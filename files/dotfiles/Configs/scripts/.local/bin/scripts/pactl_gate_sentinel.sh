#!/usr/bin/env bash
# ponytail: trap EXIT covers normal return + signals bash catches (INT/TERM);
# a SIGKILL on this wrapper leaks the sink — acceptable for a dev sentinel,
# but if that matters, add a systemd unit with ExecStopPost instead.

sink_name=gate_sentinel
lock=/tmp/pactl_gate_sentinel.pid

sink_load()   { pactl load-module module-null-sink sink_name="$sink_name" sink_properties=application.process.binary="$sink_name"; }
sink_unload() { [ -n "$1" ] && pactl unload-module "$1"; }
sink_reload() { sink_unload "$sink_id"; sink_id=$(sink_load); }

if [ "$1" = --reload ]; then
  read -r pid < "$lock" 2>/dev/null || { echo "gate sentinel not running"; exit 1; }
  kill -HUP "$pid" && echo "sentinel reloaded"
  exit
fi

sink_id=$(sink_load)
trap 'rm -f "$lock"; sink_unload "$sink_id"' EXIT
trap sink_reload HUP
printf '%s\n' "$$" > "$lock"
"$@"
