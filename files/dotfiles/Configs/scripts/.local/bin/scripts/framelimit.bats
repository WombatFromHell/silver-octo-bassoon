#!/usr/bin/env bats
# Tests for framelimit.sh
#
# Argument order under test: [FLAGS] [<fps>] -- [command]
#   FLAGS: --dry-run|-n, --vkd3d, --dxvk   (flags always come first)
#
# Run with:  bats framelimit.bats

setup() {
  SCRIPT="$(dirname "$BATS_TEST_FILENAME")/framelimit.sh"
}

# Helper: run framelimit.sh in --dry-run mode and capture output.
run_dry() {
  run "$SCRIPT" --dry-run "$@"
}

# --- mangohud vs direct exec (core behavior) ---

@test "no flags: mangohud runs with MANGOHUD env vars" {
  run_dry 60 -- true
  [[ $output == *'MANGOHUD=1'* ]]
  [[ $output == *'MANGOHUD_CONFIG=read_cfg,vsync=3,fps_limit_method=early,fps_limit=60'* ]]
  [[ $output != *'VKD3D_CONFIG'* ]]
  [[ $output != *'VKD3D_FRAME_RATE'* ]]
  [[ $output != *'DXVK_CONFIG'* ]]
  [[ $output == *'true'* ]]
}

@test "--vkd3d: engine vars set, mangohud NOT run" {
  run_dry --vkd3d 60 -- true
  [[ $output == *'VKD3D_CONFIG=frame_rate_limit=60'* ]]
  [[ $output == *'VKD3D_FRAME_RATE=60'* ]]
  [[ $output != *'MANGOHUD'* ]]
  [[ $output == *'true'* ]]
}

@test "--dxvk: engine vars set, mangohud NOT run" {
  run_dry --dxvk 60 -- true
  [[ $output == *'DXVK_CONFIG=dxgi.maxFrameRate=60;d3d9.maxFrameRate=60'* ]]
  [[ $output != *'MANGOHUD'* ]]
  [[ $output != *'VKD3D_CONFIG'* ]]
  [[ $output == *'true'* ]]
}

@test "both flags: both engine vars set, mangohud NOT run" {
  run_dry --vkd3d --dxvk 60 -- true
  [[ $output == *'VKD3D_CONFIG=frame_rate_limit=60'* ]]
  [[ $output == *'VKD3D_FRAME_RATE=60'* ]]
  [[ $output == *'DXVK_CONFIG=dxgi.maxFrameRate=60;d3d9.maxFrameRate=60'* ]]
  [[ $output != *'MANGOHUD'* ]]
}

@test "dry-run output is a single runnable command line (env <vars> <cmd>)" {
  run_dry 60 -- true
  [[ $output == env* ]]
  local line_count
  line_count=$(wc -l <<<"$output")
  [[ $line_count -eq 1 ]]
}

# --- argument parsing ---

@test "-n is an alias for --dry-run" {
  run "$SCRIPT" -n 60 -- true
  [[ $output == *'MANGOHUD=1'* ]]
}

@test "--help prints usage (MangoHUD is the default) and exits 0" {
  run "$SCRIPT" --help
  [[ $status -eq 0 ]]
  [[ $output == *'Usage:'* ]]
  [[ $output == *'Default: MangoHUD mode'* ]]
  [[ $output == *'--vkd3d'* ]]
  [[ $output == *'--dxvk'* ]]
}

@test "defaults to 60 fps when no fps is given" {
  run_dry -- true
  [[ $output == *'fps_limit=60'* ]]
}

@test "invalid fps is rejected" {
  run_dry abc -- true
  [[ $status -ne 0 ]]
}

@test "missing '--' delimiter is rejected" {
  run_dry 60 true
  [[ $status -ne 0 ]]
}

@test "missing command after '--' is rejected" {
  run_dry --
  [[ $status -ne 0 ]]
}

@test "unknown flag is rejected" {
  run_dry --foo 60 -- true
  [[ $status -ne 0 ]]
}

# --- non-destructive: preserve pre-set env vars ---

@test "vkd3d: preserves a pre-set VKD3D_CONFIG and appends non-destructively" {
  export VKD3D_CONFIG="frame_rate_limit=144"
  run_dry --vkd3d 60 -- true
  [[ $output == *'VKD3D_CONFIG=frame_rate_limit=144,frame_rate_limit=60'* ]]
}

@test "vkd3d: preserves a pre-set VKD3D_FRAME_RATE (non-destructive)" {
  export VKD3D_FRAME_RATE=144
  run_dry --vkd3d 60 -- true
  [[ $output == *'VKD3D_FRAME_RATE=144'* ]]
  [[ $output != *'VKD3D_FRAME_RATE=60'* ]]
}

@test "dxvk: preserves a pre-set DXVK_CONFIG and appends non-destructively" {
  export DXVK_CONFIG="dxgi.maxFrameRate=144"
  run_dry --dxvk 60 -- true
  [[ $output == *'DXVK_CONFIG=dxgi.maxFrameRate=144;dxgi.maxFrameRate=60;d3d9.maxFrameRate=60'* ]]
}

@test "mangohud: preserves a pre-set MANGOHUD_CONFIG (existing behavior)" {
  export MANGOHUD_CONFIG="frame=30"
  run_dry 60 -- true
  [[ $output == *'MANGOHUD_CONFIG=frame=30,vsync=3,fps_limit_method=early,fps_limit=60'* ]]
}

@test "repeated identical config is not duplicated (idempotent)" {
  export DXVK_CONFIG="dxgi.maxFrameRate=60;d3d9.maxFrameRate=60"
  run_dry --dxvk 60 -- true
  local count
  count=$(grep -o 'dxgi.maxFrameRate=60' <<<"$output" | wc -l)
  [[ $count -eq 1 ]]
}
