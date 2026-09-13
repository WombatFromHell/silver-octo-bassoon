#!/usr/bin/env bash
set -euo pipefail
exec gamemode -- nscb -f -r 140 -- env -u DISABLE_LSFG PROTON_ADD_CFG="wayland,hdr,sdlinput" "$@"
