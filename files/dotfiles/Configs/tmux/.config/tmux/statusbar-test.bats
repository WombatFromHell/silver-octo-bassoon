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
  LIB="$DIR/statusbar-lib.bash"
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

# make_mock NAME CONTENT -> executable in $T/mock, alongside the few real
# utilities the lib needs. Call start_server first if CONTENT references $T.
make_mock() {
  ensure_tmp
  mkdir -p "$T/mock"
  link_tools "$T/mock" jq head sleep timeout cat
  rm -f "$T/mock/$1" # never write through a symlink to a real binary
  printf '%s' "$2" >"$T/mock/$1"
  chmod +x "$T/mock/$1"
}

# Unit tier: gpu_read on a clean PATH (mockdir only, no real GPU tools).
call_gpu() {
  (
    export PATH="$T/mock"
    source "$LIB"
    gpu_read
    printf '%s %s' "$gpu" "$vram"
  )
}

# Poll helpers: replace every fixed sleep.
env_var() { tmux show-environment -g "$1" 2>/dev/null | sed -n "s/^$1=//p"; }
env_is() { [[ "$(env_var "$1")" =~ $2 ]]; }
wait_env() { wait_until 5 env_is "$@"; } # VAR REGEX
is_dead() { ! kill -0 "$1" 2>/dev/null; }
# The shim logs once per loop iteration, so a non-empty log == iteration 1 done.
wait_iteration() { wait_until 5 test -s "$T/sleep.log"; }
first_sleep_arg() { head -n1 "$T/sleep.log"; }

# --- integration-tier server ---------------------------------------------------

# Shared scratch server, plus the minimal PATH dir the consumer runs under.
start_server() {
  start_scratch_server
  mkdir -p "$T/bin"
  link_tools "$T/bin" tmux jq awk sleep head cat bash flock timeout uname rm
}

# start_consumer [ENV=VAL ...]
start_consumer() {
  ensure_tmp
  make_mock sleep "#!/bin/sh
echo \"\$1\" >> '$T/sleep.log'
exec '$REAL_SLEEP' 0.05"
  env PATH="$T/mock:$T/bin" TMUX="$SOCK,0,0" "$@" \
    bash "$DIR/statusbar.sh" >/dev/null 2>&1 3>&- &
  SCRIPT_PID=$!
}

status_right() { tmux display-message -p -t base "$(tmux show-options -gv status-right)"; }

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

@test "integration: cold start seeds 0 placeholders while first GPU fetch is in flight" {
  start_server
  # Mock blocks until $T/release exists, then echoes. Bounded by a 5s cap
  # so the test doesn't hang even without timeout(1).
  make_mock nvidia-smi "#!/bin/sh
i=0
while [ ! -e '$T/release' ] && [ \$i -lt 100 ]; do
  sleep 0.05; i=\$((i+1))
done
echo '12, 550, 8192'"
  start_consumer
  wait_env CPU '^0$'
  wait_env RAM '^0$'
  wait_env GPU_UTIL '^0$'
  wait_env VRAM '^0$'
  : >"$T/release"
  wait_env GPU_UTIL '^12$'
  wait_env VRAM '^6$'
}

@test "integration: no GPU tool sets CPU/RAM, unsets GPU/VRAM" {
  start_server
  start_consumer
  wait_iteration
  [[ "$(env_var CPU)" =~ ^[0-9]+$ ]]
  [[ "$(env_var RAM)" =~ ^[0-9]+$ ]]
  [[ -z "$(env_var GPU_UTIL)" ]]
  [[ -z "$(env_var VRAM)" ]]
}

@test "integration: mock nvidia-smi sets GPU_UTIL and VRAM" {
  start_server
  make_mock nvidia-smi '#!/bin/sh
echo "12, 550, 8192"'
  start_consumer
  wait_env GPU_UTIL '^12$'
  wait_env VRAM '^6$'
  [[ "$(env_var CPU)" =~ ^[0-9]+$ ]]
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
  [[ "$(first_sleep_arg)" == "3" ]]
}

@test "integration: STATUSBAR_REFRESH is honored" {
  start_server
  start_consumer STATUSBAR_REFRESH=2
  wait_iteration
  [[ "$(first_sleep_arg)" == "2" ]]
}

@test "integration: status-right renders GPU/CPU blocks from env vars" {
  start_server
  load_conf
  tmux set-environment -g GPU_UTIL 42
  tmux set-environment -g VRAM 67
  tmux set-environment -g CPU 15
  tmux set-environment -g RAM 80
  local right
  right="$(status_right)"
  [[ $right == *42%* ]]
  [[ $right == *67%* ]]
  [[ $right == *15%* ]]
  [[ $right == *80%* ]]
}

@test "integration: status-right hides GPU block when GPU_UTIL unset" {
  start_server
  load_conf
  tmux set-environment -g GPU_UTIL 42
  tmux set-environment -g CPU 15
  tmux set-environment -g RAM 80
  local right
  right="$(status_right)"
  [[ $right == *42%* ]]
  [[ $right == *15%* ]]
  tmux set-environment -g -u GPU_UTIL
  tmux set-environment -g -u VRAM
  right="$(status_right)"
  [[ $right != *42%* ]]
  [[ $right == *15%* ]]
}

@test "integration: status-right renders four 0% placeholders when seeded 0" {
  start_server
  load_conf
  tmux set-environment -g GPU_UTIL 0
  tmux set-environment -g VRAM 0
  tmux set-environment -g CPU 0
  tmux set-environment -g RAM 0

  local right count
  right="$(status_right | sed -e 's/#\[[^]]*\]//g')"

  count="$({ grep -o '0%' <<<"$right" || true; } | awk 'END { print NR }')"
  [[ $count == "4" ]]
}

@test "integration: Darwin branch fills CPU/RAM from top/vm_stat (pidfile lock, no flock)" {
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
  wait_env CPU '^15$'
  wait_env RAM '^52$'
  [[ "$(<"$SOCK,0,0-statusbar.lock")" == "$SCRIPT_PID" ]]
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
  start_server
  rm -f "$T/bin/flock"
  echo 999999 >"$SOCK,0,0-statusbar.lock"
  start_consumer
  wait_env CPU '^[0-9]+$'
  wait_iteration
  [[ "$(<"$SOCK,0,0-statusbar.lock")" == "$SCRIPT_PID" ]]
}
