# test_helper.bash — shared scratch-tmux harness for the bats suites.
#
# Isolation: every test gets its own $T holding the socket, HOME and
# TMUX_TMPDIR; TMUX/TMUX_PANE are unset; the `tmux` wrapper is the ONLY door
# to tmux and always passes -S "$SOCK", so a real server is unreachable.
# The socket sits at the *default* path inside the private TMUX_TMPDIR, so a
# nested bare `tmux attach` (the floax popup path) finds this server too.

ensure_tmp() { [[ -n ${T:-} ]] || T="$(mktemp -d /tmp/tt-XXXXXX)"; }

tmux() {
  [[ -n ${SOCK:-} ]] || {
    echo "refusing to run tmux: no scratch socket" >&2
    return 99
  }
  "$REAL_TMUX" -f /dev/null -S "$SOCK" "$@"
}

start_scratch_server() {
  unset TMUX TMUX_PANE
  REAL_TMUX="$(type -P tmux)"
  ensure_tmp
  export TMUX_TMPDIR="$T" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
  SOCK="$T/tmux-$(id -u)/default"
  mkdir -p -m 700 "${SOCK%/*}"
  mkdir -p "$HOME" # tmux rejects non-700 socket dirs
  # Start the server in a subshell with extra FDs closed so the
  # daemonized server does not inherit the bats pipes (which would
  # keep the pipe open and deadlock bats in do_wait after the last test).
  (
    exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 2>/dev/null
    tmux new-session -d -s base
  ) </dev/null
}

# Server start for the integration/E2E tiers. (The old $T/bin link_tools line
# is gone: no integration/E2E test puts $T/bin on PATH — only unit-tier
# call_gpu does, via init_unit_bin in the unit test file.)
start_server() { start_scratch_server; }

stop_scratch_server() {
  # kill-server can fail (server already gone); never let that skip the rm.
  if [[ -n ${SOCK:-} ]]; then tmux kill-server </dev/null 2>/dev/null || true; fi
  if [[ -n ${T:-} ]]; then
    # The dying fish shell can mkdir its cache dirs back into $T a few ms
    # after kill-server; retry briefly until the tree is actually gone.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      rm -rf "$T" 2>/dev/null
      [[ -e $T ]] || break
      sleep 0.05
    done
  fi
  return 0
}

wait_until() { # seconds cmd [args...] — poll instead of sleeping
  local n=$(($1 * 20)) i
  shift
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

# Load the real tmux.conf into the scratch server. Copied into $T so ~ and
# #{d:current_file} resolve there, never to the user's dotfiles. The main
# conf sources conf.d/*.conf from ~, so those must land in the scratch HOME too.
load_conf() {
  ensure_tmp

  mkdir -p "$HOME/.config/tmux/scripts"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.config/tmux/scripts/statusbar.sh"
  chmod +x "$HOME/.config/tmux/scripts/statusbar.sh"

  cp "$BATS_TEST_DIRNAME/../tmux.conf" "$T/tmux.conf" &&
    cp -r "$BATS_TEST_DIRNAME/../conf.d" "$HOME/.config/tmux/" &&
    tmux source-file "$T/tmux.conf"
}

# make_mock NAME CONTENT -> executable in $T/mock, without overwriting other mocks.
make_mock() {
  ensure_tmp
  mkdir -p "$T/mock"
  rm -f "$T/mock/$1" # never write through a symlink to a real binary
  printf '%s' "$2" >"$T/mock/$1"
  chmod +x "$T/mock/$1"
}

# link_tools DIR tool... — symlink the real tools that exist; silently skip the
# rest (jq/flock/timeout are absent on stock macOS). Tests that need a tool
# call `needs TOOL`.
link_tools() {
  local dir=$1 t p
  shift
  for t in "$@"; do p="$(type -P "$t")" && ln -sf "$p" "$dir/$t"; done
  return 0
}
needs() { command -v "$1" >/dev/null || skip "$1 not installed"; }
