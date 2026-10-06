#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2001,SC2030,SC2031
# statusbar-unit-test.bats — unit tier for statusbar-lib.bash: pure
# parse/compute tests (gpu providers, cpu/ram, darwin fixtures, _icon,
# compose_metrics/_sb_time, battery). No tmux server, no sleeps.

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

# Minimal PATH for call_gpu's subshell: only what gpu_read + mocks exec
# under $T/mock:$T/bin (cat runs the amd-smi mock heredoc; timeout/gtimeout
# are _tout). Everything else resolves from the normal test PATH.
init_unit_bin() {
  ensure_tmp
  mkdir -p "$T/bin"
  link_tools "$T/bin" jq head cat timeout gtimeout
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

@test "amd: broken output leaves gpu/vram empty" {
  make_mock amd-smi '#!/bin/sh
echo "not json"'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "amd: zero total VRAM is rejected" {
  make_mock amd-smi '#!/bin/sh
cat <<JSON
{"gpu_data":[{"usage":{"gfx_activity":{"value":41.7}},"mem_usage":{"used_vram":{"value":3000},"total_vram":{"value":0}}}]}]
JSON'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "intel dGPU: parses utilization and memory, floors" {
  make_mock xpu-smi '#!/bin/sh
echo '\''{"device_id":0,"device_level":[{"metrics_type":"XPUM_STATS_GPU_UTILIZATION","value":37.5},{"metrics_type":"XPUM_STATS_MEMORY_UTILIZATION","value":42.1},{"metrics_type":"XPUM_STATS_POWER","value":45.0}]}'\'''
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "37" ]]
  [[ $vram == "42" ]]
}

@test "intel dGPU: broken output leaves gpu empty" {
  make_mock xpu-smi '#!/bin/sh
echo "not json"'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "intel iGPU: max engine busy, no vram" {
  make_mock intel_gpu_top '#!/bin/sh
echo '\''{"period":{"duration":1000,"unit":"ms"},"engines":{"Render/3D/0":{"busy":12.5,"sema":0,"wait":0,"unit":"%"},"Blitter/0":{"busy":1.0,"sema":0,"wait":0,"unit":"%"}},"clients":[]}'\'''
  read -r gpu vram <<<"$(call_gpu)"
  [[ $gpu == "12" ]]
  [[ -z $vram ]]
}

@test "intel iGPU: broken output leaves gpu empty" {
  make_mock intel_gpu_top '#!/bin/sh
echo "garbage"'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "gpu_read: no GPU tool -> empty" {
  make_mock noop '#!/bin/sh
exit 1'
  read -r gpu vram <<<"$(call_gpu)"
  [[ -z $gpu ]]
  [[ -z $vram ]]
}

@test "_sb_clock_fmt: 12/24-hour mapping" {
  source "$LIB"
  [[ $(_sb_clock_fmt 12) == "%I:%M %p" ]]
  [[ $(_sb_clock_fmt 24) == "%H:%M" ]]
  [[ $(_sb_clock_fmt '') == "%H:%M" ]]
  [[ $(_sb_clock_fmt garbage) == "%H:%M" ]]
}

@test "compose: bare clock pre-data (no metrics)" {
  source "$LIB"
  gpu= vram= cpu= ram= batt= batt_icon= date_str= clock=07:19
  out=$(compose_metrics)$(_sb_time)
  [[ $out == "#[fg=#6c7086]07:19 #[default]" ]]
}

@test "compose: decorated calendar+clock ready (exact)" {
  source "$LIB"
  gpu= vram= cpu= ram= batt= batt_icon= date_str=07.06 clock=07:19
  out=$(compose_metrics)$(_sb_time 1)
  [[ $out == "#[bg=#313244] #[fg=#cdd6f4]$(_icon cal)#[fg=#a6adc8] 07.06 #[fg=#6c7086]|#[default]#[bg=#313244] #[fg=#cdd6f4]$(_icon clock) #[fg=#a6adc8]07:19 #[default]" ]]
}

@test "compose: time block present even with all metrics hidden" {
  source "$LIB"
  gpu= vram= cpu= ram= batt= batt_icon= date_str=07.06 clock=07:19
  out=$(compose_metrics)$(_sb_time 1)
  [[ $out == *"07.06"* ]]
  [[ $out == *"07:19"* ]]
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
2026-10-04 12:00:00
Load Avg: 1.00, 1.00, 1.00
CPU usage: 40.00% user, 30.00% sys, 30.00% idle
SharedLibs: 500M resident, 100M data, 50M linkedit.
Processes: 500 total, 2 running, 498 sleeping, 2500 threads
2026-10-04 12:00:01
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
# COMPOSE TIER — pure compose_metrics() + _sb_time() (no server, no tmux)
# ---------------------------------------------------------------------------
# compose_metrics() reads the gpu/vram/cpu/ram/batt/batt_icon globals and
# prints the right-side metric blocks (GPU, CPU, battery); hidden blocks emit
# zero characters. _sb_time() adds the time block from date_str/clock; the
# tests call both, mirroring how statusbar.sh composes its output.

@test "_icon: bytes match the expected Nerd Font codepoints" {
  source "$LIB"
  local name want fails=0
  # Table derived from the U+F0079..U+F008E Nerd Font codepoints; a wrong
  # glyph in _icon (or a bad paste) changes these bytes and fails here.
  while read -r name want; do
    [[ $(_icon "$name" | od -An -tx1 | tr -d ' \n') == "$want" ]] || fails=$((fails + 1))
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
cal ef9195
clock ef8097
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
  out="$(compose_metrics)$(_sb_time)"
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
  out="$(compose_metrics)$(_sb_time)"
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
  out="$(compose_metrics)$(_sb_time)"
  local count
  count="$(grep -o '0%' <<<"$out" | wc -l)"
  [[ $count == "5" ]]
}

@test "compose: all hidden — only time block" {
  source "$LIB"
  gpu=
  vram=
  cpu=
  ram=
  batt=
  batt_icon=
  date_str=07.06
  clock=07:19
  local out
  out="$(compose_metrics)$(_sb_time)"
  [[ $out == "#[fg=#6c7086]07:19 #[default]" ]]
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
  out="$(compose_metrics)$(_sb_time)"
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
  out="$(compose_metrics)$(_sb_time)"
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
  out="$(compose_metrics)$(_sb_time)"
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
