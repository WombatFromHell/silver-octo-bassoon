#!/usr/bin/env bash
# statusbar.sh — one-shot status-right provider for tmux's `#()`.
# tmux spawns it as a background job on every status draw (one start/second;
# steady state = status-interval), inserts the last output line into
# status-right verbatim, and redraws when it exits. Output rules:
#   * single line, single % (tmux does not strftime `#()` output)
#   * no `#{}`; `#[...]` styles are honored
#   * the time block lives in the conf, not here
exec 2>/dev/null
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/statusbar-lib.bash"

gpu_read
platform=$(uname -s)
if [[ $platform == Darwin ]]; then
  cpu_darwin "$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null)"
  ram_darwin "$(vm_stat 2>/dev/null)" "$(sysctl -n hw.memsize 2>/dev/null)"
  batt_darwin "$(pmset -g batt 2>/dev/null)" || true
else
  read -r _ u n s i w _ </proc/stat
  total=$((u + n + s + i + w)) idle=$((i + w))
  sleep 1
  read -r _ u n s i w _ </proc/stat
  total2=$((u + n + s + i + w)) idle2=$((i + w))
  cpu_delta "$total" "$idle" "$total2" "$idle2"
  read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  ram_pct "$mt" "$ma"
  batt_linux || true
fi

compose_blocks
