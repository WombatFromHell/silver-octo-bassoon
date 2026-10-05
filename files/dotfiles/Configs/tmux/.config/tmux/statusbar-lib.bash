#!/usr/bin/env bash
# statusbar-lib.bash — pure parse/compute layer for the tmux status bar.
# No tmux, no loop, no sleep, no /proc I/O: every function takes its input
# (a tool's raw output or a proc snapshot) and fills the gpu/vram/cpu/ram
# globals. Sourced by statusbar.sh (the consumer) and by the bats suite
# (the unit tier), so the same logic is tested with fixtures and in the
# live loop.

# ---------------------------------------------------------------------------
# 1. General Helpers
# ---------------------------------------------------------------------------

# refresh_interval VALUE -> sets refresh (positive integer seconds, else 3).
refresh_interval() {
  refresh=3
  [[ $1 =~ ^[1-9][0-9]*$ ]] && refresh=$1
  return 0
}

# _tout SECONDS CMD... -> run CMD with a timeout when timeout(1) or its
# GNU-coreutils macOS alias gtimeout(1) exists; otherwise run it directly.
# GPU probes are best-effort and self-limiting, so the fallback is safe.
_tout() {
  local t=$1
  shift
  if command -v timeout >/dev/null; then
    timeout "$t" "$@"
  elif command -v gtimeout >/dev/null; then
    gtimeout "$t" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 2. GPU Providers
# ---------------------------------------------------------------------------

# Vendor helpers: set the gpu/vram globals, return 1 when their tool is
# absent or reports nothing usable (the bar then hides the GPU block).

gpu_nvidia() {
  local util used total
  command -v nvidia-smi >/dev/null || return 1
  IFS=', ' read -r util used total <<<"$(_tout 2 nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
  [[ $util =~ ^[0-9]+$ && $used =~ ^[0-9]+$ && $total =~ ^[0-9]+$ ]] || return 1
  ((total > 0)) || return 1
  gpu=$util
  vram=$((used * 100 / total))
}

gpu_amd() {
  local out
  command -v amd-smi >/dev/null && command -v jq >/dev/null || return 1
  out=$(_tout 2 amd-smi metric -u -m --json 2>/dev/null | jq -r '
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
  stats=$(_tout 3 xpu-smi stats -j 2>/dev/null | head -1)
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
  gpu=$(_tout 3 intel_gpu_top -J -n 1 2>/dev/null |
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
  return 0
}

# ---------------------------------------------------------------------------
# 3. Linux CPU/RAM Calculation Primitives
# ---------------------------------------------------------------------------
# These are pure math functions. They do not read /proc themselves;
# statusbar.sh reads /proc and passes the values here.

# cpu_delta PREV_TOTAL PREV_IDLE TOTAL IDLE -> sets cpu (0 when no forward
# delta, i.e. first iteration or a clock step backwards).
cpu_delta() {
  cpu=0
  if (($3 > $1)); then
    cpu=$((($3 - $1 - ($4 - $2)) * 100 / ($3 - $1)))
  fi
  return 0
}

# ram_pct MT MA -> sets ram (percent of memory in use).
ram_pct() {
  ram=$((($1 - $2) * 100 / $1))
  return 0
}

# ---------------------------------------------------------------------------
# 4. macOS (Darwin) Parsers
# ---------------------------------------------------------------------------
# macOS has no /proc: statusbar.sh feeds these the raw output of top(1) and
# vm_stat(1). Same contract as the Linux path: fill cpu / ram, never fail.

# cpu_darwin TOP_OUTPUT -> sets cpu from the LAST "CPU usage:" line
# (`top -l 2`: sample 1 is since-boot, sample 2 is the delta over -s seconds).
cpu_darwin() {
  cpu=$(awk '/^CPU usage:/ { for (i = 2; i <= NF; i++) if ($i == "idle") v = $(i - 1) }
             END { if (v != "") printf "%d", 100 - v }' <<<"$1")
  [[ $cpu =~ ^[0-9]+$ ]] || cpu=0
  return 0
}

# ram_darwin VM_STAT_OUTPUT MEMSIZE_BYTES -> sets ram. "Used" mirrors Activity
# Monitor: (anonymous - purgeable) + wired + compressor pages.
ram_darwin() {
  local page used

  # Extract page size (e.g., 16384) from header: "(page size of 16384 bytes)"
  page=$(awk '/page size of/ { for (i = 1; i < NF; i++) if ($i == "of") print $(i + 1) }' <<<"$1")

  # Calculate used pages based on Activity Monitor formula
  used=$(awk -F: '
    { gsub(/[^0-9]/, "", $2) }
    /^Anonymous pages/              { n += $2 }
    /^Pages purgeable/              { n -= $2 }
    /^Pages wired down/             { n += $2 }
    /^Pages occupied by compressor/ { n += $2 }
    END { print (n > 0 ? n : 0) }' <<<"$1")

  if [[ $page =~ ^[1-9][0-9]*$ && $2 =~ ^[1-9][0-9]*$ ]]; then
    # Total physical memory is passed as $2 (bytes).
    # Convert used pages to bytes, subtract from total to get available/free equivalent for ram_pct
    # Note: ram_pct expects (Total, Available).
    # Used Bytes = used_pages * page_size
    # Free/Avail Bytes = Total Bytes - Used Bytes
    ram_pct "$2" $(($2 - used * page))
  else
    ram=0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5. Battery Parsers
# ---------------------------------------------------------------------------

# _batt_is_ac STATUS ONLINE -> success when the battery sits on AC power.
# STATUS is the raw state string (pmset output, or /sys .../status) and ONLINE
# is "1" when the AC adapter reads online (Linux only, else empty). "Not
# charging" (charge limits / macOS optimized charging) still means AC; only an
# explicit "discharging" is not, and it must be tested first because
# "discharging" contains the substring "charging".
_batt_is_ac() {
  local status=${1:-} online=${2:-}
  [[ $online == 1 ]] && return 0
  [[ $status =~ [Dd]ischarging ]] && return 1
  [[ $status =~ [Cc]harging|[Cc]harged|Full|[Ff]inished[[:space:]]charging ]] && return 0
  return 1
}

# _batt_icon PCT STATUS [ONLINE] -> prints the glyph: the single charging icon
# whenever the battery is on AC (at any percentage, including full/paused),
# otherwise the tiered level icon for PCT.
_batt_icon() {
  local pct=$1 status=${2:-} online=${3:-}
  if _batt_is_ac "$status" "$online"; then
    printf '󰂄'
  elif ((pct < 10)); then
    printf '󰂎'
  elif ((pct < 20)); then
    printf '󰁺'
  elif ((pct < 30)); then
    printf '󰁻'
  elif ((pct < 40)); then
    printf '󰁼'
  elif ((pct < 50)); then
    printf '󰁽'
  elif ((pct < 60)); then
    printf '󰁾'
  elif ((pct < 70)); then
    printf '󰁿'
  elif ((pct < 80)); then
    printf '󰂀'
  elif ((pct < 90)); then
    printf '󰂁'
  elif ((pct < 100)); then
    printf '󰂂'
  else
    printf '󰁹'
  fi
}

batt_darwin() {
  batt=
  batt_icon=
  local raw=$1
  [[ $raw =~ ([0-9]+)% ]] || return 1
  batt="${BASH_REMATCH[1]}"
  batt_icon=$(_batt_icon "$batt" "$raw")
  return 0
}

# _ac_online -> success when any AC adapter is online. Drivers that report a
# battery status of "Unknown" on AC give us no other signal, so this is what
# keeps those laptops on the charging icon.
_ac_online() {
  local ac_dir online
  for ac_dir in /sys/class/power_supply/AC*; do
    [[ -r "$ac_dir/online" ]] || continue
    online=$(cat "$ac_dir/online" 2>/dev/null)
    [[ $online == 1 ]] && return 0
  done
  return 1
}

batt_linux() {
  batt=
  batt_icon=
  local bat_dir cap status online=
  _ac_online && online=1
  for bat_dir in /sys/class/power_supply/BAT*; do
    if [[ -r "$bat_dir/capacity" ]]; then
      cap=$(cat "$bat_dir/capacity" 2>/dev/null)
      status=$(cat "$bat_dir/status" 2>/dev/null)
      if [[ $cap =~ ^[0-9]+$ ]]; then
        batt=$cap
        batt_icon=$(_batt_icon "$batt" "$status" "$online")
        return 0
      fi
    fi
  done
  return 1
}
