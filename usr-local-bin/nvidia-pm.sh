#!/bin/bash
NVIDIASET="$(command -v nvidia-settings)"
NVIDIASMI="$(command -v nvidia-smi)"

underclock() {
	"$NVIDIASET" -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=115"
	"$NVIDIASET" -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=300"
	"$NVIDIASMI" -pl "$1"
	"$NVIDIASMI" -gtt 80
	"$NVIDIASMI" -lgc 210,1800
}
undo() {
	"$NVIDIASET" -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=0"
	"$NVIDIASET" -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=0"
	"$NVIDIASMI" -pl 370
	"$NVIDIASMI" -gtt 91
	"$NVIDIASMI" -rgc
	"$NVIDIASMI" -rmc
}

"$NVIDIASMI" -pm 1
[ "$1" != "undo" ] && undo

if [ "$1" == "high" ]; then
	underclock 370
elif [ "$1" == "med" ]; then
	underclock 296 # 80%
elif [ "$1" == "low" ]; then
	underclock 267 # 72%
elif [ "$1" == "vlow" ]; then
	underclock 222 # 60%
elif [ "$1" == "undo" ]; then
	undo
fi
