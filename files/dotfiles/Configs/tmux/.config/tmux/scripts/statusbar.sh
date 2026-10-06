#!/usr/bin/env bash
# statusbar.sh — pull-model status-right provider for tmux's `#()`.
# tmux spawns it as a background job on every status draw (status ticks AND
# job-completion redraws — back-to-back), inserts the last output line into
# status-right verbatim, and redraws when it exits. We enforce "no pull
# faster than status-interval": at most one full pull per interval, and
# faster spawns emit the last composed output. State + lock live in
# TMUX_TMPDIR if set, else /tmp (`#()` children get no TMUX_TMPDIR).
# Output rules:
#   * single line, single % (tmux does not strftime `#()` output)
#   * no `#{}`; `#[...]` styles are honored
#   * the time block is composed here (static: rendered at pull time)
exec 2>/dev/null
export PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/statusbar-lib.bash"

# --- pacing: at most one pull per status-interval --------------------------
# State file: line 1 = last claim (epoch s), line 2 = last composed output.
_sb_state="${TMUX_TMPDIR:-/tmp}/sb-state"

# _sb_lock — exclusive flock so concurrent spawns (tick + completion redraw)
# serialize; skipped when flock is absent (stock macOS) -> rare double-work.
_sb_lock() {
  command -v flock >/dev/null && exec 9>"${_sb_state}.lock" && flock 9
  return 0
}

# _sb_interval -> status-interval read live from tmux (the conf stays the
# source of truth; runtime changes are followed); default 3 if unavailable.
_sb_interval() {
  local iv
  iv=$(tmux show-options -gv status-interval 2>/dev/null | awk '{print $NF}')
  [[ $iv =~ ^[1-9][0-9]*$ ]] || iv=3
  printf '%s' "$iv"
}

# _sb_read_state -> SB_LAST (claim ts) / SB_CACHE (last composed output).
_sb_read_state() {
  SB_LAST= SB_CACHE=
  {
    IFS= read -r SB_LAST
    IFS= read -r SB_CACHE
  } <"$_sb_state" 2>/dev/null
  [[ $SB_LAST =~ ^[0-9]+$ ]] || SB_LAST=0
}

# _sb_clock_format -> print the raw @clock-format value. The single tmux
# interface for the time block (the library stays tmux-free).
_sb_clock_format() {
  tmux show-options -gv @clock-format 2>/dev/null | awk '{print $NF}'
}

# _sb_stamp -> date_str / clock for the time block (cheap, always rendered).
_sb_stamp() {
  date_str=$(date +%m.%d)
  clock=$(date +"$(_sb_clock_fmt "$(_sb_clock_format)")")
}

# _sb_pull -> the slow part: fills gpu/vram/cpu/ram/batt.
_sb_pull() {
  gpu_read
  if [[ $(uname -s) == Darwin ]]; then
    cpu_darwin "$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null)"
    ram_darwin "$(vm_stat 2>/dev/null)" "$(sysctl -n hw.memsize 2>/dev/null)"
    batt_darwin "$(pmset -g batt 2>/dev/null)" || true
  else
    read -r _ u n s i w _ </proc/stat
    total=$((u + n + s + i + w)) idle=$((i + w))
    sleep 0.5 # keeps the pull's #() job under tmux's 1s in-flight window
    read -r _ u n s i w _ </proc/stat
    total2=$((u + n + s + i + w)) idle2=$((i + w))
    cpu_delta "$total" "$idle" "$total2" "$idle2"
    read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
    ram_pct "$mt" "$ma"
    batt_linux || true
  fi
}

# _sb_write TS METRICS -> atomic state update (the renderer never sees a partial file).
_sb_write() {
  printf '%s\n%s\n' "$1" "$2" >"$_sb_state.$$" && mv "$_sb_state.$$" "$_sb_state"
}

# _sb_fetch TS -> slow path, runs detached: pull, publish metrics, ask for a redraw.
_sb_fetch() {
  _sb_pull
  _sb_write "$1" "$(compose_metrics)"
  tmux refresh-client -S
}

# Renderer: never waits on a pull.
_sb_lock
now=$(date +%s)
_sb_read_state
ready=0
[[ -f $_sb_state ]] && ready=1
if ((now - SB_LAST >= $(_sb_interval))); then
  _sb_write "$now" "$SB_CACHE" # claim first so concurrent spawns don't double-fetch
  # stdio + lock fd closed so tmux sees this job exit now, not when the fetch ends
  _sb_fetch "$now" </dev/null >/dev/null 9>&- &
fi
_sb_stamp
printf '%s%s' "$SB_CACHE" "$(_sb_time "$ready")"
