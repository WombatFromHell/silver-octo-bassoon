#!/usr/bin/env bash

# Append fallback system paths while preserving test mock PATH order
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
source "${BASH_SOURCE[0]%/*}/statusbar-lib.bash"

# Pass variable directly so refresh_interval defaults to 3 when unset
refresh_interval "${STATUSBAR_REFRESH:-}"

socket_path="${TMUX%%,*}"
lock="${socket_path:-/tmp/tx}-statusbar.lock"

if command -v flock >/dev/null; then
  exec 9>"$lock"
  flock -n 9 || exit 0
else
  claim() { (
    set -o noclobber
    echo $$ >"$lock"
  ) 2>/dev/null; }
  if ! claim; then
    if kill -0 "$(<"$lock")" 2>/dev/null; then
      exit 0
    fi
    rm -f "$lock"
    claim || exit 0
  fi
  trap 'rm -f "$lock"' EXIT
fi

# Clear metric options on cold start so blocks remain hidden until first sample completes
tmux set-option -gu @cpu \; set-option -gu @ram \; set-option -gu @gpu_util \; set-option -gu @vram \; set-option -gu @batt \; set-option -gu @batt_icon 2>/dev/null || true

platform=$(uname -s)

if [[ $platform == Darwin ]]; then
  sample() {
    cpu_darwin "$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null)"
    ram_darwin "$(vm_stat 2>/dev/null)" "$(sysctl -n hw.memsize 2>/dev/null)"
    batt_darwin "$(pmset -g batt 2>/dev/null)"
  }
else
  prev_total=0
  prev_idle=0
  sample() {
    local u n s i w total idle mt ma
    read -r _ u n s i w _ </proc/stat
    total=$((u + n + s + i + w))
    idle=$((i + w))
    cpu_delta "$prev_total" "$prev_idle" "$total" "$idle"
    prev_total=$total
    prev_idle=$idle
    read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
    ram_pct "$mt" "$ma"
    batt_linux
  }
fi

while :; do
  tmux show-options -g >/dev/null 2>&1 || exit 0

  gpu_read
  sample

  args=(set-option -g @cpu "$cpu" \; set-option -g @ram "$ram")
  if [[ -n $batt ]]; then
    args+=(\; set-option -g @batt "$batt" \; set-option -g @batt_icon "$batt_icon")
  else
    args+=(\; set-option -gu @batt \; set-option -gu @batt_icon)
  fi

  if [[ $gpu =~ ^[0-9]+$ ]]; then
    args+=(\; set-option -g @gpu_util "$gpu")
    if [[ $vram =~ ^[0-9]+$ ]]; then
      args+=(\; set-option -g @vram "$vram")
    else
      args+=(\; set-option -gu @vram)
    fi
  else
    args+=(\; set-option -gu @gpu_util \; set-option -gu @vram)
  fi

  args+=(\; refresh-client -A -S)

  tmux "${args[@]}"

  if [[ $platform == Darwin ]]; then
    sleep_time=$((refresh > 1 ? refresh - 1 : 1))
  else
    sleep_time="$refresh"
  fi

  sleep "$sleep_time"
done
