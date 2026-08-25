#!/usr/bin/env bash
# Shared GPU detection helpers. Sourced by chromium-wrapper.sh and
# bazzified-steam.sh so both use one sysfs-based hybrid-graphics check.
# DRM_SYS_PATH is overridable (tests set it before sourcing).

readonly DRM_SYS_PATH="${DRM_SYS_PATH:-/sys/class/drm}"

# Hybrid graphics is "in use" (not merely enabled) only when >=2 distinct GPU
# devices each drive a connected output - i.e. the desktop actually spans GPUs.
# ponytail: counts distinct PCI devices with a connected connector via sysfs;
# no drm library needed. Prints the active-GPU count, returns 0 if hybrid.
detect_hybrid_graphics() {
  local card gpu count=0
  local -A seen
  for card in "$DRM_SYS_PATH"/card[0-9]*; do
    [[ -d "$card/device" ]] || continue
    gpu=$(readlink -f "$card/device")
    gpu=${gpu##*/}
    [[ -n ${seen[$gpu]:-} ]] && continue
    for status in "$card"/*/status; do
      [[ -f $status ]] && grep -q '^connected$' "$status" || continue
      seen[$gpu]=1
      count=$((count + 1))
      break
    done
  done
  echo "$count"
  ((count >= 2))
}
