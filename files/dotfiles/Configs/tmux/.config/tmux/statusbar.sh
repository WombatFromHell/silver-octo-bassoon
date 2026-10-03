#!/usr/bin/env bash
# Refreshes GPU/CPU/RAM into tmux global env vars for the status bar.
# Started from tmux.conf via `run -b`; flock-guarded so config reloads
# don't spawn duplicate loops.
exec 9>/tmp/tmux-statusbar.lock
flock -n 9 || exit 0
while :; do
  gpu=0; vram=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    read -r util used total <<<"$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | head -1)"
    [[ $util =~ ^[0-9]+$ ]] && gpu=$util
    [[ $total =~ ^[0-9]+$ ]] && (( total > 0 )) && vram=$(( used * 100 / total ))
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
    [[ $gpu =~ ^[0-9]+$ ]] || gpu=0
    [[ $vram =~ ^[0-9]+$ ]] || vram=0
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

  tmux set-environment -g GPU_UTIL "$gpu"
  tmux set-environment -g VRAM "$vram"
  tmux set-environment -g CPU "$cpu"
  tmux set-environment -g RAM "$ram"
  sleep 2
done
