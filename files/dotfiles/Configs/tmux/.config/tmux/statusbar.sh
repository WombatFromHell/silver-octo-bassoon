#!/usr/bin/env bash
# Refreshes GPU/CPU/RAM into tmux global env vars for the status bar.
# Started from tmux.conf via `run -b`; flock-guarded so config reloads
# don't spawn duplicate loops.
exec 9>/tmp/tmux-statusbar.lock
flock -n 9 || exit 0
while :; do
  # Liveness: exit (releasing the flock) when our server is gone, e.g. after
  # a server restart, so the new server can spawn a fresh loop.
  tmux show-options -g >/dev/null 2>&1 || exit 0

  # Fast short-circuit: only fetch when a usable GPU tool exists; unusable
  # output leaves the vars unset so the status bar hides its GPU block.
  # Provider precedence: NVIDIA -> AMD -> Intel dGPU (xpu-smi) -> iGPU
  # (intel_gpu_top).
  gpu=; vram=
  if command -v nvidia-smi >/dev/null 2>&1; then
    IFS=', ' read -r util used total <<<"$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
    if [[ $util =~ ^[0-9]+$ ]] && [[ $used =~ ^[0-9]+$ ]] && [[ $total =~ ^[0-9]+$ ]] && (( total > 0 )); then
      gpu=$util
      vram=$(( used * 100 / total ))
    fi
  elif command -v amd-smi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # AMD: pick the largest-VRAM GPU (the dGPU) -> gfx_activity %, VRAM %
    out=$(amd-smi metric -u -m --json 2>/dev/null | jq -r '
      .gpu_data
      | map(select((.mem_usage.total_vram.value // 0) > 0))
      | max_by(.mem_usage.total_vram.value)
      | [(.usage.gfx_activity.value | if type=="number" then . else 0 end),
         ((.mem_usage.used_vram.value * 100 / .mem_usage.total_vram.value) | floor)]
      | @csv' 2>/dev/null)
    gpu=${out%%,*}
    vram=${out##*,}
    [[ $gpu =~ ^[0-9]+$ ]] && [[ $vram =~ ^[0-9]+$ ]] || { gpu=; vram=; }
  elif command -v xpu-smi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # Intel discrete GPU (Arc). xpu-smi is the Intel 700-series successor
    # to intel_gpu_top; metrics live in device_level[] keyed by
    # metrics_type (key names verified against xpu-smi upstream source).
    stats=$(xpu-smi stats -j 2>/dev/null | head -1)
    gpu=$(printf '%s' "$stats" | jq -r \
      '[.device_level[]? | select(.metrics_type == "XPUM_STATS_GPU_UTILIZATION") | (.value | floor)] | .[0] // empty' 2>/dev/null)
    vram=$(printf '%s' "$stats" | jq -r \
      '[.device_level[]? | select(.metrics_type == "XPUM_STATS_MEMORY_UTILIZATION") | (.value | floor)] | .[0] // empty' 2>/dev/null)
    [[ $gpu =~ ^[0-9]+$ ]] || gpu=
    [[ $vram =~ ^[0-9]+$ ]] || vram=
  elif command -v intel_gpu_top >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # Intel iGPU. -J = JSON, -n 1 = one iteration. Utilization is the max
    # busy across all engines; iGPUs expose no discrete VRAM figure, so
    # vram stays empty and the statusbar hides the VRAM sub-block.
    gpu=$(intel_gpu_top -J -n 1 2>/dev/null \
      | jq -s '([.[]? | .engines? // {} | .[]? | .busy?]) | (max // empty | floor)' 2>/dev/null)
    [[ $gpu =~ ^[0-9]+$ ]] || gpu=
  fi

  read -r _ u1 n1 s1 i1 w1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 _ < /proc/stat
  total=$(( (u2+n2+s2+i2+w2) - (u1+n1+s1+i1+w1) ))
  idle=$(( (i2+w2) - (i1+w1) ))
  cpu=0
  (( total > 0 )) && cpu=$(( (total - idle) * 100 / total ))

  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  ram=$(( (mt - ma) * 100 / mt ))

  if [[ $gpu =~ ^[0-9]+$ ]]; then
    tmux set-environment -g GPU_UTIL "$gpu"
    if [[ $vram =~ ^[0-9]+$ ]]; then
      tmux set-environment -g VRAM "$vram"
    else
      tmux set-environment -g -u VRAM
    fi
  else
    tmux set-environment -g -u GPU_UTIL
    tmux set-environment -g -u VRAM
  fi
  tmux set-environment -g CPU "$cpu"
  tmux set-environment -g RAM "$ram"
  sleep 2
done
