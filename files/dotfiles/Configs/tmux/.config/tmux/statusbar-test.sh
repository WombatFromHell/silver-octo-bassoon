#!/usr/bin/env bash
# statusbar-test.sh — red/green test for statusbar.sh (GPU/CPU/RAM env vars).
#
# Verifies, against a throwaway tmux server:
#   T1  no GPU tool in PATH        -> CPU/RAM set, GPU_UTIL/VRAM unset
#   T2  mock nvidia-smi (ok)       -> GPU_UTIL/VRAM set
#   T3  mock nvidia-smi (broken)   -> GPU_UTIL/VRAM unset, CPU/RAM still set
#   T4  real amd-smi (this box)    -> GPU_UTIL/VRAM set
#   T5  mock xpu-smi (Intel dGPU)  -> GPU_UTIL/VRAM set
#   T6  mock intel_gpu_top (Intel)  -> GPU_UTIL set, VRAM unset
#   T7  server killed mid-loop      -> loop exits, flock released
#   T8  status-right format         -> GPU/CPU blocks render per env vars
#
# Uses a throwaway server socket so it never touches your real sessions.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKDIR="$(mktemp -d /tmp/tmux-statusbar-test-XXXXXX)"
export TMUX_TMPDIR="$SOCKDIR"
export TMUX="$SOCKDIR/tmux-$(id -u)"
# Empty HOME: the scratch server must NOT load the user's tmux.conf, whose
# `run -b 'bash ~/.config/tmux/statusbar.sh'` spawns a real loop (full PATH,
# real flock + amd-smi) that competes for the lock and pollutes the scratch
# server's env vars. (This tmux build loads the user conf even with
# `new-session -f /dev/null`.) T8 sources the conf by absolute path, so the
# conf's `~/.config/tmux/statusbar.sh` resolves against the empty HOME and
# spawns no loop there.
export HOME="$SOCKDIR/home"
mkdir -p "$HOME"

# Resolve the tmux binary BEFORE defining the tmux() wrapper: `command -v`
# on a shell function returns the bare name, which would make the BASEBIN
# symlink circular (tmux -> tmux).
TMUX_BIN="$(command -v tmux)"
tmux() { command "$TMUX_BIN" "$@"; }

# A pre-existing statusbar loop (from a real server) holds the flock; the
# test's own instances would then silently exit. Refuse to run in that case.
if pgrep -f 'statusbar\.sh' >/dev/null 2>&1; then
  echo "ABORT: a statusbar.sh loop is already running (holds the flock)." >&2
  echo "       Stop your tmux server and re-run." >&2
  exit 2
fi

# Base bin dir: the minimal toolset statusbar.sh needs, with NO GPU tools.
# (amd-smi lives in /usr/bin here, so /usr/bin must not be on these PATHs.)
BASEBIN="$(mktemp -d /tmp/tmux-statusbar-bin-XXXXXX)"
ln -s "$TMUX_BIN" "$BASEBIN/tmux"
for b in jq awk sleep head cat bash flock; do
  ln -s "$(command -v "$b")" "$BASEBIN/$b"
done

MOCKDIR=""
SCRIPT_PID=""
cleanup() {
  kill_script
  [[ -n $MOCKDIR ]] && rm -rf "$MOCKDIR"
  rm -rf "$BASEBIN"
  tmux kill-server 2>/dev/null || true
  rm -rf "$SOCKDIR"
}
trap cleanup EXIT

pass=0 fail=0
check() { # desc  actual  expected
  if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (got "%s", want "%s")\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
check_contains() { # desc  needle  haystack
  if [[ "$3" == *"$2"* ]]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (missing "%s" in "%s")\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
check_not_contains() { # desc  needle  haystack
  if [[ "$3" != *"$2"* ]]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (unexpected "%s" in "%s")\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
env_gpu() { tmux show-environment -g 2>/dev/null | sed -n 's/^GPU_UTIL=//p'; }
env_vram()  { tmux show-environment -g 2>/dev/null | sed -n 's/^VRAM=//p'; }
env_cpu()   { tmux show-environment -g 2>/dev/null | sed -n 's/^CPU=//p'; }
env_ram()   { tmux show-environment -g 2>/dev/null | sed -n 's/^RAM=//p'; }
is_num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
check_num() { # desc  envvar
  local v
  v="$(tmux show-environment -g 2>/dev/null | sed -n "s/^$2=//p")"
  if is_num "$v"; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL  %s  (got "%s", want numeric)\n' "$1" "$v"; fail=$((fail+1)); fi
}

# Kill the whole process tree rooted at $1 (children inherit fd 9 and would
# keep holding the flock after the script itself dies).
kill_tree() {
  local p c
  for p in "$@"; do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
    kill "$p" 2>/dev/null || true
  done
}

kill_script() {
  [[ -n $SCRIPT_PID ]] || return 0
  kill_tree "$SCRIPT_PID"
  wait "$SCRIPT_PID" 2>/dev/null || true
  SCRIPT_PID=""
  # Wait until the flock is actually free: the loop's `sleep` children inherit
  # fd 9 and a fresh one can be spawned after kill_tree's pgrep snapshot,
  # outliving the kill by up to 2s and blocking the next case's flock.
  for _ in $(seq 1 20); do
    bash -c 'exec 9>/tmp/tmux-statusbar.lock; flock -n 9' 2>/dev/null && break
    sleep 0.3
  done
}

# -f /dev/null: skip the user's tmux.conf, whose `run -b statusbar.sh`
# would spawn a real loop (full PATH, real flock + amd-smi) competing for
# the lock and polluting the scratch server's env vars.
start_server() {
  kill_script
  tmux kill-server 2>/dev/null || true
  sleep 0.3
  tmux new-session -f /dev/null -d -s base
}

# Run one iteration of statusbar.sh against the scratch server with $1 as PATH.
run_case() { # path
  SCRIPT_PID="$(env PATH="$1" TMUX="$TMUX" bash "$DIR/statusbar.sh" >/dev/null 2>&1 & echo $!)"
  sleep 6
}

# --- T1: no GPU tool -> CPU/RAM set, GPU vars unset --------------------------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
start_server
run_case "$MOCKDIR:$BASEBIN"
check_num  "T1 CPU set"    CPU
check_num  "T1 RAM set"    RAM
check "T1 GPU unset"  "$(env_gpu)"  ""
check "T1 VRAM unset" "$(env_vram)" ""

# --- T2: mock nvidia-smi (ok) -> GPU_UTIL=12, VRAM=6 (550*100/8192) -----------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
printf '#!/bin/sh\necho "12, 550, 8192"\n' > "$MOCKDIR/nvidia-smi"
chmod +x "$MOCKDIR/nvidia-smi"
start_server
run_case "$MOCKDIR:$BASEBIN"
check "T2 GPU_UTIL=12" "$(env_gpu)"  "12"
check "T2 VRAM=6"      "$(env_vram)" "6"
check_num "T2 CPU set"     CPU

# --- T3: mock nvidia-smi (broken) -> GPU vars unset, CPU/RAM still set --------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
printf '#!/bin/sh\necho "NVIDIA-SMI has failed" >&2\nexit 1\n' > "$MOCKDIR/nvidia-smi"
chmod +x "$MOCKDIR/nvidia-smi"
start_server
run_case "$MOCKDIR:$BASEBIN"
check "T3 GPU unset"  "$(env_gpu)"  ""
check "T3 VRAM unset" "$(env_vram)" ""
check_num "T3 CPU set"    CPU
check_num "T3 RAM set"    RAM

# --- T4: real amd-smi (this box) -> GPU_UTIL/VRAM numeric --------------------
MOCKDIR=""
start_server
run_case "/usr/bin:$BASEBIN"
check_num "T4 GPU numeric" GPU_UTIL
check_num "T4 VRAM numeric" VRAM

# --- T5: mock xpu-smi (Intel dGPU) -> GPU_UTIL=37, VRAM=42 (floored) ----------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
cat > "$MOCKDIR/xpu-smi" <<'EOF'
#!/bin/sh
echo '{"device_id":0,"device_level":[{"metrics_type":"XPUM_STATS_GPU_UTILIZATION","value":37.5},{"metrics_type":"XPUM_STATS_MEMORY_UTILIZATION","value":42.1},{"metrics_type":"XPUM_STATS_POWER","value":45.0}]}'
EOF
chmod +x "$MOCKDIR/xpu-smi"
start_server
run_case "$MOCKDIR:$BASEBIN"
check "T5 GPU_UTIL=37" "$(env_gpu)"  "37"
check "T5 VRAM=42"     "$(env_vram)" "42"
check_num "T5 CPU set"     CPU

# --- T6: mock intel_gpu_top (Intel iGPU) -> GPU_UTIL=12, VRAM unset ------------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
cat > "$MOCKDIR/intel_gpu_top" <<'EOF'
#!/bin/sh
echo '{"period":{"duration":1000,"unit":"ms"},"engines":{"Render/3D/0":{"busy":12.5,"sema":0,"wait":0,"unit":"%"},"Blitter/0":{"busy":1.0,"sema":0,"wait":0,"unit":"%"}},"clients":[]}'
EOF
chmod +x "$MOCKDIR/intel_gpu_top"
start_server
run_case "$MOCKDIR:$BASEBIN"
check "T6 GPU_UTIL=12" "$(env_gpu)"  "12"
check "T6 VRAM unset"  "$(env_vram)" ""
check_num "T6 CPU set"     CPU

# --- T7: server killed mid-loop -> loop exits, flock released ------------------
MOCKDIR="$(mktemp -d /tmp/tmux-statusbar-mock-XXXXXX)"
start_server
run_case "$MOCKDIR:$BASEBIN"
check_num "T7 loop was live" CPU
tmux kill-server
for _ in $(seq 1 12); do
  kill -0 "$SCRIPT_PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$SCRIPT_PID" 2>/dev/null; then
  check "T7 loop exits when server dies" "alive" "dead"
else
  check "T7 loop exits when server dies" "dead" "dead"
  kill_script
fi

# --- T8: status-right rendering from the real tmux.conf format -----------------
MOCKDIR=""
start_server
# source-file by absolute path installs the real palette + status-right.
# The conf's `run -b 'bash ~/.config/tmux/statusbar.sh'` resolves ~ against
# the empty test HOME, so no competing loop is spawned here.
tmux source-file "$DIR/tmux.conf"
sleep 1

tmux set-environment -g GPU_UTIL 42
tmux set-environment -g VRAM 67
tmux set-environment -g CPU 15
tmux set-environment -g RAM 80
right="$(tmux display -p -t base:1 -F '#{T;=/60:status-right}')"
check_contains "T8a GPU block renders"  "42%"  "$right"
check_contains "T8a VRAM renders"       "67%"  "$right"
check_contains "T8a CPU block renders"  "15%"  "$right"
check_contains "T8a RAM renders"        "80%"  "$right"

tmux set-environment -g -u GPU_UTIL
tmux set-environment -g -u VRAM
right="$(tmux display -p -t base:1 -F '#{T;=/60:status-right}')"
check_not_contains "T8b GPU block hidden" "42%"  "$right"
check_not_contains "T8b GPU icon hidden"  "󰘚"  "$right"
check_contains     "T8b CPU block still renders" "15%" "$right"

# T8c: GPU set but VRAM unset (Intel iGPU) -> no dangling '|' after GPU %.
# (Strip the literal #[...] style tags display -F leaves in its output:
# the '|' is wrapped in #[fg=...] codes, so the raw expansion can never
# contain the literal "42%|".)
tmux set-environment -g GPU_UTIL 42
right="$(tmux display -p -t base:1 -F '#{T;=/60:status-right}' | sed -e 's/#\[[^]]*\]//g')"
check_contains     "T8c GPU % renders" "42%" "$right"
check_not_contains "T8c no dangling pipe" "42%|" "$right"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
exit $(( fail > 0 ))
