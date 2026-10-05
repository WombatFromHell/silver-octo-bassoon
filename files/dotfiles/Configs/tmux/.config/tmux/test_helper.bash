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
  tmux new-session -d -s base
}

stop_scratch_server() {
  [[ -z ${SOCK:-} ]] || tmux kill-server 2>/dev/null
  [[ -z ${T:-} ]] || rm -rf "$T"
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
# #{d:current_file} resolve there, never to the user's dotfiles.
load_conf() {
  ensure_tmp

  mkdir -p "$HOME/.config/tmux"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.config/tmux/statusbar.sh"
  chmod +x "$HOME/.config/tmux/statusbar.sh"

  cp "$BATS_TEST_DIRNAME/tmux.conf" "$T/tmux.conf" &&
    tmux source-file "$T/tmux.conf"
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
