#!/usr/bin/env bash
# statusbar-lib.sh — pure parse/compute layer for the tmux status bar.
# No tmux, no loop, no sleep, no /proc I/O: every function takes its input
# (a tool's raw output or a proc snapshot) and fills the gpu/vram/cpu/ram
# globals. Sourced by statusbar.sh (the consumer) and by the bats suite
# (the unit tier), so the same logic is tested with fixtures and in the
# live loop.

# refresh_interval VALUE -> sets refresh (positive integer seconds, else 3).
refresh_interval() {
  refresh=3
  [[ $1 =~ ^[1-9][0-9]*$ ]] && refresh=$1
  return 0
}
# Vendor helpers: set the gpu/vram globals, return 1 when their tool is
# absent or reports nothing usable (the bar then hides the GPU block).
gpu_nvidia() {
  local util used total
  command -v nvidia-smi >/dev/null || return 1
  IFS=', ' read -r util used total <<<"$(timeout 2 nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
  [[ $util =~ ^[0-9]+$ && $used =~ ^[0-9]+$ && $total =~ ^[0-9]+$ ]] || return 1
  ((total > 0)) || return 1
  gpu=$util
  vram=$((used * 100 / total))
}

gpu_amd() {
  local out
  command -v amd-smi >/dev/null && command -v jq >/dev/null || return 1
  # Pick the largest-VRAM GPU (the dGPU) -> gfx_activity %, VRAM %
  out=$(timeout 2 amd-smi metric -u -m --json 2>/dev/null | jq -r '
    .gpu_data
    | map(select((.mem_usage.total_vram.value // 0) > 0))
    | max_by(.mem_usage.total_vram.value)
    | [(.usage.gfx_activity.value | if type=="number" then (. | floor) else 0 end),
       ((.mem_usage.used_vram.value * 100 / .mem_usage.total_vram.value) | floor)]
    | @csv' 2>/dev/null)
  gpu=${out%%,*}
  vram=${out##*,}
  [[ $gpu =~ ^[0-9]+$ && $vram =~ ^[0-9]+$ ]] || return 1
}

gpu_intel_dgpu() {
  local stats
  command -v xpu-smi >/dev/null && command -v jq >/dev/null || return 1
  # Intel Arc (xpu-smi, the 700-series successor to intel_gpu_top):
  # metrics live in device_level[] keyed by metrics_type.
  stats=$(timeout 3 xpu-smi stats -j 2>/dev/null | head -1)
  gpu=$(printf '%s' "$stats" | jq -r \
    '[.device_level[]? | select(.metrics_type == "XPUM_STATS_GPU_UTILIZATION") | (.value | floor)] | .[0] // empty' 2>/dev/null)
  vram=$(printf '%s' "$stats" | jq -r \
    '[.device_level[]? | select(.metrics_type == "XPUM_STATS_MEMORY_UTILIZATION") | (.value | floor)] | .[0] // empty' 2>/dev/null)
  [[ $gpu =~ ^[0-9]+$ ]] || gpu=
  [[ $vram =~ ^[0-9]+$ ]] || vram=
  [[ -n $gpu ]]
}

gpu_intel_igpu() {
  command -v intel_gpu_top >/dev/null && command -v jq >/dev/null || return 1
  # Intel iGPU: utilization = max busy across engines; no discrete VRAM
  # figure, so vram stays empty and the bar hides the VRAM sub-block.
  gpu=$(timeout 3 intel_gpu_top -J -n 1 2>/dev/null |
    jq -s '([.[]? | .engines? // {} | .[]? | .busy?]) | (max // empty | floor)' 2>/dev/null)
  [[ $gpu =~ ^[0-9]+$ ]] || return 1
}

# Provider precedence: NVIDIA -> AMD -> Intel dGPU -> Intel iGPU.
gpu_read() {
  gpu=
  vram=
  local f
  for f in gpu_nvidia gpu_amd gpu_intel_dgpu gpu_intel_igpu; do
    "$f" && return 0
  done
  return 0 # no GPU tool found is a valid state, not an error
}

# cpu_delta PREV_TOTAL PREV_IDLE TOTAL IDLE -> sets cpu (0 when no forward
# delta, i.e. first iteration or a clock step backwards).
cpu_delta() {
  cpu=0
  if (($3 > $1)); then cpu=$((($3 - $1 - ($4 - $2)) * 100 / ($3 - $1))); fi
  return 0
}

# ram_pct MT MA -> sets ram (percent of memory in use).
ram_pct() {
  ram=$((($1 - $2) * 100 / $1))
  return 0
}
