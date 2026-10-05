#!/usr/bin/env bats
# statusbar-test.bats — red/green suite for statusbar.sh + statusbar-lib.bash.
#
# Unit tier: sources the pure lib, feeds fixture GPU/proc inputs, asserts
# parsed gpu/vram/cpu/ram. No tmux server, no sleeps.
#
# Integration tier: runs the real consumer against a throwaway tmux server.
# Isolation guarantees:
#   * every test gets its own temp dir ($T) holding the socket, HOME, mocks,
#     logs; teardown is a single `rm -rf "$T"`
#   * the ONLY way tests reach tmux is the `tmux` wrapper below, which always
#     passes -S "$SOCK" and refuses to run when no scratch socket exists, so a
#     real server can never be touched (TMUX/TMUX_PANE are unset in setup)
#   * `sleep` in the consumer's PATH is a shim (logs its arg, sleeps 50ms), so
#     the loop spins fast and tests poll for state instead of sleeping
#   * no fixed /tmp paths -> safe under `bats --jobs N`

load test_helper

setup() {
  DIR="$BATS_TEST_DIRNAME"
  LIB="$DIR/../scripts/statusbar-lib.bash"
  REAL_SLEEP="$(type -P sleep)" # for the consumer's sleep shim
  SCRIPT_PID=""
}

teardown() {
  if [[ -n $SCRIPT_PID ]]; then kill_tree "$SCRIPT_PID" 2>/dev/null; fi
  stop_scratch_server # also removes $T in the unit tier (no server)
}

kill_tree() {
  local p c
  for p in "$@"; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
    kill "$p" 2>/dev/null || true
  done
}

# --- helpers -------------------------------------------------------------------

# make_mock NAME CONTENT -> executable in $T/mock, without overwriting other mocks.
make_mock() {
  ensure_tmp
  mkdir -p "$T/mock"
  rm -f "$T/mock/$1" # never write through a symlink to a real binary
  printf '%s' "$2" >"$T/mock/$1"
  chmod +x "$T/mock/$1"
}

# Helper for unit tests to access system utilities (head, jq, etc.)
init_unit_bin() {
  ensure_tmp
  mkdir -p "$T/bin"
  link_tools "$T/bin" jq awk sleep head cat bash flock timeout uname rm grep sed tr cut wc sort tail ps sysctl vm_stat top
}

# Unit tier helper
call_gpu() {
  (
    init_unit_bin
    export PATH="$T/mock:$T/bin"
    source "$LIB"
    gpu_read
    printf '%s %s' "$gpu" "$vram"
  )
}

# Poll helpers: replace every fixed sleep (updated for tmux user options @var).
opt_var() { tmux show-options -gv "$1" 2>/dev/null; }
opt_is() { [[ "$(opt_var "$1")" =~ $2 ]]; }
wait_opt() { wait_until 5 opt_is "$@"; } # VAR REGEX
is_dead() { ! kill -0 "$1" 2>/dev/null; }

# The shim logs once per loop iteration, so a non-empty log == iteration 1 done.
wait_iteration() { wait_until 5 test -s "$T/sleep.log"; }
first_sleep_arg() { head -n1 "$T/sleep.log"; }

# --- integration-tier server ---------------------------------------------------

start_server() {
  start_scratch_server
  mkdir -p "$T/bin"
  link_tools "$T/bin" tmux jq awk sleep head cat bash flock timeout uname rm grep sed tr cut wc sort tail ps sysctl vm_stat top
}

# start_consumer [ENV=VAL ...]
start_consumer() {
  ensure_tmp
  make_mock sleep "#!/bin/sh
echo \"\$1\" >> '$T/sleep.log'
exec '$REAL_SLEEP' 0.05"
  env PATH="$T/mock:$T/bin" TMUX="$SOCK,0,0" "$@" \
    bash "$DIR/../scripts/statusbar.sh" >/dev/null 2>&1 3>&- &
  SCRIPT_PID=$!
}

status_right() { tmux display-message -p -t base "$(tmux show-options -gv status-right)"; }

# Render the tab list (@sl_windows_fmt) from the scratch server, style tokens stripped.
tab_list() { tmux display -p -t base:0 '#{E:@sl_windows_fmt}' | sed 's/#\[[^]]*\]//g'; }

# ---------------------------------------------------------------------------
# UNIT TIER — pure parse/compute (no server)
# ---------------------------------------------------------------------------

@test "nvidia: parses util and vram percent" {
  make_mock nvidia-smi '#!/bin/sh
echo "12, 550, 8192"'
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "12" ]]
  [[ $vram == "6" ]]
}

@test "nvidia: broken output leaves gpu/vram empty" {
  make_mock nvidia-smi '#!/bin/sh
echo "NVIDIA-SMI has failed" >&2
exit 1'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "nvidia: zero total VRAM is rejected" {
  make_mock nvidia-smi '#!/bin/sh
echo "12, 550, 0"'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "amd: picks largest-VRAM GPU, floors util and vram" {
  make_mock amd-smi '#!/bin/sh
cat <<JSON
{"gpu_data":[{"usage":{"gfx_activity":{"value":41.7}},"mem_usage":{"used_vram":{"value":3000},"total_vram":{"value":8000}}},{"usage":{"gfx_activity":{"value":5.0}},"mem_usage":{"used_vram":{"value":100},"total_vram":{"value":200}}}]}
JSON'
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "41" ]]
  [[ $vram == "37" ]]
}

@test "intel dGPU: parses utilization and memory, floors" {
  make_mock xpu-smi '#!/bin/sh
echo '\''{"device_id":0,"device_level":[{"metrics_type":"XPUM_STATS_GPU_UTILIZATION","value":37.5},{"metrics_type":"XPUM_STATS_MEMORY_UTILIZATION","value":42.1},{"metrics_type":"XPUM_STATS_POWER","value":45.0}]}'\'''
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "37" ]]
  [[ $vram == "42" ]]
}

@test "intel iGPU: max engine busy, no vram" {
  make_mock intel_gpu_top '#!/bin/sh
echo '\''{"period":{"duration":1000,"unit":"ms"},"engines":{"Render/3D/0":{"busy":12.5,"sema":0,"wait":0,"unit":"%"},"Blitter/0":{"busy":1.0,"sema":0,"wait":0,"unit":"%"}},"clients":[]}'\'''
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "12" ]]
  [[ -z $vram ]]
}

@test "gpu_read: no GPU tool -> empty" {
  make_mock noop '#!/bin/sh
exit 1'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "cpu_delta: computes percent from totals" {
  source "$LIB"
  cpu_delta 0 0 100 40
  [[ $cpu == "60" ]]
}

@test "cpu_delta: no forward delta -> 0" {
  source "$LIB"
  cpu_delta 100 40 100 40
  [[ $cpu == "0" ]]
}

@test "cpu_delta: backward clock -> 0" {
  source "$LIB"
  cpu_delta 100 40 90 30
  [[ $cpu == "0" ]]
}

@test "ram_pct: computes percent in use" {
  source "$LIB"
  ram_pct 1000 250
  [[ $ram == "75" ]]
}

@test "refresh_interval: positive integers pass, anything else -> 3" {
  source "$LIB"
  local v
  for v in 1 5 60; do
    refresh_interval "$v"
    [[ $refresh == "$v" ]]
  done
  for v in "" 0 -2 abc 1.5 "3 4"; do
    refresh_interval "$v"
    [[ $refresh == "3" ]]
  done
}

# --- macOS fixtures ----------------------------------------------------------
TOP='Processes: 500 total, 2 running, 498 sleeping, 2500 threads
2026/10/04 12:00:00
Load Avg: 1.00, 1.00, 1.00
CPU usage: 40.00% user, 30.00% sys, 30.00% idle
SharedLibs: 500M resident, 100M data, 50M linkedit.
Processes: 500 total, 2 running, 498 sleeping, 2500 threads
2026/10/04 12:00:01
Load Avg: 1.00, 1.00, 1.00
CPU usage: 5.26% user, 10.52% sys, 84.21% idle
SharedLibs: 500M resident, 100M data, 50M linkedit.'
# 16 GiB = 1048576 pages of 16384; used = (400000-50000)+100000+98576 = 548576 -> 52%
VMSTAT='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Pages active:                            234567.
Pages inactive:                          123456.
Pages speculative:                         1234.
Pages throttled:                              0.
Pages wired down:                        100000.
Pages purgeable:                          50000.
"Translation faults":                 123456789.
Pages copy-on-write:                    1234567.
File-backed pages:                       200000.
Anonymous pages:                         400000.
Pages stored in compressor:              150000.
Pages occupied by compressor:             98576.'
MEMSIZE=17179869184

@test "cpu_darwin: last sample wins, busy = floor(100 - idle)" {
  source "$LIB"
  cpu_darwin "$TOP"
  [[ $cpu == "15" ]]
}

@test "cpu_darwin: no CPU line or empty input -> 0" {
  source "$LIB"
  cpu_darwin "garbage"
  [[ $cpu == "0" ]]
  cpu_darwin ""
  [[ $cpu == "0" ]]
}

@test "ram_darwin: Activity-Monitor-style used percent" {
  source "$LIB"
  ram_darwin "$VMSTAT" "$MEMSIZE"
  [[ $ram == "52" ]]
}

@test "ram_darwin: missing page size or memsize -> 0" {
  source "$LIB"
  ram_darwin "" "$MEMSIZE"
  [[ $ram == "0" ]]
  ram_darwin "$VMSTAT" ""
  [[ $ram == "0" ]]
}

# ---------------------------------------------------------------------------
# INTEGRATION TIER — real consumer against a throwaway server
# ---------------------------------------------------------------------------

@test "integration: cold start hides GPU/CPU blocks while first fetch is in flight" {
  start_server
  make_mock nvidia-smi "#!/bin/sh
i=0
while [ ! -e '$T/release' ] && [ \$i -lt 100 ]; do
  sleep 0.05; i=\$((i+1))
done
echo '12, 550, 8192'"
  start_consumer

  # Options should be unset (empty) on cold start before data is ready
  [[ -z "$(opt_var @cpu)" ]]
  [[ -z "$(opt_var @ram)" ]]
  [[ -z "$(opt_var @gpu_util)" ]]
  [[ -z "$(opt_var @vram)" ]]

  # Release the slow GPU fetch and verify values update
  : >"$T/release"
  wait_opt @gpu_util '^12$'
  wait_opt @vram '^6$'
}

@test "integration: no GPU tool sets CPU/RAM, unsets GPU/VRAM" {
  start_server
  # Hermetic: the consumer appends real system paths, so shadow every GPU
  # tool with a failing stub to keep "no GPU tool" true on any host.
  local t
  for t in nvidia-smi amd-smi xpu-smi intel_gpu_top; do
    make_mock "$t" '#!/bin/sh
exit 1'
  done
  start_consumer
  wait_iteration
  [[ "$(opt_var @cpu)" =~ ^[0-9]+$ ]]
  [[ "$(opt_var @ram)" =~ ^[0-9]+$ ]]
  [[ -z "$(opt_var @gpu_util)" ]]
  [[ -z "$(opt_var @vram)" ]]
}

@test "integration: mock nvidia-smi sets GPU_UTIL and VRAM" {
  start_server
  make_mock nvidia-smi '#!/bin/sh
echo "12, 550, 8192"'
  start_consumer
  wait_opt @gpu_util '^12$'
  wait_opt @vram '^6$'
  [[ "$(opt_var @cpu)" =~ ^[0-9]+$ ]]
}

@test "integration: loop exits when the server is killed" {
  start_server
  start_consumer
  wait_iteration
  tmux kill-server
  wait_until 5 is_dead "$SCRIPT_PID"
}

@test "integration: default refresh interval is 3s" {
  start_server
  start_consumer
  wait_iteration
  local expected=3
  [[ $(uname -s) == "Darwin" ]] && expected=2
  [[ "$(first_sleep_arg)" == "$expected" ]]
}

@test "integration: STATUSBAR_REFRESH is honored" {
  start_server
  start_consumer STATUSBAR_REFRESH=2
  wait_iteration
  local expected=2
  [[ $(uname -s) == "Darwin" ]] && expected=1
  [[ "$(first_sleep_arg)" == "$expected" ]]
}

@test "integration: status-right renders GPU/CPU blocks from options" {
  start_server
  load_conf
  tmux set-option -g @gpu_util 42
  tmux set-option -g @vram 67
  tmux set-option -g @cpu 15
  tmux set-option -g @ram 80
  local right
  right="$(status_right)"
  [[ $right == *42%* ]]
  [[ $right == *67%* ]]
  [[ $right == *15%* ]]
  [[ $right == *80%* ]]
}

@test "integration: status-right hides GPU block when @gpu_util unset" {
  start_server
  load_conf
  tmux set-option -g @gpu_util 42
  tmux set-option -g @cpu 15
  tmux set-option -g @ram 80
  local right
  right="$(status_right)"
  [[ $right == *42%* ]]
  [[ $right == *15%* ]]
  tmux set-option -gu @gpu_util
  tmux set-option -gu @vram
  right="$(status_right)"
  [[ $right != *42%* ]]
  [[ $right == *15%* ]]
}

# --- status-right block spacing ------------------------------------------------
# A hidden block must contribute no visible space: the gap between its
# neighbours must be exactly the one separator space, and a fully hidden
# leading run must leave no stray padding before the time block.

sb_right() { status_right | sed 's/#\[[^]]*\]//g'; }
# Length of the space run between /regex-before/ and /regex-after/.
gap_len() { # before-regex after-regex text
  local m
  m="$(sed -E "s/.*$1([ ]+)$2.*/\1/" <<<"$3")"
  printf '%s' "${#m}"
}

@test "integration: hidden battery leaves single gap between CPU and time blocks" {
  start_server
  load_conf
  tmux set-option -g @gpu_util 42
  tmux set-option -g @vram 67
  tmux set-option -g @cpu 15
  tmux set-option -g @ram 80
  tmux set-option -gu @batt
  tmux set-option -gu @batt_icon
  local right
  right="$(sb_right)"
  # RAM half (|80%) -> calendar icon: three spaces (CPU trailing pad + separator + time leading pad).
  [[ "$(gap_len '\|[0-9]+%' '' "$right")" == 3 ]]
}

@test "integration: visible battery keeps single spacing between all blocks" {
  start_server
  load_conf
  tmux set-option -g @gpu_util 42
  tmux set-option -g @vram 67
  tmux set-option -g @cpu 15
  tmux set-option -g @ram 80
  tmux set-option -g @batt 97
  tmux set-option -g @batt_icon '🔋'
  local right
  right="$(sb_right)"
  # Three spaces between each visible section (trailing + default-bg + leading).
  [[ "$(gap_len '\|[0-9]+%' '🔋' "$right")" == 3 ]]
  [[ "$(gap_len '[0-9]+%' '' "$right")" == 3 ]]
}

@test "integration: all metrics hidden leaves no stray space before time" {
  start_server
  load_conf
  tmux set-option -gu @gpu_util
  tmux set-option -gu @vram
  tmux set-option -gu @cpu
  tmux set-option -gu @ram
  tmux set-option -gu @batt
  tmux set-option -gu @batt_icon
  local right
  right="$(sb_right)"
  # Only the time block's own leading space remains (hidden blocks emit zero chars).
  [[ $right == ' '* ]]
}

@test "integration: hidden GPU leaves no stray leading space" {
  start_server
  load_conf
  tmux set-option -gu @gpu_util
  tmux set-option -gu @vram
  tmux set-option -g @cpu 15
  tmux set-option -g @ram 80
  local right
  right="$(sb_right)"
  # CPU block's own leading space only — GPU emitted zero characters.
  [[ $right == ' '* ]]
}

@test "integration: status-right renders four 0% placeholders when seeded 0" {
  start_server
  load_conf
  tmux set-option -g @gpu_util 0
  tmux set-option -g @vram 0
  tmux set-option -g @cpu 0
  tmux set-option -g @ram 0

  local right count
  right="$(status_right | sed -e 's/#\[[^]]*\]//g')"

  count="$({ grep -o '0\%' <<<"$right" || true; } | awk 'END { print NR }')"
  [[ $count == "4" ]]
}

# The Darwin sampler is exercised cross-platform via mocks; locking differs by
# platform (real flock shadows the mock on Linux), so the pidfile-lock content
# is asserted only in the Darwin-only test below.
@test "integration: Darwin sampler fills CPU/RAM from top/vm_stat (mocked)" {
  start_server
  rm -f "$T/bin/flock"
  make_mock uname '#!/bin/sh
echo Darwin'
  make_mock top "#!/bin/sh
cat <<'X'
$TOP
X"
  make_mock vm_stat "#!/bin/sh
cat <<'X'
$VMSTAT
X"
  make_mock sysctl "#!/bin/sh
echo $MEMSIZE"
  start_consumer
  wait_opt @cpu '^15$'
  wait_opt @ram '^52$'
}

@test "integration: without flock, a second consumer exits while the first lives" {
  start_server
  rm -f "$T/bin/flock"
  start_consumer
  wait_iteration
  local first=$SCRIPT_PID
  start_consumer
  wait_until 5 is_dead "$SCRIPT_PID"
  kill -0 "$first"
}

@test "integration: without flock, a stale lock from a dead owner is taken over" {
  # Darwin-only: on Linux the real flock shadows the mock and the consumer
  # takes the flock branch, which never writes $$ into the lockfile.
  [[ $(uname -s) == "Darwin" ]] || skip "Darwin-only (pidfile lock path)"
  start_server
  rm -f "$T/bin/flock"
  echo 999999 >"$SOCK-statusbar.lock"
  start_consumer
  wait_opt @cpu '^[0-9]+$'
  wait_iteration
  [[ "$(<"$SOCK-statusbar.lock")" == "$SCRIPT_PID" ]]
}

# --- Battery unit tests -----------------------------------------------------

@test "batt_darwin: parses percentage and maps discharging icon" {
  source "$LIB"
  batt_darwin "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=12345)	85%; discharging; 4:20 remaining present: true"
  [[ $batt == "85" ]]
  [[ $batt_icon == "󰂁" ]]
}

@test "batt_darwin: charging state uses charging icon" {
  source "$LIB"
  batt_darwin "Now drawing from 'AC Power'
 -InternalBattery-0 (id=12345)	45%; charging; 1:12 remaining present: true"
  [[ $batt == "45" ]]
  [[ $batt_icon == "󰂄" ]]
}

@test "batt_darwin: low battery (<10%) maps outline icon" {
  source "$LIB"
  batt_darwin "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=12345)	5%; discharging; 0:15 remaining present: true"
  [[ $batt == "5" ]]
  [[ $batt_icon == "󰂎" ]]
}

@test "batt_darwin: no battery output returns failure" {
  source "$LIB"
  run batt_darwin "Now drawing from 'AC Power'"
  [[ $status -ne 0 ]]
  [[ -z $batt ]]
}

@test "batt_darwin: optimized charging on AC (not charging) uses charging icon" {
  source "$LIB"
  batt_darwin "Now drawing from 'AC Power'
 -InternalBattery-0 (id=12345)	80%; not charging; 0:00 remaining present: true"
  [[ $batt == "80" ]]
  [[ $batt_icon == "󰂄" ]]
}

@test "batt_darwin: full battery on AC uses charging icon" {
  source "$LIB"
  batt_darwin "Now drawing from 'AC Power'
 -InternalBattery-0 (id=12345)	100%; charged; 0:00 remaining present: true"
  [[ $batt == "100" ]]
  [[ $batt_icon == "󰂄" ]]
}

# --- Battery icon unit tests -------------------------------------------------

@test "_batt_icon: every AC state yields the charging icon at any percentage" {
  source "$LIB"
  local s p
  for s in Charging "Not charging" Full "charged" "charging" "Finished charging"; do
    for p in 5 45 80 100; do
      [[ $(_batt_icon "$p" "$s") == "󰂄" ]]
    done
  done
}

@test "_batt_icon: discharging states fall back to the level tiers" {
  source "$LIB"
  [[ $(_batt_icon 85 Discharging) == "󰂁" ]]
  [[ $(_batt_icon 85 "discharging; 4:20 remaining") == "󰂁" ]]
  [[ $(_batt_icon 5 "discharging; 0:15 remaining") == "󰂎" ]]
}

@test "_batt_icon: unknown status with no AC data falls back to the level tiers" {
  source "$LIB"
  [[ $(_batt_icon 45 Unknown) == "󰁽" ]]
  [[ $(_batt_icon 45 "") == "󰁽" ]]
}

@test "_batt_icon: AC adapter online overrides an Unknown status" {
  source "$LIB"
  [[ $(_batt_icon 45 Unknown 1) == "󰂄" ]]
  [[ $(_batt_icon 45 Unknown 0) == "󰁽" ]]
}

@test "_batt_is_ac: classifying states" {
  source "$LIB"
  _batt_is_ac Charging
  _batt_is_ac "Not charging"
  _batt_is_ac Full
  _batt_is_ac "Unknown" 1
  ! _batt_is_ac Discharging
  ! _batt_is_ac Unknown
  ! _batt_is_ac ""
}

# --- Tab list (status-left) --------------------------------------------------

@test "tab list: uniform 2sp gaps with no bell (active first)" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  local title
  title="$(tmux display -p -t base:0 '#{pane_title}')"
  [[ "$(tab_list)" == " 0  $title  1  2 " ]]
}

@test "tab list: uniform 2sp gaps with no bell (active middle)" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  tmux select-window -t base:1
  local title
  title="$(tmux display -p -t base:1 '#{pane_title}')"
  [[ "$(tab_list)" == " 0  1  $title  2 " ]]
}

@test "tab list: uniform 2sp gaps with no bell (active last)" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  tmux select-window -t base:2
  local title
  title="$(tmux display -p -t base:2 '#{pane_title}')"
  [[ "$(tab_list)" == " 0  1  2  $title " ]]
}

@test "tab list: per-window bell dot renders inline with uniform spacing" {
  start_server
  load_conf
  tmux new-window -d -n tab2
  tmux new-window -d -n tab3
  tmux set-window -t base:1 @bell 1
  local title
  title="$(tmux display -p -t base:0 '#{pane_title}')"
  [[ "$(tab_list)" == " 0  $title  1 ●  2 " ]]
}

@test "tab list: composable @sl_tab_bell unit holds the red dot" {
  start_server
  load_conf
  local bell_unit
  bell_unit="$(opt_var @sl_tab_bell)"
  [[ $bell_unit == *'●'* ]]
  [[ $bell_unit == *'@c_red'* ]]
}

# --- Integration test --------------------------------------------------------

@test "integration: status-right renders battery block when set and hides when unset" {
  start_server
  load_conf
  tmux set-option -g @batt 85
  tmux set-option -g @batt_icon "󰂁"
  local right
  right="$(status_right)"
  [[ $right == *󰂁* ]]
  [[ $right == *85%* ]]

  tmux set-option -gu @batt
  tmux set-option -gu @batt_icon
  right="$(status_right)"
  [[ $right != *85%* ]]
}
