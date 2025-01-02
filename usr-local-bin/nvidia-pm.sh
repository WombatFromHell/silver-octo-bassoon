#!/bin/bash
NVIDIASMI="$(command -v nvidia-smi)"
BASE_PL="320"

do_math() {
	python -c "from decimal import Decimal, ROUND_HALF_UP; print(int((Decimal(\"$1\") * Decimal(\"$2\")).quantize(Decimal('1'), rounding=ROUND_HALF_UP)))"
}

underclock() {
	"$NVIDIASMI" -pl "$1"
}
undo() {
	"$NVIDIASMI" -pl "$BASE_PL"
	"$NVIDIASMI" -rgc
	"$NVIDIASMI" -rmc
}

"$NVIDIASMI" -pm 1
[ "$1" != "undo" ] && undo

if [ "$1" == "high" ]; then
	underclock "$BASE_PL"
elif [ "$1" == "med" ]; then
	limit="$(do_math $BASE_PL 0.8)" # 80%
	underclock "$limit"
elif [ "$1" == "low" ]; then
	limit="$(do_math $BASE_PL 0.72)" # 72%
	underclock "$limit"
elif [ "$1" == "vlow" ]; then
	limit="$(do_math $BASE_PL 0.6)" # 60%
	underclock "$limit"
elif [ "$1" == "xlow" ]; then
	limit="$(do_math $BASE_PL 0.4)" # 40%
	underclock "$limit"
elif [ "$1" == "undo" ]; then
	undo
fi
