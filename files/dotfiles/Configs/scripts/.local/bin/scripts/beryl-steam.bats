#!/usr/bin/env bats
# Tests for beryl-steam.sh
#
# Contract under test: [MODE] [-- <args>]
#   MODE: (empty) plain | tenfoot | nested
#   <args> after -- are launcher passthrough: they end up in the steam
#   arguments in plain/tenfoot, and in the gamescope arguments in nested.
#
# Run with: bats beryl-steam.bats
#
# Stubs keep the test hermetic: PATH holds only the stub bin plus /usr/bin and
# /bin, so the real ~/.local/bin/scripts entries (bazzite-steam.sh, bazzite-steam,
# steam, nscb, gamemode) can never resolve. Real Steam is running on this
# machine, so pgrep/pkill/steam are stubbed too: the script must not signal or
# launch the live client. DRM_SYS_PATH points at an empty directory so hybrid
# detection is off, and niri answers with fixed JSON.
# The TV-connected (HDR) path is not covered here: it runs the real lgc1-wold.py
# wrapper, which needs the compositor. That path is verified by hand.

setup() {
  SCRIPT="$(dirname "$BATS_TEST_FILENAME")/beryl-steam.sh"
  STUBS="$(mktemp -d)"
  BIN="$STUBS/bin"
  mkdir -p "$BIN" "$STUBS/run" "$STUBS/empty-drm"

  # steam reports the arguments it received, then stops.
  cat >"$BIN/steam" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'STEAM_ARG %s\n' "$a"; done
printf 'STEAM_COUNT %s\n' "$#"
printf 'ENV_PROTON %s\n' "${PROTON_ENABLE_WAYLAND:-unset}"
EOF

  # nscb reports its arguments, then hands off to steam. Real gamescope passes
  # everything after "--" to the wrapped command, so the stub splits there too.
  cat >"$BIN/nscb" <<'EOF'
#!/usr/bin/env bash
while ((${#})) && [[ $1 != -- ]]; do printf 'GAMESCOPE_ARG %s\n' "$1"; shift; done
shift
exec "$@"
EOF

  # gamemode is a pre-launch wrapper: it consumes its "--" terminator.
  cat >"$BIN/gamemode" <<'EOF'
#!/usr/bin/env bash
printf 'GAMEMODE\n'
[ "$1" = -- ] && shift
exec "$@"
EOF

  # niri answers the one query the script makes, from NIRI_JSON.
  cat >"$BIN/niri" <<'EOF'
#!/usr/bin/env bash
cat "$NIRI_JSON"
EOF

  # No Steam is running, and nothing may signal a real process.
  # Nothing may signal or notify the live desktop: pgrep reports "no Steam",
  # pkill is a no-op, notify-send is swallowed.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BIN/pgrep"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/pkill"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/notify-send"

  # The launcher resolves Steam through command -v, trying these three names
  # in order. All three must be stubs, or a test would start the real client.
  for name in bazzite-steam.sh bazzite-steam; do
    printf '#!/usr/bin/env bash\nexec steam "$@"\n' >"$BIN/$name"
  done

  chmod +x "$BIN"/*

  export PATH="$BIN:/usr/bin:/bin"
  export XDG_RUNTIME_DIR="$STUBS/run"
  export DRM_SYS_PATH="$STUBS/empty-drm"
}

cleanup() {
  rm -rf "$STUBS"
}

# --- plain mode: the launcher passthrough contract (goal 1) ---

@test "plain: one URI after -- reaches steam unchanged" {
  run "$SCRIPT" -- 'steam://open/bigpicture'
  [[ $status -eq 0 ]]
  [[ $output == *"STEAM_ARG steam://open/bigpicture"* ]]
  [[ $output == *"STEAM_COUNT 1"* ]]
  [[ $output == *"ENV_PROTON unset"* ]]
}

@test "plain: no arguments means steam gets nothing" {
  run "$SCRIPT"
  [[ $status -eq 0 ]]
  [[ $output == *"STEAM_COUNT 0"* ]]
}

@test "plain: a URI containing -- is not eaten as the separator" {
  run "$SCRIPT" -- 'steam://rungame/730/123/--x'
  [[ $status -eq 0 ]]
  [[ $output == *"STEAM_ARG steam://rungame/730/123/--x"* ]]
  [[ $output == *"STEAM_COUNT 1"* ]]
}

@test "log tags and usage name the real file" {
  run "$SCRIPT" tenfoot
  [[ $output == *"[beryl-steam-tenfoot]"* ]]
  run "$SCRIPT" bpm
  [[ $output == *"Usage: beryl-steam.sh"* ]]
}

# --- tenfoot: mode flags first, passthrough last ---

@test "tenfoot: gamemode wrapper runs, passthrough follows the mode flags" {
  run "$SCRIPT" tenfoot -- a b
  [[ $status -eq 0 ]]
  [[ $output == *"GAMEMODE"* ]]
  [[ $output == *"STEAM_ARG -tenfoot"* ]]
  [[ $output == *"STEAM_ARG -pipewire"* ]]
  [[ $output == *"STEAM_ARG a"* ]]
  [[ $output == *"STEAM_COUNT 4"* ]]
}

# --- nested: passthrough goes to gamescope, not to steam ---

@test "nested: passthrough lands in gamescope args, steam keeps only mode flags" {
  NIRI_JSON="$STUBS/dp.json"
  cat >"$NIRI_JSON" <<'EOF'
{"DP-1": {"current_mode": {"width": 1920, "height": 1080}, "make": "Dell", "model": "U2723QE", "serial": "x"}}
EOF
  export NIRI_JSON
  run "$SCRIPT" nested -- a b
  [[ $status -eq 0 ]]
  [[ $output == *"GAMESCOPE_ARG -p"* ]]
  [[ $output == *"GAMESCOPE_ARG tenfoot,hdr"* ]]
  [[ $output == *"GAMESCOPE_ARG a"* ]]
  [[ $output == *"STEAM_ARG -tenfoot"* ]]
  [[ $output == *"STEAM_ARG -steamos3"* ]]
  [[ $output == *"STEAM_COUNT 2"* ]]
  [[ $output == *"ENV_PROTON 1"* ]]
}

@test "nested: DP-only monitor selects SDR profile and no TV wrapper" {
  NIRI_JSON="$STUBS/dp.json"
  cat >"$NIRI_JSON" <<'EOF'
{"DP-1": {"current_mode": {"width": 1920, "height": 1080}, "make": "Dell", "model": "U2723QE", "serial": "x"}}
EOF
  export NIRI_JSON
  run "$SCRIPT" nested
  [[ $output == *"DP monitor"* ]]
  [[ $output != *"lgc1-wold.py"* ]]
}

# --- unknown mode is rejected, not silently treated as plain ---

@test "tenfoot lock is created then removed" {
  run "$SCRIPT" tenfoot
  [[ ! -f "$STUBS/run/beryl-steam-tenfoot.lock" ]]
  [[ ! -f "$STUBS/run/beryl-steam-nested.lock" ]]
}

@test "plain mode runs without XDG_RUNTIME_DIR" {
  unset XDG_RUNTIME_DIR
  run "$SCRIPT" -- 'steam://open/games'
  [[ $status -eq 0 ]]
  [[ $output == *"STEAM_ARG steam://open/games"* ]]
}

@test "bpm is rejected with a non-zero exit" {
  run "$SCRIPT" bpm -- 'steam://open/bigpicture'
  [[ $status -ne 0 ]]
  [[ $output == *"Usage:"* ]]
  [[ $output != *"STEAM_ARG"* ]]
}
