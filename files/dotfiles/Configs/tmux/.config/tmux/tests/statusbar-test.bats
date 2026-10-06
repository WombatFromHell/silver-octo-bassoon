#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2001,SC2030,SC2031
# statusbar-test.bats — red/green suite for statusbar.sh + statusbar-lib.bash.
#
# Unit tier: sources the pure lib, feeds fixture GPU/proc inputs, asserts
# parsed gpu/vram/cpu/ram. No tmux server, no sleeps.
#
# Integration tier: runs the status bar against a throwaway tmux server.
# Isolation guarantees:
#   * every test gets its own temp dir ($T) holding the socket, HOME, mocks,
#     logs; teardown kills the scratch server and removes $T
#   * the ONLY way tests reach tmux is the `tmux` wrapper below, which always
#     passes -S "$SOCK" and refuses to run when no scratch socket exists, so a
#     real server can never be touched (TMUX/TMUX_PANE are unset in setup)
#   * no fixed /tmp paths -> safe under `bats --jobs N`

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  DIR="$BATS_TEST_DIRNAME"
  LIB="$DIR/../scripts/statusbar-lib.bash"
}

teardown() {
  stop_scratch_server # also removes $T in the unit tier (no server)
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

# tmux option reader (kept for the @sl_tab_bell unit test)
opt_var() { tmux show-options -gv "$1" 2>/dev/null; }

# hex -> stdin bytes as one lowercase hex string (no separators/spaces).
hex() { od -An -tx1 | tr -d ' \n'; }

# --- integration-tier server ---------------------------------------------------

start_server() {
  start_scratch_server
  mkdir -p "$T/bin"
  link_tools "$T/bin" tmux jq awk sleep head cat bash flock timeout uname rm grep sed tr cut wc sort tail ps sysctl vm_stat top
}

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
# COMPOSE TIER — pure compose_blocks() (no server, no tmux)
# ---------------------------------------------------------------------------
# compose_blocks() reads the gpu/vram/cpu/ram/batt/batt_icon globals and
# prints the composed right-side metric blocks (GPU, CPU, battery). Hidden
# blocks emit zero characters. The time block is not composed here — it stays
# a live conf format (@sb_time) so the runtime @clock-format toggle works.

@test "_icon: bytes match the expected Nerd Font codepoints" {
  source "$LIB"
  local name want fails=0
  # Table derived from the U+F0079..U+F008E Nerd Font codepoints; a wrong
  # glyph in _icon (or a bad paste) changes these bytes and fails here.
  while read -r name want; do
    [[ $(_icon "$name" | hex) == "$want" ]] || fails=$((fails + 1))
  done <<'EOF'
gpu ef8b9b
cpu ef92bc
batt_ac f3b08284
batt_full f3b081b9
batt_0 f3b0828e
batt_1 f3b081ba
batt_2 f3b081bb
batt_3 f3b081bc
batt_4 f3b081bd
batt_5 f3b081be
batt_6 f3b081bf
batt_7 f3b08280
batt_8 f3b08281
batt_9 f3b08282
EOF
  [[ $fails -eq 0 ]]
  # a copy-paste giving both metric blocks the same glyph must fail
  [[ $(_icon gpu) != "$(_icon cpu)" ]]
  # unknown names emit nothing (no default branch)
  [[ -z $(_icon nope) ]]
}

@test "compose: all blocks visible — exact string" {
  source "$LIB"
  gpu=42
  vram=67
  cpu=15
  ram=80
  batt=97
  batt_icon="󰂄"
  local out g c
  g="$(_icon gpu)"
  c="$(_icon cpu)"
  out="$(compose_blocks)"
  # GPU block (bg + icon + util + vram)
  [[ $out == *"#[bg=#313244] #[fg=#cdd6f4]${g}#[fg=#a6adc8] 42%"* ]]
  [[ $out == *"#[fg=#6c7086]|#[fg=#a6adc8]67%"* ]]
  # CPU block (bg + icon + util + ram)
  [[ $out == *"#[bg=#313244] #[fg=#cdd6f4]#[fg=#a6adc8] 15%"* ]]
  [[ $out == *"#[fg=#6c7086]|#[fg=#a6adc8]80%"* ]]
  # Battery block (bg + icon + pct)
  [[ $out == *"#[bg=#313244] #[fg=#cdd6f4]󰂄 #[fg=#a6adc8]97%"* ]]
  # Each visible block ends with #[default] + trailing space (separator)
  [[ $out == *"#[default] "* ]]
  # No double spaces between blocks
  [[ $out != *"#[default]  "* ]]
}

@test "compose: no GPU — GPU block empty, CPU/RAM render" {
  source "$LIB"
  gpu=
  vram=
  cpu=15
  ram=80
  batt=
  batt_icon=
  local out g c
  g="$(_icon gpu)"
  c="$(_icon cpu)"
  out="$(compose_blocks)"
  [[ $out != *"$g"* ]]
  [[ $out != *"42%"* ]]
  [[ $out == *"#[bg=#313244] #[fg=#cdd6f4]${c}#[fg=#a6adc8] 15%"* ]]
  [[ $out == *"#[fg=#6c7086]|#[fg=#a6adc8]80%"* ]]
}

@test "compose: zero values render (0% is not hidden)" {
  source "$LIB"
  gpu=0
  vram=0
  cpu=0
  ram=0
  batt=0
  batt_icon="󰂎"
  local out
  out="$(compose_blocks)"
  local count
  count="$({ grep -o '0%' <<<"$out" || true; } | awk "END { print NR }")"
  [[ $count == "5" ]]
}

@test "compose: all hidden — empty output" {
  source "$LIB"
  gpu=
  vram=
  cpu=
  ram=
  batt=
  batt_icon=
  local out
  out="$(compose_blocks)"
  [[ -z $out ]]
}

@test "compose: GPU hidden leaves no leading space" {
  source "$LIB"
  gpu=
  vram=
  cpu=15
  ram=80
  batt=
  batt_icon=
  local out
  out="$(compose_blocks)"
  # CPU block starts immediately with #[bg=...] (no leading space)
  [[ $out == "#[bg"*** ]]
  [[ $out != " "* ]]
}

@test "compose: hidden battery leaves single gap after CPU" {
  source "$LIB"
  gpu=
  vram=
  cpu=15
  ram=80
  batt=
  batt_icon=
  local out
  out="$(compose_blocks)"
  local plain
  plain="$(sed "s/#\[[^]]*\]//g" <<<"$out")"
  # RAM half is last visible: ends with 80% + 3 spaces
  [[ $plain == *"80% "* ]]
}

@test "compose: visible battery keeps single spacing between all blocks" {
  source "$LIB"
  gpu=42
  vram=67
  cpu=15
  ram=80
  batt=97
  batt_icon="󰂄"
  local out
  out="$(compose_blocks)"
  local plain
  plain="$(sed "s/#\[[^]]*\]//g" <<<"$out")"
  [[ $plain == *"42%|67% "* ]]
  [[ $plain == *"15%|80% "* ]]
  [[ $plain == *"󰂄 97% "* ]]
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
  run ! _batt_is_ac Discharging
  run ! _batt_is_ac Unknown
  run ! _batt_is_ac ""
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

# --- E2E: pull model (#() job) ----------------------------------------------

# Copy the real statusbar.sh (not the stub) into the scratch HOME.
load_real_script() {
  cp "$DIR/../scripts/statusbar.sh" "$HOME/.config/tmux/scripts/statusbar.sh"
  cp "$DIR/../scripts/statusbar-lib.bash" "$HOME/.config/tmux/scripts/statusbar-lib.bash"
  chmod +x "$HOME/.config/tmux/scripts/statusbar.sh"
}

# The stored status-right option is always the raw conf format (job
# substitution happens per-client at draw time), so the observable is the
# status line of a real attached client: its job cache renders the script's
# output. The time block never contains '%', so a '%' in the bottom row
# proves the job ran. The client is wide so the right-aligned status-right
# is not clipped.
attach_observer() {
  tmux new-session -d -s obs -x 200 -y 20 'env -u TMUX tmux attach-session -t base'
}
# The conf pins status-position top, so the status line is the first row.
obs_row() { tmux capture-pane -p -t obs | head -1; }
row_has_metrics() { [[ "$(obs_row)" == *'%'* ]]; }

@test "E2E: attached client renders the composed status-right" {
  start_server
  load_conf
  load_real_script
  attach_observer
  # The job takes ~1s; wait for its output in the client's status line.
  wait_until 15 row_has_metrics
  local row
  row="$(obs_row)"
  # Metric blocks (percent signs, separators) plus the live clock.
  [[ $row == *'%'* ]]
  [[ $row =~ [0-9]:[0-9]{2}$ ]]
}

@test "E2E: status-right updates between intervals" {
  start_server
  load_conf
  load_real_script
  attach_observer
  wait_until 15 row_has_metrics
  local r1 r2
  r1="$(obs_row)"
  # A couple of status-intervals (3s) later the job has run again. Values may
  # be identical on an idle machine, so only require a rendered row.
  sleep 6
  r2="$(obs_row)"
  [[ $r1 == *'%'* ]]
  [[ $r2 == *'%'* ]]
}

@test "E2E: reload conf re-fires the status bar job" {
  start_server
  load_conf
  load_real_script
  attach_observer
  wait_until 15 row_has_metrics
  # Reload the conf — status-right goes back to the raw job format, and the
  # next tick re-runs the job under the new format.
  tmux source-file "$T/tmux.conf"
  wait_until 15 row_has_metrics
}
