#!/usr/bin/env bash
# force nvidia powermizer performance state
nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1"
# disable the compositor
qdbus org.kde.KWin /Compositor suspend
#pw-metadata -n settings 0 clock.force-quantum 50
# wait until the game exits
PULSE_LATENCY_MSEC=60
"$@"
# reenable the compositor
qdbus org.kde.KWin /Compositor resume
#pw-metadata -n settings 0 clock.force-quantum 0
nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=0"
