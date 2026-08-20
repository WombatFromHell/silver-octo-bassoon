#!/usr/bin/env bash
set -euo pipefail

export DRI_PRIME=1
export VK_DEVICE_FILTER=discrete

exec "$@"
